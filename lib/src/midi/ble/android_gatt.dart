// SPDX-License-Identifier: GPL-3.0-only
//
// GATT on Android, through the universal_ble plugin. Android pairs the pedal
// itself: the system shows its pairing dialog when the pedal asks for it.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:universal_ble/universal_ble.dart';

import 'gatt.dart';

class AndroidGattClient implements BleGattClient {
  /// What scans found, by id: Android lists only connected devices on its own.
  /// Shared, so a pedal paired from the pairing dialog is seen as paired by
  /// the backend at once.
  static final Map<String, BleDevice> _seen = <String, BleDevice>{};

  /// Pedals in range that this phone has not paired: the user picks one, so
  /// a neighbour's pedal is never paired on its own.
  Future<List<BleDeviceInfo>> nearbyUnpaired({
    required bool Function(BleDeviceInfo) isPedal,
    Duration scanFor = const Duration(seconds: 5),
  }) async => <BleDeviceInfo>[
    for (final BleDeviceInfo d in await listDevices(scanFor: scanFor))
      if (!d.paired && isPedal(d)) d,
  ];

  /// Shows Android's pairing dialog for [deviceId]; throws if the user
  /// declines or the pedal does not answer.
  Future<void> pair(String deviceId) async {
    await UniversalBle.pair(deviceId);
    _seen[deviceId]?.paired = true;
  }

  @override
  Future<bool> hasAdapter() async {
    try {
      if (!await UniversalBle.hasPermissions()) {
        await UniversalBle.requestPermissions();
      }
      return await UniversalBle.getBluetoothAvailabilityState() ==
          AvailabilityState.poweredOn;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<BleDeviceInfo>> listDevices({
    Duration scanFor = Duration.zero,
  }) async {
    if (scanFor > Duration.zero) {
      final StreamSubscription<BleDevice> sub = UniversalBle.scanStream.listen(
        (BleDevice d) => _seen[d.deviceId] = d,
      );
      try {
        try {
          await UniversalBle.startScan();
        } catch (_) {
          // Already scanning (the backend's background scan): listen to it.
        }
        await Future<void>.delayed(scanFor);
      } finally {
        await UniversalBle.stopScan();
        await sub.cancel();
      }
    }
    for (final BleDevice d in await UniversalBle.getSystemDevices()) {
      _seen[d.deviceId] = d;
    }
    final List<BleDeviceInfo> out = <BleDeviceInfo>[
      for (final BleDevice d in _seen.values)
        BleDeviceInfo(
          id: d.deviceId,
          name: d.name ?? '',
          address: d.deviceId,
          serviceUuids: d.services.map((String s) => s.toLowerCase()).toList(),
          paired: d.paired ?? false,
        ),
    ];
    // A paired pedal that reconnected to the phone does not advertise.
    for (final Map<Object?, Object?> b in await _bonded()) {
      final String id = b['id']! as String;
      out
        ..removeWhere((BleDeviceInfo d) => d.id == id)
        ..add(
          BleDeviceInfo(
            id: id,
            name: b['name']! as String,
            address: id,
            serviceUuids:
                _seen[id]?.services
                    .map((String s) => s.toLowerCase())
                    .toList() ??
                const <String>[],
            paired: true,
          ),
        );
    }
    return out;
  }

  static const MethodChannel _channel = MethodChannel('pocket_amp/bluetooth');

  Future<List<Map<Object?, Object?>>> _bonded() async {
    try {
      return (await _channel.invokeListMethod<Map<Object?, Object?>>(
            'bonded',
          )) ??
          const <Map<Object?, Object?>>[];
    } on MissingPluginException {
      return const <Map<Object?, Object?>>[];
    }
  }

  @override
  Future<BleGattSession> open({
    required String deviceId,
    required String serviceUuid,
    required String writeCharacteristicUuid,
    required String notifyCharacteristicUuid,
  }) async {
    try {
      try {
        await UniversalBle.connect(
          deviceId,
          timeout: const Duration(seconds: 12),
        );
      } catch (_) {
        // Android often fails the first connect with GATT error 133, most
        // of all right after pairing; a second try usually works.
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await UniversalBle.connect(
          deviceId,
          timeout: const Duration(seconds: 12),
        );
      }
      await UniversalBle.discoverServices(deviceId);
      int mtu = 23;
      try {
        mtu = await UniversalBle.requestMtu(deviceId, 247);
      } catch (_) {
        // The default MTU still works, in smaller writes.
      }
      final _AndroidSession s = _AndroidSession(
        deviceId,
        serviceUuid,
        writeCharacteristicUuid,
        notifyCharacteristicUuid,
        mtu - 3,
      );
      await UniversalBle.subscribeNotifications(
        deviceId,
        serviceUuid,
        notifyCharacteristicUuid,
      );
      return s;
    } catch (e) {
      try {
        await UniversalBle.disconnect(deviceId);
      } catch (_) {
        // Never connected.
      }
      throw BleGattException(BleGattFailure.connectionFailed, '$e');
    }
  }
}

class _AndroidSession implements BleGattSession {
  _AndroidSession(
    this._id,
    this._service,
    this._write,
    this._notify,
    this.writeMtu,
  ) {
    _value = UniversalBle.characteristicValueStream(
      _id,
      _notify,
    ).listen(_out.add);
    _link = UniversalBle.connectionStream(_id).listen((bool up) {
      if (!up && !_out.isClosed) {
        _out.addError(const BleGattException(BleGattFailure.disconnected));
        _out.close();
      }
    });
  }

  final String _id;
  final String _service;
  final String _write;
  final String _notify;
  final StreamController<List<int>> _out = StreamController<List<int>>();
  late final StreamSubscription<Uint8List> _value;
  late final StreamSubscription<bool> _link;

  @override
  final int writeMtu;

  @override
  Stream<List<int>> get notifications => _out.stream;

  @override
  Future<void> write(List<int> chunk) => UniversalBle.write(
    _id,
    _service,
    _write,
    Uint8List.fromList(chunk),
    withoutResponse: true,
  );

  @override
  Future<void> disconnect() => UniversalBle.disconnect(_id);

  @override
  Future<void> close() async {
    await _value.cancel();
    await _link.cancel();
    unawaited(_out.close());
    try {
      await UniversalBle.unsubscribe(_id, _service, _notify);
    } catch (_) {
      // The link may already be down.
    }
    await UniversalBle.disconnect(_id);
  }
}
