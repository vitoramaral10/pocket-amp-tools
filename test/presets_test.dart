import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_upgrader/src/midi/midi_backend.dart';
import 'package:pocket_amp_upgrader/src/ota_protocol.dart';
import 'package:pocket_amp_upgrader/src/presets/mefcs.dart';
import 'package:pocket_amp_upgrader/src/presets/preset_backup.dart';
import 'package:pocket_amp_upgrader/src/presets/preset_session.dart';

String hex(List<int> b) => b
    .map((int x) => x.toRadixString(16).padLeft(2, '0').toUpperCase())
    .join(' ');

/// Simulated preset bank: answers reads, keeps saves in a RAM mirror and
/// copies it to "flash" on Commit.
class FakeBank implements MidiConnection {
  FakeBank(this.flash) : ram = Uint8List.fromList(flash);
  final Uint8List flash;
  final Uint8List ram;
  final List<String> writes = <String>[];
  final StreamController<Uint8List> _out = StreamController<Uint8List>();
  final SysexSplitter _split = SysexSplitter();

  @override
  Stream<Uint8List> get messages => _out.stream;

  void _reply(List<int> packet) =>
      scheduleMicrotask(() => _out.add(mefcsWrap(packet)));

  @override
  Future<void> send(Uint8List sysex) async {
    for (final Uint8List m in _split.add(sysex)) {
      final Uint8List p = mefcsUnwrap(m)!;
      final int addr = p[7] | (p[8] << 8) | (p[9] << 16);
      final int len = p[11] | (p[12] << 8) | (p[13] << 16);
      if (p[2] == 0x23) {
        final List<int> r = <int>[
          0x00,
          0x59,
          0x23,
          (len + 8) & 0xFF,
          (len + 8) >> 8,
          0,
          4,
          ...p.sublist(7, 14),
          ...ram.sublist(addr, addr + len),
          0,
        ];
        r[r.length - 1] = mefcsChecksum(r);
        _reply(r);
      } else if (p[2] == 0x22) {
        if (p[10] == 0xF0) {
          flash.setAll(0, ram);
          writes.add('commit');
        } else {
          ram.setAll(addr, p.sublist(14, 14 + len));
          writes.add(p[3] == 0x64 ? 'preset ${addr ~/ 92}' : 'eq');
        }
        _reply(<int>[0, 0x59, 0, 1, 0, 0, 0, 0xFF]);
      }
    }
  }

  @override
  Future<void> close() => _out.close();
}

Uint8List bank() {
  final Uint8List a = Uint8List(eqTableAddress + eqTableLength);
  for (int i = 0; i < eqTableAddress; i++) {
    a[i] = (i * 13) & 0x7F;
  }
  a.setAll(eqTableAddress, eqHeader);
  return a;
}

void main() {
  test('packets match the bytes measured on the pedal', () {
    expect(hex(commitPacket()), '00 59 22 08 00 00 04 00 00 00 F0 00 00 00 0B');
    expect(savePresetPacket(79, List<int>.filled(92, 0)).last, 0x1F);
    expect(
      savePresetPacket(79, List<int>.filled(92, 0)..[32] = 0x11).last,
      0x0E,
    );
    expect(
      hex(readFlashPacket(7360, 128)),
      '00 59 23 08 00 00 04 C0 1C 00 00 80 00 00 9F',
    );
    expect(
      hex(readFlashPacket(7360 + 512, 66)),
      '00 59 23 08 00 00 04 C0 1E 00 00 42 00 00 DB',
    );
    expect(
      saveEqPacket(79, <int>[1, 0, 6, 0, 0xFA, 0, 3]).sublist(7, 10),
      <int>[0xFB, 0x1E, 0],
    );
  });

  test('wire format round-trips', () {
    final Uint8List p = savePresetPacket(
      3,
      List<int>.generate(92, (int i) => i),
    );
    expect(mefcsUnwrap(mefcsWrap(p)), p);
  });

  test('out-of-range EQ is refused', () {
    expect(
      () => saveEqPacket(0, <int>[1, 0, 7, 0, 0, 0, 0]),
      throwsArgumentError,
    );
  });

  test('backup, then restore writes only what changed', () async {
    final FakeBank pedal = FakeBank(bank());
    final PresetSession s = PresetSession(pedal);
    final PresetBackup saved = await readPresetBank(s, 'Pocket AMP_105');
    expect(saved.presets, pedal.ram.sublist(0, eqTableAddress));
    final PresetBackup copy = PresetBackup.fromJson(saved.toJson());
    expect(copy.presets, saved.presets);

    // A firmware update rewrites two presets and one EQ record.
    pedal.ram[0] ^= 0x7F;
    pedal.ram[79 * 92 + 5] ^= 1;
    pedal.ram[eqTableAddress + eqHeaderLength + 2] = 1;
    pedal.flash.setAll(0, pedal.ram);

    final PresetDiff restored = await restorePresetBank(s, copy);
    expect(restored.presets, <int>[0, 79]);
    expect(restored.eq, <int>[0]);
    expect(pedal.writes, <String>['preset 0', 'preset 79', 'eq', 'commit']);
    expect(pedal.flash, bank());
    await s.close();
  });

  test('the backup file also shows the presets as plain fields', () {
    final Uint8List a = Uint8List(eqTableAddress + eqTableLength)
      ..setAll(eqTableAddress, eqHeader);
    // P02: volume 60, MOD first in the chain, AMP on with model 7 and its
    // first knob at 300; a 5-band EQ at the head.
    final int p02 = presetSize;
    a[p02] = 60;
    a.setAll(p02 + 2, <int>[2, 0, 1, 3, 4, 6]); // 6 is not a block
    a[p02 + 8 + 1] = 1;
    a[p02 + 14 + 1] = 7;
    a.setAll(p02 + 20 + 12, <int>[0x2C, 0x01]);
    final int eq = eqTableAddress + eqHeaderLength;
    a.setAll(eq + eqRecordLength, <int>[1, 1, 6, 0xFA, 0, 0, 3]);
    // P03: a 7-band record (bands 1 -2 3 -4 5 -6 7 dB, level -3, model 1).
    a.setAll(eq + 2 * eqRecordLength, <int>[1, 0x84, 193, 15, 94, 244, 233]);

    final PresetBackup b = PresetBackup(
      identity: 'Pocket AMP_105',
      created: DateTime.utc(2026),
      presets: Uint8List.sublistView(a, 0, eqTableAddress),
      eq: Uint8List.sublistView(a, eqTableAddress),
    );
    final Map<String, Object?> file =
        jsonDecode(b.toJson()) as Map<String, Object?>;
    final List<Object?> readable = file['readable']! as List<Object?>;
    expect(readable, hasLength(presetCount));
    expect(readable[1], <String, Object>{
      'preset': 'P02',
      'volume': 60,
      'chain': <Object>['MOD', 'FX', 'AMP', 'DLY', 'REV', 6],
      'blocks': <String, Object>{
        for (final String name in blockNames)
          name: <String, Object>{
            'on': name == 'AMP',
            'model': name == 'AMP' ? 7 : 0,
            'knobs': <int>[name == 'AMP' ? 300 : 0, 0, 0, 0, 0, 0],
          },
      },
      'eq': <String, Object>{
        'on': true,
        'position': 'head',
        'bands': <int>[6, -6, 0, 0, 3],
      },
    });
    expect((readable[2]! as Map<String, Object?>)['eq'], <String, Object>{
      'on': true,
      'position': 4,
      'bands_db': <int>[1, -2, 3, -4, 5, -6, 7],
      'level_db': -6,
      'model': 1,
    });
    // P04: the most negative band (raw 16) and level (raw 8) read as 0.
    a.setAll(eq + 3 * eqRecordLength, <int>[1, 0x80, 0x10, 0, 0, 0, 0x40]);
    expect(
      PresetBackup(
        identity: 'x',
        created: DateTime.utc(2026),
        presets: Uint8List.sublistView(a, 0, eqTableAddress),
        eq: Uint8List.sublistView(a, eqTableAddress),
      ).readable[3]['eq'],
      <String, Object>{
        'on': true,
        'position': 'tail',
        'bands_db': <int>[0, 0, 0, 0, 0, 0, 0],
        'level_db': 0,
        'model': 0,
      },
    );
    // Restore still reads the raw data, whatever "readable" says.
    file['readable'] = <Object>[];
    expect(PresetBackup.fromJson(jsonEncode(file)).presets, b.presets);
  });

  test(
    'a record the app cannot write stops the restore before any write',
    () async {
      final FakeBank pedal = FakeBank(bank());
      final PresetSession s = PresetSession(pedal);
      final PresetBackup saved = await readPresetBank(s, 'x');
      // The backup differs in a preset and in the EQ of P02, which has a
      // band out of range.
      final Uint8List eq = Uint8List.fromList(saved.eq)
        ..setAll(eqHeaderLength + eqRecordLength, <int>[1, 0, 7, 0, 0, 0, 0]);
      final PresetBackup odd = PresetBackup(
        identity: 'x',
        created: saved.created,
        presets: Uint8List.fromList(saved.presets)..[0] ^= 1,
        eq: eq,
      );
      await expectLater(
        restorePresetBank(s, odd),
        throwsA(
          isA<PresetIoException>().having(
            (PresetIoException e) => e.message,
            'message',
            'Cannot restore: the EQ of P02 is not a record this app can '
                'write. Nothing was written to the pedal.',
          ),
        ),
      );
      expect(pedal.writes, isEmpty);
      await s.close();
    },
  );

  group('7-band EQ records', () {
    const List<int> sevenBand = <int>[1, 0x80, 61, 244, 254, 133, 8];

    Future<List<String>> restoreSevenBandTo(Uint8List flash) async {
      final FakeBank pedal = FakeBank(flash);
      final PresetSession s = PresetSession(pedal);
      final PresetBackup saved = await readPresetBank(s, 'x');
      final PresetBackup backup = PresetBackup(
        identity: 'x',
        created: saved.created,
        presets: saved.presets,
        eq: Uint8List.fromList(saved.eq)
          ..setAll(eqHeaderLength + 79 * eqRecordLength, sevenBand),
      );
      try {
        await restorePresetBank(s, backup);
        expect(pedal.flash.sublist(pedal.flash.length - 7), sevenBand);
      } finally {
        await s.close();
      }
      return pedal.writes;
    }

    test('go back to a pedal that already holds one', () async {
      final Uint8List flash = bank()
        ..[eqTableAddress + eqHeaderLength + 1] = 0x80;
      expect(await restoreSevenBandTo(flash), <String>['eq', 'commit']);
    });

    test('are refused on a pedal with none, before any write', () async {
      await expectLater(
        restoreSevenBandTo(bank()),
        throwsA(
          isA<PresetIoException>().having(
            (PresetIoException e) => e.message,
            'message',
            'Cannot restore: the EQ of P80 is a 7-band record, and this '
                'pedal has no 7-band EQ. Nothing was written to the pedal.',
          ),
        ),
      );
    });

    test('with a position past 6 are refused', () {
      expect(
        () => saveEqPacket(0, <int>[1, 0x87, 0, 0, 0, 0, 0], sevenBand: true),
        throwsArgumentError,
      );
    });
  });

  test('restore with nothing to do writes nothing', () async {
    final FakeBank pedal = FakeBank(bank());
    final PresetSession s = PresetSession(pedal);
    final PresetBackup saved = await readPresetBank(s, 'x');
    expect((await restorePresetBank(s, saved)).isEmpty, isTrue);
    expect(pedal.writes, isEmpty);
    await s.close();
  });
  test('unknown layout keeps the raw bytes', () async {
    final Uint8List flash = bank();
    flash[eqTableAddress] = 0xFF; // no PATCHEND header, as on PIXIE1 V0.07
    final PresetSession s = PresetSession(FakeBank(flash));
    await expectLater(
      readPresetBank(s, 'PIXIE1_007'),
      throwsA(
        isA<UnknownPresetLayout>().having(
          (UnknownPresetLayout e) => e.area,
          'area',
          flash,
        ),
      ),
    );
    await s.close();
  });
}
