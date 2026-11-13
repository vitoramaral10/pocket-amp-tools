// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_tools/src/midi/midi_backend.dart';
import 'package:pocket_amp_tools/src/ota_protocol.dart';
import 'package:pocket_amp_tools/src/presets/mefcs.dart';
import 'package:pocket_amp_tools/src/presets/preset_backup.dart';
import 'package:pocket_amp_tools/src/presets/preset_session.dart';
import 'package:pocket_amp_tools/src/presets/raw_flash.dart';
import 'package:pocket_amp_tools/src/presets/write_guard.dart';

import 'support/fake_pedal.dart';

/// A pedal over Bluetooth, as the V1.05 firmware reads: Save Preset gets a
/// NAK, route 05 type 7 erases and writes the two banks of raw flash, and
/// route 04 reads the active bank.
class RawPedal implements MidiConnection {
  RawPedal(Uint8List area, {Uint8List? other, this.active = 0})
    : flash = Uint8List(rawAreaEnd - rawAreaBase)..fillRange(0, 0x4000, 0xFF) {
    flash.setAll(active * rawBankSize, area);
    flash.setAll((1 - active) * rawBankSize, other ?? area);
  }

  final int active;
  final Uint8List flash;
  final List<String> ops = <String>[];
  final StreamController<Uint8List> _out = StreamController<Uint8List>();
  final SysexSplitter _split = SysexSplitter();

  @override
  Stream<Uint8List> get messages => _out.stream;

  void _reply(List<int> p) => scheduleMicrotask(() => _out.add(mefcsWrap(p)));

  static const List<int> _ack = <int>[0, 0x59, 0, 1, 0, 0, 0, 0xFF];
  static const List<int> _nak = <int>[0, 0x59, 0, 1, 0, 0, 1, 0xFE];

  @override
  Future<void> send(Uint8List sysex) async {
    for (final Uint8List m in _split.add(sysex)) {
      final Uint8List p = mefcsUnwrap(m)!;
      final int arg = p[7] | (p[8] << 8) | (p[9] << 16);
      final bool raw = p[6] == 5 && p[10] == 0x70;
      final int at = raw ? arg - rawAreaBase : active * rawBankSize + arg;
      if (p[2] == 0x21) {
        flash.fillRange(at, at + rawSectorSize, 0xFF);
        ops.add('erase ${at.toRadixString(16)}');
        _reply(_ack);
        continue;
      }
      final int len = p[11] | (p[12] << 8) | (p[13] << 16);
      if (p[2] == 0x23) {
        final List<int> r = <int>[
          0x00, 0x59, 0x23, (len + 8) & 0xFF, (len + 8) >> 8, 0, //
          ...p.sublist(6, 14),
          ...flash.sublist(at, at + len),
          0,
        ];
        r[r.length - 1] = mefcsChecksum(r);
        _reply(r);
      } else if (raw) {
        for (int i = 0; i < len; i++) {
          flash[at + i] &= p[14 + i]; // NOR flash only clears bits
        }
        _reply(_ack);
      } else {
        _reply(_nak); // Save Preset with Bluetooth connected
      }
    }
  }

  @override
  Future<void> close() => _out.close();
}

Uint8List areaBytes(Uint8List bank) =>
    Uint8List.sublistView(bank, 0, eqTableAddress + eqTableLength);

void main() {
  test('the erase packet is the one read from the firmware', () {
    expect(rawErasePacket(0x3C000), <int>[
      0x00, 0x59, 0x21, 0x05, 0x00, 0x00, 0x05, //
      0x00, 0xC0, 0x03, 0x70, 0xC7,
    ]);
    checkOutgoing(rawErasePacket(0x3E000));
  });

  test('raw packets outside the preset flash are blocked', () {
    expect(
      () => checkOutgoing(rawErasePacket(0x3B000)),
      throwsA(isA<BlockedPacket>()),
    );
    expect(
      () => checkOutgoing(rawErasePacket(0x3C800)),
      throwsA(isA<BlockedPacket>()),
    );
    expect(
      () => checkOutgoing(rawWritePacket(0x3FF00, Uint8List(512))),
      throwsA(isA<BlockedPacket>()),
    );
    expect(
      () => checkOutgoing(rawReadPacket(0x00000, 16)),
      throwsA(isA<BlockedPacket>()),
    );
    checkOutgoing(rawWritePacket(0x3D000, Uint8List(1024)));
    checkOutgoing(rawReadPacket(0x3E000, 1024));
  });

  test('a restore over Bluetooth rewrites only the active bank', () async {
    final Uint8List area = areaBytes(demoBank());
    final Uint8List other = Uint8List.fromList(area)..[5] ^= 1;
    final RawPedal pedal = RawPedal(area, other: other, active: 1);
    final PresetSession s = PresetSession(pedal);
    final PresetBackup read = await readPresetBank(s, 'Pocket AMP_BLE');
    final PresetBackup want = PresetBackup.fromJson(read.toJson());
    want.presets[3 * presetSize + 20] = 77; // P04, a knob
    want.presets[60 * presetSize + 20] = 66; // P61, second sector

    final PresetDiff d = await restorePresetBank(s, want, rawFlash: true);
    expect(d.presets, <int>[3, 60]);
    expect(pedal.ops, <String>['erase 2000', 'erase 3000']);
    expect(
      pedal.flash.sublist(rawBankSize, rawBankSize + area.length),
      areaOf(want),
    );
    expect(pedal.flash.sublist(0, area.length), other); // the other bank
    expect(
      pedal.flash.sublist(rawBankSize + area.length, 0x4000),
      everyElement(0xFF),
    );
    await s.close();
  });

  test('when both banks match, both are written', () async {
    final Uint8List area = areaBytes(demoBank());
    final RawPedal pedal = RawPedal(area);
    final PresetSession s = PresetSession(pedal);
    final PresetBackup read = await readPresetBank(s, 'Pocket AMP_BLE');
    final PresetBackup want = PresetBackup.fromJson(read.toJson());
    want.presets[20] = 1;
    await restorePresetBank(s, want, rawFlash: true);
    expect(pedal.ops, <String>['erase 0', 'erase 2000']);
    await s.close();
  });

  test('over USB the same restore is still refused, not written raw', () async {
    final RawPedal pedal = RawPedal(areaBytes(demoBank()));
    final PresetSession s = PresetSession(pedal);
    final PresetBackup read = await readPresetBank(s, 'Pocket AMP_BLE');
    final PresetBackup want = PresetBackup.fromJson(read.toJson());
    want.presets[20] = 1;
    await expectLater(
      restorePresetBank(s, want),
      throwsA(isA<PresetIoException>()),
    );
    expect(pedal.ops, isEmpty);
    await s.close();
  });
}
