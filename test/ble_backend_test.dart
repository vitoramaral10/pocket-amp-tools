import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_tools/src/firmware_package.dart';
import 'package:pocket_amp_tools/src/midi/ble/ble_backend.dart';
import 'package:pocket_amp_tools/src/midi/ble/gatt.dart';
import 'package:pocket_amp_tools/src/midi/midi_backend.dart';
import 'package:pocket_amp_tools/src/ota_protocol.dart';
import 'package:pocket_amp_tools/src/pedal_updater.dart';
import 'package:pocket_amp_tools/src/presets/mefcs.dart';
import 'package:pocket_amp_tools/src/presets/preset_session.dart';
import 'package:pocket_amp_tools/src/presets/write_guard.dart';

import 'support/fake_pedal.dart';

/// A pedal behind the GATT tunnel: reassembles what is written, answers like
/// [pedal] would, and notifies the answer in 20-byte pieces.
class _Radio implements BleGattClient, BleGattSession {
  _Radio(this.pedal, {this.devices = const <BleDeviceInfo>[]});
  final FakePedal pedal;
  final List<BleDeviceInfo> devices;
  final List<List<int>> writes = <List<int>>[];
  int failAfter = -1;
  int disconnects = 0;
  final List<int> _in = <int>[];
  StreamController<List<int>> _notify = StreamController<List<int>>();

  @override
  Future<bool> hasAdapter() async => true;
  @override
  Future<List<BleDeviceInfo>> listDevices({
    Duration scanFor = Duration.zero,
  }) async => devices;
  @override
  Future<BleGattSession> open({
    required String deviceId,
    required String serviceUuid,
    required String writeCharacteristicUuid,
    required String notifyCharacteristicUuid,
  }) async {
    _notify = StreamController<List<int>>();
    return this;
  }

  @override
  Stream<List<int>> get notifications => _notify.stream;
  @override
  int get writeMtu => 20;
  @override
  Future<void> write(List<int> chunk) async {
    if (writes.length == failAfter) {
      throw const BleGattException(BleGattFailure.disconnected);
    }
    writes.add(chunk);
    _in.addAll(chunk);
    final int total = (_in[3] | (_in[4] << 8)) + 7;
    if (_in.length >= total) {
      final List<int> reply = bankReply(
        pedal,
        Uint8List.fromList(_in.sublist(0, total)),
      );
      _in.clear();
      for (int at = 0; at < reply.length; at += 20) {
        _notify.add(
          reply.sublist(at, at + 20 > reply.length ? reply.length : at + 20),
        );
      }
    }
  }

  @override
  Future<void> disconnect() async => disconnects++;

  @override
  Future<void> close() => _notify.close();
}

const BleDeviceInfo _pocket = BleDeviceInfo(
  id: '/org/bluez/hci0/dev_14',
  name: 'Pocket AMP_BLE',
  address: 'AA:BB:CC:DD:EE:FF',
  paired: true,
);

class _NoUsb implements MidiBackend {
  @override
  Future<List<MidiPortRef>> listPorts() async => const <MidiPortRef>[];
  @override
  Future<MidiConnection> open(MidiPortRef port) => throw UnimplementedError();
}

void main() {
  test('lists only the pedal, as a Bluetooth port', () async {
    final _Radio radio = _Radio(
      FakePedal(image: Uint8List(1024), bank: demoBank()),
      devices: const <BleDeviceInfo>[
        _pocket,
        BleDeviceInfo(id: 'x', name: 'Headphones', address: 'AA', paired: true),
        // A neighbour's pedal: same name, not paired here.
        BleDeviceInfo(id: 'n', name: 'Pocket AMP_BLE', address: 'BB'),
      ],
    );
    final List<MidiPortRef> ports = await BleBackend(client: radio).listPorts();
    expect(ports.map((MidiPortRef p) => p.name), <String>['Pocket AMP_BLE']);
    expect(ports.single.bluetooth, isTrue);
  });

  test('preset traffic crosses in MTU pieces and comes back whole', () async {
    final FakePedal pedal = FakePedal(image: Uint8List(1024), bank: demoBank());
    final _Radio radio = _Radio(pedal);
    final MidiConnection c = await BleBackend(
      client: radio,
    ).open(const MidiPortRef(id: 'd', name: 'Pocket AMP_BLE', bluetooth: true));
    final PresetSession s = PresetSession(c);
    final Uint8List live = await s.readLive();
    await s.close();

    expect(live, pedal.bank!.sublist(0, presetSize));
    // Sent raw, without SysEx: the first piece starts with the packet.
    expect(radio.writes.first.sublist(0, 3), <int>[0x00, 0x59, 0x23]);
    expect(radio.writes.every((List<int> w) => w.length <= 20), isTrue);
  });

  test('a failed write drops the link', () async {
    final _Radio radio = _Radio(
      FakePedal(image: Uint8List(1024), bank: demoBank()),
    )..failAfter = 0;
    final MidiConnection c = await BleBackend(
      client: radio,
    ).open(const MidiPortRef(id: 'd', name: 'Pocket AMP_BLE', bluetooth: true));
    await expectLater(
      c.send(mefcsWrap(changeKnobPacket(1, 0, 50))),
      throwsA(isA<MidiPortGone>()),
    );
    expect(radio.disconnects, 1);
    await c.close();
  });

  test('a false header with a bad checksum is skipped', () async {
    final _Radio radio = _Radio(
      FakePedal(image: Uint8List(1024), bank: demoBank()),
    );
    final BleConnection c = BleConnection(
      await radio.open(
        deviceId: 'd',
        serviceUuid: '',
        writeCharacteristicUuid: '',
        notifyCharacteristicUuid: '',
      ),
    );
    final Uint8List good = loadPresetPacket(3);
    final List<int> bad = List<int>.of(good)..last ^= 0xFF;
    final Future<Uint8List> first = c.messages.first;
    radio._notify.add(<int>[...bad, ...good]);
    expect(mefcsUnwrap(await first), good);
    await c.close();
  });

  test('firmware traffic never goes over the radio', () async {
    final _Radio radio = _Radio(
      FakePedal(image: Uint8List(1024), bank: demoBank()),
    );
    final MidiConnection c = await BleBackend(
      client: radio,
    ).open(const MidiPortRef(id: 'd', name: 'Pocket AMP_BLE', bluetooth: true));
    await expectLater(
      c.send(buildFrame(cmdIdentity, Uint8List(0))),
      throwsA(anyOf(isA<MidiIoException>(), isA<BlockedPacket>())),
    );
    expect(radio.writes, isEmpty);
    await c.close();
  });

  test('a pedal over Bluetooth is found, but not offered an update', () async {
    final _Radio radio = _Radio(
      FakePedal(image: Uint8List(1024), bank: demoBank()),
      devices: const <BleDeviceInfo>[_pocket],
    );
    final PedalUpdater u = PedalUpdater(
      CombinedBackend(_NoUsb(), BleBackend(client: radio)),
    );
    final DetectedPedal p = (await u.detect())!;
    expect(p.identity, 'Pocket AMP_BLE');
    expect(p.family, 'Pocket AMP');
    expect(p.port.bluetooth, isTrue);
    final FirmwarePackage pkg = FirmwarePackage.parse(
      buildFwsc(loader: Uint8List(64)),
    );
    expect(u.blockers(pkg, p).first, contains('USB cable'));
  });

  test('a cut-off answer does not swallow the next one', () async {
    final FakePedal pedal = FakePedal(image: Uint8List(1024), bank: demoBank());
    final _Radio radio = _Radio(pedal);
    final MidiConnection c = await BleBackend(
      client: radio,
    ).open(const MidiPortRef(id: 'd', name: 'Pocket AMP_BLE', bluetooth: true));
    // The start of a long answer whose rest never came.
    radio._notify.add(<int>[0x00, 0x59, 0x23, 0xF0, 0x00, 1, 2, 3]);
    final PresetSession s = PresetSession(c);
    expect(await s.readLive(), pedal.bank!.sublist(0, presetSize));
    await s.close();
  });
}
