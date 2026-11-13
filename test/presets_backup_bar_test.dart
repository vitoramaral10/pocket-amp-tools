import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_tools/src/presets/mefcs.dart';
import 'package:pocket_amp_tools/src/presets/preset_backup.dart';
import 'package:pocket_amp_tools/src/ui/presets_page.dart';

import 'support/fake_pedal.dart';

PresetBackup _of(Uint8List area) => PresetBackup(
  identity: 'Pocket AMP_105',
  created: DateTime.utc(2026),
  presets: Uint8List.sublistView(area, 0, eqTableAddress),
  eq: Uint8List.sublistView(area, eqTableAddress),
);

Future<void> _show(
  WidgetTester t,
  PresetWorkspace w,
  VoidCallback onWrite, {
  VoidCallback? onRead,
}) {
  t.view.physicalSize = const Size(1400, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  return t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PresetsPage(
          workspace: w,
          canUsePedal: true,
          busy: false,
          task: null,
          fraction: null,
          message: null,
          messageIsError: false,
          onRead: onRead ?? () {},
          onWrite: onWrite,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a backup in the editor is marked and can be restored', (
    t,
  ) async {
    final PresetWorkspace w = PresetWorkspace()
      ..load(_of(demoBank()), 'b.json', fromBackup: true);
    int writes = 0;
    await _show(t, w, () => writes++);

    expect(find.textContaining('Viewing a backup'), findsOneWidget);
    await t.tap(find.text('Restore to pedal…'));
    expect(writes, 1);

    w.written(w.draft!.copy());
    await t.pump();
    expect(find.textContaining('Viewing a backup'), findsNothing);
  });

  testWidgets('back to the pedal drops the backup for what was read', (
    t,
  ) async {
    final Uint8List other = demoBank()..[0] ^= 1;
    final PresetWorkspace w = PresetWorkspace()
      ..load(_of(demoBank()), 'pedal', fromPedal: true)
      ..load(_of(other), 'b.json', fromBackup: true);
    await _show(t, w, () {});
    expect(w.changed, isNotEmpty);

    await t.tap(find.text('Back to the pedal'));
    await t.pump();

    expect(find.textContaining('Viewing a backup'), findsNothing);
    expect(w.changed, isEmpty);
    expect(w.draft!.presets, w.onPedal!.presets);
  });

  testWidgets('back to the pedal reads it when nothing was read yet', (
    t,
  ) async {
    int reads = 0;
    final PresetWorkspace w = PresetWorkspace()
      ..load(_of(demoBank()), 'b.json', fromBackup: true);
    await _show(t, w, () {}, onRead: () => reads++);

    await t.tap(find.text('Back to the pedal'));
    expect(reads, 1);
  });

  testWidgets('presets read from the pedal show no backup bar', (t) async {
    final PresetWorkspace w = PresetWorkspace()
      ..load(_of(demoBank()), 'pedal', fromPedal: true);
    await _show(t, w, () {});
    expect(find.textContaining('Viewing a backup'), findsNothing);
  });
}
