import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_tools/src/presets/preset_backup.dart';
import 'package:pocket_amp_tools/src/ui/backups_page.dart';

void main() {
  testWidgets('backing up now reloads the list without a setState error', (
    t,
  ) async {
    int listed = 0;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BackupsPage(
            list: () async {
              listed++;
              return <(File, PresetBackup?, String?)>[];
            },
            canRestore: true,
            onEdit: (_, _) {},
            onRestore: (_, _) {},
            onRestoreRaw: (_) {},
            onSaveNew: () async {},
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(listed, 1);

    await t.tap(find.text('Back up the pedal now'));
    await t.pumpAndSettle();

    expect(t.takeException(), isNull);
    expect(listed, 2);
  });

  testWidgets('deleting a backup asks first, removes the file and reloads', (
    t,
  ) async {
    final Directory dir = (await t.runAsync(
      () => Directory.systemTemp.createTemp('backups_page_test'),
    ))!;
    addTearDown(() => dir.delete(recursive: true));
    final File f = File('${dir.path}/raw.bin')..writeAsBytesSync(<int>[0]);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BackupsPage(
            list: () async => <(File, PresetBackup?, String?)>[
              if (f.existsSync()) (f, null, null),
            ],
            canRestore: false,
            onEdit: (_, _) {},
            onRestore: (_, _) {},
            onRestoreRaw: (_) {},
            onSaveNew: () async {},
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('raw.bin'), findsOneWidget);

    await t.tap(find.byTooltip('Delete backup'));
    await t.pumpAndSettle();
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(f.existsSync(), isTrue);

    await t.tap(find.byTooltip('Delete backup'));
    await t.pumpAndSettle();
    await t.runAsync(() async {
      await t.tap(find.widgetWithText(FilledButton, 'Delete'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    for (int i = 0; i < 5; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump();
    }

    expect(f.existsSync(), isFalse);
    expect(find.text('raw.bin'), findsNothing);
    expect(find.text('No backups yet.'), findsOneWidget);
  });
}
