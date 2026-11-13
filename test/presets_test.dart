import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_tools/src/midi/midi_backend.dart';
import 'package:pocket_amp_tools/src/ota_protocol.dart';
import 'package:pocket_amp_tools/src/presets/block_models.dart';
import 'package:pocket_amp_tools/src/presets/mefcs.dart';
import 'package:pocket_amp_tools/src/presets/preset_backup.dart';
import 'package:pocket_amp_tools/src/presets/preset_session.dart';

import 'support/fake_pedal.dart';

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

/// A bank in the ranges the firmware keeps (the guard refuses others).
Uint8List bank() => demoBank();

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

  test('the backup file holds the presets as named fields', () {
    final Uint8List a = Uint8List(eqTableAddress + eqTableLength)
      ..setAll(eqTableAddress, eqHeader);
    // P02: volume 60, MOD first in the chain, AMP on with model 7 and its
    // first knob at 44; a 5-band EQ at the head.
    final int p02 = presetSize;
    a[p02] = 60;
    a.setAll(p02 + 2, <int>[2, 0, 1, 3, 5, 4]);
    a[p02 + 8 + 1] = 1;
    a[p02 + 14 + 1] = 7;
    a[p02 + 14 + 3] = 9; // DLY has 5 models: 9 stays a number
    a.setAll(p02 + 20 + 12, <int>[44, 0]);
    final int eq = eqTableAddress + eqHeaderLength;
    a.setAll(eq + eqRecordLength, <int>[1, 1, 6, 0xFA, 0, 0, 3]);

    final PresetBackup b = PresetBackup(
      identity: 'Pocket AMP_105',
      created: DateTime.utc(2026),
      presets: Uint8List.sublistView(a, 0, eqTableAddress),
      eq: Uint8List.sublistView(a, eqTableAddress),
    );
    final Map<String, Object?> file =
        jsonDecode(b.toJson()) as Map<String, Object?>;
    expect(file['format'], 'pocket-amp-upgrader/presets@3');
    final List<Object?> presets = file['presets']! as List<Object?>;
    expect(presets, hasLength(presetCount));
    final Map<String, Object?> p = presets[1]! as Map<String, Object?>;
    expect(p['chain'], <Object>['MOD', 'FX', 'AMP', 'DLY', 'CAB', 'REV']);
    final Map<String, Object?> blocks = p['blocks']! as Map<String, Object?>;
    expect(blocks['AMP'], <String, Object>{
      'on': true,
      'model': '8DARKS_DS',
      'knobs': <Map<String, Object>>[
        <String, Object>{'label': 'Gain', 'value': 44},
        <String, Object>{'label': 'Level', 'value': 0},
        <String, Object>{'label': 'Bass', 'value': 0},
        <String, Object>{'label': 'Mid', 'value': 0},
        <String, Object>{'label': 'Treble', 'value': 0},
        <String, Object>{'label': 'knob6 (unused)', 'value': 0},
      ],
    });
    expect((blocks['DLY']! as Map<String, Object?>)['model'], 9);
    expect(p['eq'], <String, Object>{
      'on': true,
      'position': 'head',
      'bands': <Map<String, Object>>[
        <String, Object>{'label': '100Hz', 'value': 6},
        <String, Object>{'label': '250Hz', 'value': -6},
        <String, Object>{'label': '800Hz', 'value': 0},
        <String, Object>{'label': '2kHz', 'value': 0},
        <String, Object>{'label': '10kHz', 'value': 3},
      ],
    });

    // Editing a field changes what is restored. The label is not read: the
    // position decides the knob.
    final List<Object?> ampKnobs =
        (blocks['AMP']! as Map<String, Object?>)['knobs']! as List<Object?>;
    (ampKnobs[4]! as Map<String, Object?>)
      ..['label'] = 'Treble (renamed)'
      ..['value'] = 70;
    (blocks['AMP']! as Map<String, Object?>)['model'] = '3JC120_CL';
    final PresetBackup edited = PresetBackup.fromJson(jsonEncode(file));
    final Uint8List want = Uint8List.fromList(b.presets)
      ..[p02 + 20 + 12 + 8] = 70
      ..[p02 + 14 + 1] = 2;
    expect(edited.presets, want);
    expect(edited.eq, b.eq);
  });

  test('every byte survives the trip through the named fields', () {
    // Every value the pedal keeps: volume and knobs 0..100, any order of
    // the chain, on/off, any model byte, EQ bands -6..6.
    final Random r = Random(11);
    final Uint8List a = Uint8List(eqTableAddress + eqTableLength)
      ..setAll(eqTableAddress, eqHeader);
    for (int id = 0; id < presetCount; id++) {
      final int p = id * presetSize;
      a[p] = r.nextInt(101);
      a.setAll(p + 2, <int>[0, 1, 2, 3, 4, 5]..shuffle(r));
      for (int b = 0; b < 6; b++) {
        a[p + 8 + b] = r.nextInt(2);
        a[p + 14 + b] = r.nextInt(256);
        for (int k = 0; k < 6; k++) {
          a[p + 20 + b * 12 + k * 2] = r.nextInt(101);
        }
      }
      a.setAll(eqTableAddress + eqHeaderLength + id * eqRecordLength, <int>[
        r.nextInt(2),
        r.nextInt(2),
        for (int band = 0; band < 5; band++) (r.nextInt(13) - 6) & 0xFF,
      ]);
    }
    final PresetBackup b = PresetBackup(
      identity: 'x',
      created: DateTime.utc(2026),
      presets: Uint8List.sublistView(a, 0, eqTableAddress),
      eq: Uint8List.sublistView(a, eqTableAddress),
    );
    final PresetBackup back = PresetBackup.fromJson(b.toJson());
    expect(back.presets, b.presets);
    expect(back.eq, b.eq);
  });

  test('an edit the pedal cannot take is refused with its place', () {
    final PresetBackup b = PresetBackup(
      identity: 'x',
      created: DateTime.utc(2026),
      presets: Uint8List(presetCount * presetSize),
      eq: Uint8List(eqTableLength)..setAll(0, eqHeader),
    );
    Map<String, Object?> file() =>
        jsonDecode(b.toJson()) as Map<String, Object?>;
    Map<String, Object?> block(Map<String, Object?> f, String name) =>
        (((f['presets']! as List<Object?>)[2]!
                    as Map<String, Object?>)['blocks']!
                as Map<String, Object?>)[name]!
            as Map<String, Object?>;
    void refused(Map<String, Object?> f, String message) => expect(
      () => PresetBackup.fromJson(jsonEncode(f)),
      throwsA(
        isA<FormatException>().having(
          (FormatException e) => e.message,
          'message',
          contains(message),
        ),
      ),
    );

    final Map<String, Object?> model = file();
    block(model, 'MOD')['model'] = 'Wah';
    refused(model, 'P03 MOD.model: "Wah" is not one of Chorus');

    final Map<String, Object?> knobs = file();
    (block(knobs, 'MOD')['knobs']! as List<Object?>).removeLast();
    refused(knobs, 'P03 MOD.knobs: expected a list of 6 knob values');

    final Map<String, Object?> noValue = file();
    (block(noValue, 'MOD')['knobs']! as List<Object?>)[0] = <String, Object>{
      'label': 'Speed',
    };
    refused(noValue, 'P03 MOD.knobs: each knob needs a "value"');

    // Knobs by name, as version 2 files have them: the names must follow
    // the model. Phaser has four knobs, Chorus three.
    final Map<String, Object?> named = file();
    block(named, 'MOD')
      ..['model'] = 'Phaser'
      ..['knobs'] = <String, int>{
        'Speed': 0,
        'Depth': 0,
        'Mix': 0,
        'knob4': 0,
        'knob5': 0,
        'knob6': 0,
      };
    refused(
      named,
      'P03 MOD.knobs: expected a list of 6 knob values, or '
      'exactly Speed, MidCut (ParamA), Reso (ParamB), Fb, knob5, knob6',
    );

    // A version 2 file names Phaser's knobs as they were then.
    final Map<String, Object?> former = file();
    block(former, 'MOD')
      ..['model'] = 'Phaser'
      ..['knobs'] = <String, int>{
        'Speed': 1,
        'ParamA': 2,
        'ParamB': 3,
        'Fb': 4,
        'knob5': 5,
        'knob6': 6,
      };
    final PresetBackup fromFormer = PresetBackup.fromJson(jsonEncode(former));
    expect(
      <int>[for (int k = 0; k < 6; k++) fromFormer.knob(2, 2, k)],
      <int>[1, 2, 3, 4, 5, 6],
    );

    final Map<String, Object?> range = file();
    ((block(range, 'AMP')['knobs']! as List<Object?>)[0]!
            as Map<String, Object?>)['value'] =
        70000;
    refused(range, 'P03 AMP.Gain: expected a whole number from 0 to 65535');

    final Map<String, Object?> order = file();
    (order['presets']! as List<Object?>).removeAt(0);
    refused(order, 'must list all 80 presets');
  });

  test('a version 2 backup, with knobs by name, still restores', () {
    final Uint8List a = bank();
    final PresetBackup b = PresetBackup(
      identity: 'x',
      created: DateTime.utc(2026),
      presets: Uint8List.sublistView(a, 0, eqTableAddress),
      eq: Uint8List.sublistView(a, eqTableAddress),
    );
    final Map<String, Object?> file =
        jsonDecode(b.toJson()) as Map<String, Object?>;
    file['format'] = 'pocket-amp-upgrader/presets@2';
    for (final Object? p in file['presets']! as List<Object?>) {
      final Map<String, Object?> blocks =
          (p! as Map<String, Object?>)['blocks']! as Map<String, Object?>;
      for (final String name in blockNames) {
        final Map<String, Object?> block =
            blocks[name]! as Map<String, Object?>;
        final List<Object?> list = block['knobs']! as List<Object?>;
        final Object? m = block['model'];
        final int index = m is int
            ? m
            : blockModels[name]!.indexWhere(
                ((String, List<String>) e) => e.$1 == m,
              );
        expect(index, isNonNegative, reason: '$m');
        block['knobs'] = <String, Object?>{
          for (final (int k, String n) in knobNames(name, index).indexed)
            n: (list[k]! as Map<String, Object?>)['value'],
        };
      }
    }
    final PresetBackup v2 = PresetBackup.fromJson(jsonEncode(file));
    expect(v2.presets, b.presets);
    expect(v2.eq, b.eq);
  });

  test('a version 1 backup is restored from its raw data', () {
    final Uint8List a = bank();
    final PresetBackup b = PresetBackup(
      identity: 'x',
      created: DateTime.utc(2026),
      presets: Uint8List.sublistView(a, 0, eqTableAddress),
      eq: Uint8List.sublistView(a, eqTableAddress),
    );
    final PresetBackup v1 = PresetBackup.fromJson(
      jsonEncode(<String, Object>{
        'format': 'pocket-amp-upgrader/presets@1',
        'pedal': 'x',
        'created': '2026-01-01T00:00:00.000Z',
        'readable': <Object>[],
        'presets': base64Encode(b.presets),
        'eq': base64Encode(b.eq),
      }),
    );
    expect(v1.presets, b.presets);
    expect(v1.eq, b.eq);
  });

  test(
    'an EQ record the app cannot write is left as it is; the rest restores',
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
      final PresetDiff d = await restorePresetBank(s, odd);
      expect(d.presets, <int>[0]);
      expect(d.eq, isEmpty);
      expect(d.skippedEq, <int>[1]);
      expect(pedal.writes, <String>['preset 0', 'commit']);
      expect(pedal.flash.sublist(0, presetSize), odd.preset(0));
      await s.close();
    },
  );

  test('restore with nothing to do still stores, once', () async {
    final FakeBank pedal = FakeBank(bank());
    final PresetSession s = PresetSession(pedal);
    final PresetBackup saved = await readPresetBank(s, 'x');
    expect((await restorePresetBank(s, saved)).isEmpty, isTrue);
    expect(pedal.writes, <String>['commit']);
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

  test('a PIXIE1 V0.07 raw copy restores P01..P79 and nothing else', () async {
    // The raw copy attached to issue #10, read from a PIXIE1 on V0.07.
    final Uint8List raw = File('test/fixtures/raw-PIXIE1_007.bin')
        .readAsBytesSync();
    expect(isOldPresetArea(raw), isTrue);
    // Past byte 7296 the pedal answered with filler: the request's checksum
    // (0xDF for the read at 7296) and seven zeros.
    expect(raw.sublist(7296, 7304), <int>[0xDF, 0, 0, 0, 0, 0, 0, 0]);

    final FakeBank pedal = FakeBank(bank());
    final PresetSession s = PresetSession(pedal);
    final PresetBackup now = await readPresetBank(s, 'Pocket AMP_105');
    final PresetBackup b = now.withOldPresets(raw);
    expect(b.presets.sublist(0, 7268), raw.sublist(0, 7268));
    expect(b.preset(79), now.preset(79));
    expect(b.eq, now.eq);
    // The old presets go through the same checks and writes as a backup.
    final PresetDiff d = await restorePresetBank(s, b, expected: now);
    expect(d.eq, isEmpty);
    expect(d.presets.every((int id) => id < 79), isTrue);
    expect(pedal.flash.sublist(0, 7268), raw.sublist(0, 7268));
    expect(PresetBackup.fromJson(b.toJson()).presets, b.presets);
    await s.close();
  });

  test('a PIXIE1 V0.07 raw copy opens P01..P79 to view only', () async {
    final Uint8List raw = File('test/fixtures/raw-PIXIE1_007.bin')
        .readAsBytesSync();
    final PresetBackup b = PresetBackup.oldLayout('PIXIE1_007', raw);
    expect(b.usableCount, 79);
    expect(b.presets.sublist(0, 7268), raw.sublist(0, 7268));
    expect(b.copy().oldLayout, isTrue);
    expect(b.toJson, throwsStateError);
    final FakeBank pedal = FakeBank(bank());
    final PresetSession s = PresetSession(pedal);
    await expectLater(
      restorePresetBank(s, b),
      throwsA(isA<PresetIoException>()),
    );
    expect(pedal.writes, isEmpty);
    await s.close();
    expect(
      () => PresetBackup.oldLayout('x', raw.sublist(0, 7000)),
      throwsFormatException,
    );
  });

  test('a raw copy in another layout is refused', () {
    final Uint8List raw = File('test/fixtures/raw-PIXIE1_007.bin')
        .readAsBytesSync();
    final Uint8List odd = Uint8List.fromList(raw)..[40 * 92 + 3] = 7;
    expect(isOldPresetArea(odd), isFalse);
    expect(isOldPresetArea(raw.sublist(0, 7000)), isFalse);
    expect(
      () => PresetBackup(
        identity: 'x',
        created: DateTime(2026),
        presets: bank().sublist(0, eqTableAddress),
        eq: bank().sublist(eqTableAddress),
      ).withOldPresets(odd),
      throwsFormatException,
    );
  });

  test('a backup keeps an EQ record Save EQ does not take', () async {
    // A stored record outside what Save EQ takes: position 2, bands outside
    // -6..6. The file must still reopen with the same bytes.
    final Uint8List a = bank()
      ..setAll(eqTableAddress + eqHeaderLength, <int>[1, 2, 9, 0, 0, 0xF0, 0]);
    final PresetSession s = PresetSession(FakeBank(a));
    final PresetBackup saved = await readPresetBank(s, 'x');
    await s.close();
    final PresetBackup back = PresetBackup.fromJson(saved.toJson());
    expect(back.eq, saved.eq);
    expect(back.presets, saved.presets);
  });

  test('a restore whose store was lost is stored by the next one', () async {
    final _DropCommit pedal = _DropCommit(bank());
    final PresetSession s = PresetSession(pedal);
    final PresetBackup saved = await readPresetBank(s, 'x');
    final PresetBackup want = saved.copy()..setVolume(0, 10);
    await expectLater(
      restorePresetBank(s, want),
      throwsA(isA<PresetIoException>()),
    );
    pedal.drop = false;
    await restorePresetBank(s, want);
    expect(pedal.flash.sublist(0, 2), <int>[10, 0]);
    await s.close();
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('a slow store is not sent again', () async {
    final _DropCommit pedal = _DropCommit(bank())
      ..drop = false
      ..commitDelay = const Duration(milliseconds: 2500);
    final PresetSession s = PresetSession(pedal);
    final PresetBackup saved = await readPresetBank(s, 'x');
    await restorePresetBank(s, saved.copy()..setVolume(0, 11));
    expect(pedal.commits, 1);
    expect(pedal.flash.sublist(0, 2), <int>[11, 0]);
    await s.close();
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('a file cannot put a model the pedal lacks into a slot', () async {
    final FakeBank pedal = FakeBank(bank());
    final PresetSession s = PresetSession(pedal);
    final PresetBackup saved = await readPresetBank(s, 'x');
    final Map<String, Object?> j =
        jsonDecode(saved.toJson()) as Map<String, Object?>;
    final Map<String, Object?> amp =
        ((((j['presets']! as List<Object?>)[0]!
                    as Map<String, Object?>)['blocks']!
                as Map<String, Object?>)['AMP']!
            as Map<String, Object?>);
    amp['model'] = 20; // AMP has 20 models: 0..19
    amp['knobs'] = <String, int>{for (int k = 1; k <= 6; k++) 'knob$k': 50};
    await expectLater(
      restorePresetBank(s, PresetBackup.fromJson(jsonEncode(j))),
      throwsA(isA<PresetIoException>()),
    );
    expect(pedal.writes, isEmpty);
    await s.close();
  });

  test("a backup holding the pedal's own chain order restores", () async {
    // The firmware stores orders a live Change Routing would not take (a
    // factory preset does); restoring one must work.
    final Uint8List now = bank()..setAll(2, <int>[0, 1, 2, 3, 4, 5]);
    final Uint8List then = bank()..setAll(2, <int>[0, 2, 1, 5, 4, 3]);
    final PresetBackup old = PresetBackup(
      identity: 'x',
      created: DateTime(2026),
      presets: Uint8List.sublistView(then, 0, eqTableAddress),
      eq: Uint8List.sublistView(then, eqTableAddress),
    );
    final FakeBank pedal = FakeBank(now);
    final PresetSession s = PresetSession(pedal);
    await restorePresetBank(s, old);
    expect(pedal.flash.sublist(2, 8), <int>[0, 2, 1, 5, 4, 3]);
    await s.close();
  });

  test('writing again completes a write whose store was lost', () async {
    final _DropCommit pedal = _DropCommit(bank());
    final PresetSession s = PresetSession(pedal);
    final PresetBackup read = await readPresetBank(s, 'x');
    final PresetBackup draft = read.copy()..setVolume(0, 10);
    await expectLater(
      restorePresetBank(s, draft, expected: read),
      throwsA(isA<PresetIoException>()),
    );
    pedal.drop = false;
    // The editor writes again against what it read: the mirror already
    // holds the draft, which must not count as "the pedal changed".
    await restorePresetBank(s, draft, expected: read);
    expect(pedal.flash.sublist(0, 2), <int>[10, 0]);
    await s.close();
  }, timeout: const Timeout(Duration(seconds: 40)));
}

/// Ignores Commit while [drop]; can answer it late, and counts them.
class _DropCommit extends FakeBank {
  _DropCommit(super.flash);
  bool drop = true;
  Duration commitDelay = Duration.zero;
  int commits = 0;

  @override
  Future<void> send(Uint8List sysex) async {
    final Uint8List p = mefcsUnwrap(sysex)!;
    if (p[2] == 0x22 && p[10] == 0xF0) {
      commits++;
      if (drop) {
        return;
      }
      if (commitDelay > Duration.zero) {
        await Future<void>.delayed(commitDelay);
      }
    }
    return super.send(sysex);
  }
}
