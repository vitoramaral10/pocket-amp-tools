// SPDX-License-Identifier: GPL-3.0-only
//
// A capture made with its cabinet already sounds like a whole rig: a preset
// that plays it must not go through the pedal's CAB block too.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_tools/src/library/library.dart';
import 'package:pocket_amp_tools/src/presets/mefcs.dart';
import 'package:pocket_amp_tools/src/presets/preset_backup.dart';
import 'package:pocket_amp_tools/src/ui/presets_page.dart';

import 'support/fake_pedal.dart';

const int amp = 1, cab = 5;

PresetBackup _of(Uint8List area) => PresetBackup(
  identity: 'Pocket AMP_105',
  created: DateTime.utc(2026),
  presets: Uint8List.sublistView(area, 0, eqTableAddress),
  eq: Uint8List.sublistView(area, eqTableAddress),
);

/// The A2 fixture, saying in its metadata that it holds [gear].
Uint8List capture({String? gear}) {
  final Map<String, dynamic> j = jsonDecode(
    File('test/fixtures/a2_lite_synthetic.nam').readAsStringSync(),
  ) as Map<String, dynamic>;
  if (gear != null) {
    (j['metadata'] ??= <String, dynamic>{}) as Map<String, dynamic>;
    (j['metadata'] as Map<String, dynamic>)['gear_type'] = gear;
  }
  return Uint8List.fromList(utf8.encode(jsonEncode(j)));
}

void main() {
  late Directory tmp;
  late Library lib;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('withcab');
    lib = Library(Directory('${tmp.path}/Library'));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test(
    'the library knows which slots hold a capture with its cabinet',
    () async {
      final LibraryItem rig = await lib.import(
        LibraryKind.amp,
        'Rig.nam',
        capture(gear: 'amp_cab'), // said by the file itself
      );
      final LibraryItem head = await lib.import(
        LibraryKind.amp,
        'Head.nam',
        capture(gear: 'amp'),
      );
      LibraryItem marked = await lib.import(
        LibraryKind.amp,
        'From TONE3000.nam',
        capture(),
      );
      await lib.markWithCab(marked); // said by TONE3000
      await lib.link(LibraryKind.amp, 2, rig);
      await lib.link(LibraryKind.amp, 3, head);
      await lib.link(LibraryKind.amp, 4, marked);
      expect(await lib.ampSlotsWithCab(), <int>{2, 4});

      marked = await lib.rename(marked, 'Renamed');
      expect(await lib.ampSlotsWithCab(), <int>{2, 4});

      await lib.delete(rig);
      expect(await lib.ampSlotsWithCab(), <int>{4});

      // A file added again under the old name is not taken for the old one.
      final LibraryItem again = await lib.import(
        LibraryKind.amp,
        'Rig.nam',
        capture(gear: 'amp'),
      );
      await lib.link(LibraryKind.amp, 2, again);
      expect(await lib.ampSlotsWithCab(), <int>{4});
    },
  );

  test('picking such a capture in the editor turns the CAB off', () async {
    final PresetWorkspace w = PresetWorkspace()
      ..load(_of(demoBank()), 'x', fromPedal: true)
      ..ampWithCab = <int>{7};
    final PresetBackup d = w.draft!;
    d.setOn(0, cab, true);
    d.setOn(1, cab, true);

    await w.changeModel(0, amp, 6);
    expect(d.isOn(0, cab), isTrue, reason: 'an amp without its cabinet');
    await w.changeModel(0, amp, 7);
    expect(d.isOn(0, cab), isFalse);
    await w.changeModel(1, 3, 7); // model 7 of another block
    expect(d.isOn(1, cab), isTrue);
    expect(w.unsaved, contains(0));
  });

  test('sending it to a slot turns the CAB off where that slot plays', () {
    final PresetWorkspace w = PresetWorkspace()
      ..load(_of(demoBank()), 'x', fromPedal: true);
    final PresetBackup d = w.draft!;
    for (int id = 0; id < presetCount; id++) {
      d.setModel(id, amp, id == 3 || id == 9 ? 12 : 0);
      d.setOn(id, cab, true);
    }
    d.setOn(9, cab, false);
    expect(w.cabOffForAmp(12), <int>[3]);
    expect(d.isOn(3, cab), isFalse);
    expect(d.isOn(4, cab), isTrue);
    expect(w.unsaved, contains(3), reason: 'kept as edits until written');
  });
}
