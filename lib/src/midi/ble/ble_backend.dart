// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:typed_data';

import '../../presets/mefcs.dart';
import '../../presets/write_guard.dart';
import '../midi_backend.dart';
import 'bluez_gatt.dart';
import 'gatt.dart';

/// The Pocket AMP over Bluetooth LE, through M-VAVE's own GATT tunnel
/// (service ae40: write ae41, notify ae42). Over the radio M-EFCS packets go
/// raw, without SysEx; this backend unwraps what the app sends and wraps
/// what comes back, so the rest of the app sees an ordinary MIDI port.
///
/// Only M-EFCS traffic crosses (presets, IR and model uploads): the firmware
/// update protocol is not sent. Every packet also passes [checkOutgoing].
class BleBackend implements MidiBackend {
  BleBackend({
    BleGattClient? client,
    this.scanWindow = const Duration(seconds: 4),
    this.scanCooldown = const Duration(seconds: 30),
  }) : _client = client ?? BluezGattClient();

  static const String tunnelService = '0000ae40-0000-1000-8000-00805f9b34fb';
  static const String tunnelWrite = '0000ae41-0000-1000-8000-00805f9b34fb';
  static const String tunnelNotify = '0000ae42-0000-1000-8000-00805f9b34fb';
  static const String nameHint = 'pocket amp_ble';

  final BleGattClient _client;

  /// Carries the pedal's name or its tunnel service.
  static bool looksLikePedal(BleDeviceInfo d) =>
      d.name.toLowerCase().contains(nameHint) ||
      d.serviceUuids.contains(tunnelService);
  final Duration scanWindow;
  final Duration scanCooldown;
  DateTime? _lastScan;

  @override
  Future<List<MidiPortRef>> listPorts() async {
    try {
      if (!await _client.hasAdapter()) {
        return const <MidiPortRef>[];
      }
      _scanInBackground();
      return <MidiPortRef>[
        for (final BleDeviceInfo d in await _client.listDevices(
          scanFor: Duration.zero,
        ))
          // Only a pedal paired with this computer: any device nearby can
          // carry the name or the service.
          if (d.paired && looksLikePedal(d))
            MidiPortRef(
              id: d.id,
              name: d.name.isEmpty ? d.address : d.name,
              bluetooth: true,
            ),
      ];
    } catch (_) {
      return const <MidiPortRef>[];
    }
  }

  /// Discovery runs in the background, at most every [scanCooldown], so
  /// listing ports stays quick; a pedal just turned on shows up next time.
  void _scanInBackground() {
    final DateTime now = DateTime.now();
    if (_lastScan != null && now.difference(_lastScan!) < scanCooldown) {
      return;
    }
    _lastScan = now;
    unawaited(
      _client
          .listDevices(scanFor: scanWindow)
          .then((_) {}, onError: (Object _) {}),
    );
  }

  @override
  Future<MidiConnection> open(MidiPortRef port) async {
    try {
      return BleConnection(
        await _client.open(
          deviceId: port.id,
          serviceUuid: tunnelService,
          writeCharacteristicUuid: tunnelWrite,
          notifyCharacteristicUuid: tunnelNotify,
        ),
      );
    } on BleGattException catch (e) {
      throw MidiIoException('$e');
    }
  }
}

/// One open tunnel, seen as a SysEx port.
class BleConnection implements MidiConnection {
  BleConnection(this._session) {
    _sub = _session.notifications.listen(
      (List<int> chunk) {
        _buffer.addAll(chunk);
        _drain();
      },
      onDone: _gone,
      onError: (Object _) => _gone(),
    );
  }

  final BleGattSession _session;
  late final StreamSubscription<List<int>> _sub;
  final StreamController<Uint8List> _out = StreamController<Uint8List>();
  List<int> _buffer = <int>[];

  @override
  Stream<Uint8List> get messages => _out.stream;

  @override
  Future<void> send(Uint8List sysex) async {
    final Uint8List? packet = mefcsUnwrap(sysex);
    if (packet == null) {
      throw const MidiIoException(
        'Only preset traffic goes over Bluetooth; firmware updates need the '
        'USB cable.',
      );
    }
    checkOutgoing(packet);
    // A request starts a new answer: drop the rest of a cut-off one, which
    // would otherwise swallow the replies that follow.
    _buffer = <int>[];
    final int step = _session.writeMtu;
    try {
      for (int at = 0; at < packet.length; at += step) {
        await _session.write(
          packet.sublist(
            at,
            at + step > packet.length ? packet.length : at + step,
          ),
        );
      }
    } catch (_) {
      // Part of a packet may have reached the pedal: drop the link so it
      // does not glue the next packet onto it.
      _gone();
      await _session.disconnect();
      throw const MidiPortGone('(Bluetooth)');
    }
  }

  /// Splits the notification stream into packets by their length field.
  void _drain() {
    while (true) {
      int start = -1;
      for (int i = 0; i + 1 < _buffer.length; i++) {
        if (_buffer[i] == 0x00 && _buffer[i + 1] == 0x59) {
          start = i;
          break;
        }
      }
      if (start < 0) {
        // Keep a trailing 00: it may start a header split across chunks.
        _buffer = _buffer.isNotEmpty && _buffer.last == 0 ? <int>[0] : <int>[];
        return;
      }
      _buffer = _buffer.sublist(start);
      if (_buffer.length < 5) {
        return;
      }
      final int total = (_buffer[3] | (_buffer[4] << 8)) + 7;
      if (total < 8 || total > 1100) {
        _buffer = _buffer.sublist(1);
        continue;
      }
      if (_buffer.length < total) {
        return;
      }
      final Uint8List wrapped = mefcsWrap(_buffer.sublist(0, total));
      if (mefcsUnwrap(wrapped) == null) {
        // Bad checksum: a false start, look for the next header.
        _buffer = _buffer.sublist(1);
        continue;
      }
      if (!_out.isClosed) {
        _out.add(wrapped);
      }
      _buffer = _buffer.sublist(total);
    }
  }

  void _gone() {
    if (!_out.isClosed) {
      _out.addError(const MidiPortGone('(Bluetooth)'));
      _out.close();
    }
  }

  @override
  Future<void> close() async {
    await _sub.cancel();
    // Not awaited: with no listener, close() never completes.
    unawaited(_out.close());
    try {
      await _session.close();
    } catch (_) {
      // The pedal may already be gone.
    }
  }
}

/// USB ports first, then the pedal over Bluetooth.
class CombinedBackend implements MidiBackend {
  CombinedBackend(this.usb, this.ble);
  final MidiBackend usb;
  final MidiBackend ble;

  @override
  Future<List<MidiPortRef>> listPorts() async => <MidiPortRef>[
    ...await usb.listPorts(),
    // A stuck BlueZ must not stall detection of a pedal on the cable.
    ...await ble.listPorts().timeout(
      const Duration(seconds: 3),
      onTimeout: () => const <MidiPortRef>[],
    ),
  ];

  @override
  Future<MidiConnection> open(MidiPortRef port) =>
      port.bluetooth ? ble.open(port) : usb.open(port);
}
