// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_tools/src/midi/ble/android_gatt.dart';
import 'package:pocket_amp_tools/src/midi/ble/gatt.dart';
import 'package:universal_ble/universal_ble.dart';

const String _id = 'AA:BB:CC:DD:EE:FF';
const String _service = '0000ffe0-0000-1000-8000-00805f9b34fb';
const String _write = '0000ffe1-0000-1000-8000-00805f9b34fb';
const String _notify = '0000ffe2-0000-1000-8000-00805f9b34fb';

/// Just enough of the plugin to open a session.
class _FakeBle extends UniversalBlePlatform {
  @override
  Future<void> connect(
    String deviceId, {
    Duration? connectionTimeout,
    bool autoConnect = false,
    ConnectionPlatformConfig? platformConfig,
  }) async => updateConnection(deviceId, true);

  @override
  Future<List<BleService>> discoverServices(
    String deviceId,
    bool withDescriptors, {
    DiscoverServicesPlatformConfig? platformConfig,
  }) async => <BleService>[];

  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) async => 247;

  @override
  Future<void> setNotifiable(
    String deviceId,
    String service,
    String characteristic,
    BleInputProperty bleInputProperty,
  ) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('a notification queued behind the link-down does not crash', () async {
    final _FakeBle ble = _FakeBle();
    UniversalBle.setInstance(ble);
    final BleGattSession s = await AndroidGattClient().open(
      deviceId: _id,
      serviceUuid: _service,
      writeCharacteristicUuid: _write,
      notifyCharacteristicUuid: _notify,
    );
    final List<Object> errors = <Object>[];
    s.notifications.listen((_) {}, onError: errors.add);

    // Both land in the plugin's queues before either is delivered.
    ble
      ..updateConnection(_id, false)
      ..updateCharacteristicValue(
        _id,
        _notify,
        Uint8List.fromList(<int>[1]),
        null,
      );
    await pumpEventQueue();

    expect(errors, hasLength(1));
  });
}
