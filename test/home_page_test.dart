import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_tools/src/library/library.dart';
import 'package:pocket_amp_tools/src/presets/mefcs.dart';
import 'package:pocket_amp_tools/src/ui/home_page.dart';

import 'support/fake_pedal.dart';

void main() {
  testWidgets(
    'detects the pedal on start and keeps update disabled without a package',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final FakePedal pedal = FakePedal(
        image: Uint8List(1024),
        bank: demoBank(),
      );
      await tester.pumpWidget(MaterialApp(home: HomePage(backend: pedal)));
      await tester.tap(find.text('Firmware'));
      await tester.pump();

      final Finder update = find.ancestor(
        of: find.text('Update firmware'),
        matching: find.byWidgetPredicate((Widget w) => w is ButtonStyleButton),
      );
      expect(tester.widget<ButtonStyleButton>(update).onPressed, isNull);

      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(seconds: 2));
      });
      await tester.pump();

      expect(find.text('1.03'), findsOneWidget);
      expect(find.byTooltip('Detect again'), findsOneWidget);
      expect(tester.widget<ButtonStyleButton>(update).onPressed, isNull);
      // Let the presets read that starts on detection finish.
      for (int i = 0; i < 400; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 50));
      }
    },
  );

  testWidgets('the library adds a capture and sends it to an AMP slot', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final Directory tmp = Directory.systemTemp.createTempSync('library_ui_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final Library lib = Library(Directory('${tmp.path}/Library'));
    await tester.runAsync(
      () => lib.import(
        LibraryKind.amp,
        'My Capture.nam',
        File('test/fixtures/a2_lite_synthetic.nam').readAsBytesSync(),
      ),
    );
    final FakePedal pedal = FakePedal(image: Uint8List(1024), bank: demoBank());
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(backend: pedal, libraryRoot: lib.root),
      ),
    );
    Future<void> settle([int n = 40]) async {
      for (int i = 0; i < n; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await settle(400); // detection, then the presets read it starts
    await tester.tap(find.text('Library'));
    await settle();
    expect(find.text('My Capture'), findsOneWidget);
    expect(find.text('Load from library…'), findsNWidgets(20));

    await tester.tap(find.text('Send to pedal…'));
    await settle(5);
    await tester.tap(find.textContaining('20.  '));
    await settle(5);
    expect(find.text('Replace AMP slot 20?'), findsOneWidget);
    await tester.tap(find.text('Replace'));
    await settle(80);
    expect(pedal.ampNames[19], 'My Capture');
    expect(find.text('From your library: My Capture'), findsOneWidget);
    expect(find.text('In slot 20'), findsOneWidget);

    await tester.tap(find.text('Cabinets'));
    await settle();
    expect(find.text('Add WAV files…'), findsOneWidget);
  });

  testWidgets('on a phone the library sends a file from its menu', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final Directory tmp = Directory.systemTemp.createTempSync('library_ui_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final Library lib = Library(Directory('${tmp.path}/Library'));
    await tester.runAsync(
      () => lib.import(
        LibraryKind.amp,
        'A Capture With A Long Name.nam',
        File('test/fixtures/a2_lite_synthetic.nam').readAsBytesSync(),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          backend: FakePedal(image: Uint8List(1024), bank: demoBank()),
          libraryRoot: lib.root,
        ),
      ),
    );
    Future<void> settle([int n = 40]) async {
      for (int i = 0; i < n; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await settle(400); // detection, then the presets read it starts
    await tester.tap(find.text('Library'));
    await settle();
    // The button would leave the name a few letters: it is in the menu.
    expect(find.text('Send to pedal…'), findsNothing);
    final double name = tester
        .getSize(find.text('A Capture With A Long Name'))
        .width;
    expect(name, greaterThan(150));
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(ListTile, 'A Capture With A Long Name'),
        matching: find.byTooltip('More'),
      ),
    );
    await settle(5);
    await tester.tap(find.text('Send to pedal…'));
    await settle(5);
    expect(find.textContaining('20.  '), findsOneWidget);
  });

  testWidgets('edits a preset and writes only that one to the pedal', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final Uint8List bank = demoBank();
    final Uint8List before = Uint8List.fromList(bank);
    final FakePedal pedal = FakePedal(image: Uint8List(1024), bank: bank)
      ..ampNames[1] = '2MyOwnAmp';
    await tester.pumpWidget(MaterialApp(home: HomePage(backend: pedal)));
    // Detection runs on real time; preset traffic on the test clock.
    Future<void> settle() async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      for (int i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    // Presets are read on detection, with no tap.
    for (int i = 0; i < 10 && find.text('P03').evaluate().isEmpty; i++) {
      await settle();
    }
    expect(find.text('Read all 80 presets and their EQ.'), findsOneWidget);

    // AMP names come from the pedal: P01 uses AMP model 2, renamed here.
    expect(find.text('2MyOwnAmp'), findsWidgets);

    await tester.tap(find.text('P03'));
    await settle();
    expect(pedal.active, 2, reason: 'selecting a preset plays it');
    final bool wasOn = bank[2 * presetSize + 8 + 3] != 0; // DLY of P03
    // As in M-EFCS, a block's card opens from its chip in the chain.
    await tester.tap(find.text('DLY'));
    await settle();
    await tester.tap(
      find.descendant(
        of: find.ancestor(of: find.text('DLY'), matching: find.byType(Card)),
        matching: find.byType(Switch),
      ),
    );
    await settle();
    expect(
      pedal.liveWrites.last,
      '11=${wasOn ? 0 : 1}',
      reason: 'the change is heard right away',
    );
    await tester.tap(find.text('Write 1 preset to pedal'));
    // The setting for asking first is read from disk.
    await settle();
    expect(find.text('Write presets to the pedal?'), findsOneWidget);
    await tester.tap(find.text('Write'));
    await settle();
    await settle();

    expect(bank[2 * presetSize + 8 + 3] != 0, !wasOn);
    bank[2 * presetSize + 8 + 3] = before[2 * presetSize + 8 + 3];
    expect(bank, before, reason: 'nothing else changed');
    expect(find.textContaining('Written and checked'), findsOneWidget);
  });

  testWidgets('never holds two sessions, even while live editing opens', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final FakePedal pedal = FakePedal(image: Uint8List(1024), bank: demoBank());
    await tester.pumpWidget(MaterialApp(home: HomePage(backend: pedal)));
    Future<void> settle() async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      for (int i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await settle();
    await tester.tap(find.text('Read presets from the pedal'));
    for (int i = 0; i < 10 && find.text('P03').evaluate().isEmpty; i++) {
      await settle();
    }
    expect(pedal.openNow, 1, reason: 'live editing is on');

    // Detect again; hold the live link's reopening half way.
    final int before = pedal.opens;
    pedal
      ..hold = Completer<void>()
      ..holdAt = before + 2; // detection's open, then the live link's
    await tester.tap(find.byTooltip('Detect again'));
    for (int i = 0; i < 10 && pedal.opens < before + 2; i++) {
      await settle();
    }
    expect(pedal.opens, before + 2, reason: 'the live link is opening');

    // Another operation now must wait for that open and close it first;
    // a second request in the same frame must not start a second one.
    await tester.tap(find.byTooltip('Preset actions'));
    await tester.pump();
    final VoidCallback readNow = tester
        .widget<MenuItemButton>(
          find.widgetWithText(MenuItemButton, 'Read again from pedal'),
        )
        .onPressed!;
    readNow();
    readNow();
    await settle();
    pedal.hold!.complete();
    // Success is a passing SnackBar: watch for it while things settle.
    bool read = false;
    for (int i = 0; i < 6; i++) {
      await settle();
      read |= find
          .text('Read all 80 presets and their EQ.')
          .evaluate()
          .isNotEmpty;
    }
    expect(pedal.maxOpen, 1);
    expect(read, isTrue);
  });

  group('live link and unsaved edits', () {
    late FakePedal pedal;

    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      for (int i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    Future<void> start(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      pedal = FakePedal(image: Uint8List(1024), bank: demoBank());
      await tester.pumpWidget(MaterialApp(home: HomePage(backend: pedal)));
      await settle(tester);
      await tester.tap(find.text('Read presets from the pedal'));
      for (int i = 0; i < 10 && find.text('P03').evaluate().isEmpty; i++) {
        await settle(tester);
      }
    }

    Future<void> editP03(WidgetTester tester) async {
      await tester.tap(find.text('P03'));
      await settle(tester);
      await tester.tap(find.text('DLY'));
      await settle(tester);
      await tester.tap(
        find.descendant(
          of: find.ancestor(of: find.text('DLY'), matching: find.byType(Card)),
          matching: find.byType(Switch),
        ),
      );
      await settle(tester);
    }

    testWidgets('reading while live drains does not open a second session', (
      WidgetTester tester,
    ) async {
      await start(tester);
      pedal.holdSend = Completer<void>();
      await tester.tap(find.text('P03')); // show() now waits in a send
      await tester.pump();
      await readAgain(tester);
      await tester.pump();
      pedal.holdSend!.complete();
      pedal.holdSend = null;
      for (int i = 0; i < 6; i++) {
        await settle(tester);
      }
      expect(pedal.maxOpen, 1);
    });

    testWidgets('reading again asks before dropping edits', (
      WidgetTester tester,
    ) async {
      await start(tester);
      await editP03(tester);
      expect(find.text('Write 1 preset to pedal'), findsOneWidget);
      await readAgain(tester);
      await tester.pumpAndSettle();
      expect(find.text('Read the presets again?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('Write 1 preset to pedal'), findsOneWidget);
    });

    testWidgets('detecting with the pedal unplugged keeps the edits tracked', (
      WidgetTester tester,
    ) async {
      await start(tester);
      await editP03(tester);
      pedal.present = false;
      await tester.tap(find.byTooltip('Detect again'));
      for (
        int i = 0;
        i < 60 && find.text('No pedal connected').evaluate().isEmpty;
        i++
      ) {
        await settle(tester);
      }
      expect(find.text('No pedal connected'), findsOneWidget);
      pedal.present = true;
      await tester.tap(find.byTooltip('Detect pedal'));
      for (int i = 0; i < 20 && pedal.openNow == 0; i++) {
        await settle(tester);
      }
      expect(find.text('Write 1 preset to pedal'), findsOneWidget);
      expect(pedal.openNow, 1, reason: 'the live link is open again');
    });

    testWidgets('unplugging the pedal with nothing edited clears the editor', (
      WidgetTester tester,
    ) async {
      await start(tester);
      expect(find.text('P03'), findsWidgets);
      pedal.present = false;
      for (
        int i = 0;
        i < 60 && find.text('No pedal connected').evaluate().isEmpty;
        i++
      ) {
        await settle(tester);
      }
      expect(find.text('No pedal connected'), findsOneWidget);
      expect(find.text('P03'), findsNothing);

      pedal.present = true;
      for (int i = 0; i < 60 && find.text('P03').evaluate().isEmpty; i++) {
        await settle(tester);
      }
      expect(find.text('P03'), findsWidgets, reason: 'read again on its own');
    });

    testWidgets('unplugging and plugging the pedal back needs no click', (
      WidgetTester tester,
    ) async {
      await start(tester);
      await editP03(tester);
      pedal.present = false;
      for (
        int i = 0;
        i < 60 && find.text('No pedal connected').evaluate().isEmpty;
        i++
      ) {
        await settle(tester);
      }
      expect(find.text('No pedal connected'), findsOneWidget);
      pedal.present = true;
      for (int i = 0; i < 60 && pedal.openNow == 0; i++) {
        await settle(tester);
      }
      expect(find.text('Write 1 preset to pedal'), findsOneWidget);
      expect(pedal.openNow, 1, reason: 'the live link is open again');
    });
  });

  testWidgets('an EQ the app cannot write back is shown, and can be reset', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // P01's EQ is a record Save EQ does not take (position 2, bands 9 and -16).
    final Uint8List bank = demoBank()
      ..setAll(eqTableAddress + eqHeaderLength, <int>[1, 2, 9, 0, 0, 0xF0, 0]);
    final FakePedal pedal = FakePedal(image: Uint8List(1024), bank: bank);
    await tester.pumpWidget(MaterialApp(home: HomePage(backend: pedal)));
    Future<void> settle() async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      for (int i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await settle();
    await tester.tap(find.text('Read presets from the pedal'));
    for (int i = 0; i < 10 && find.text('P03').evaluate().isEmpty; i++) {
      await settle();
    }
    await tester.tap(find.text('EQ'));
    await settle();
    expect(find.textContaining('cannot write back'), findsOneWidget);
    await tester.ensureVisible(find.text('Reset EQ (off, flat)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset EQ (off, flat)'));
    await settle();
    expect(find.text('Write 1 preset to pedal'), findsOneWidget);
    expect(find.textContaining('cannot write back'), findsNothing);
  });

  group('update without a preset backup', () {
    testWidgets('continues only on "Update without a backup"', (
      WidgetTester tester,
    ) async {
      expect(
        await _askWithoutBackup(tester, 'Update without a backup'),
        isTrue,
      );
    });

    testWidgets('Cancel stops the update', (WidgetTester tester) async {
      expect(await _askWithoutBackup(tester, 'Cancel'), isFalse);
    });

    testWidgets('tapping outside does not close it', (
      WidgetTester tester,
    ) async {
      expect(await _askWithoutBackup(tester, ''), isNull);
      expect(find.text('Presets cannot be backed up'), findsOneWidget);
    });
  });
}

Future<bool?> _askWithoutBackup(WidgetTester tester, String button) async {
  bool? answer;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (BuildContext context) => TextButton(
          onPressed: () async =>
              answer = await confirmUpdateWithoutBackup(context, '/raw.bin'),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(find.text('Presets cannot be backed up'), findsOneWidget);
  expect(find.textContaining('/raw.bin'), findsOneWidget);
  if (button.isEmpty) {
    await tester.tapAt(const Offset(5, 5)); // the barrier
  } else {
    await tester.tap(find.text(button));
  }
  await tester.pumpAndSettle();
  return answer;
}

/// Reading again sits in the app bar's preset menu.
Future<void> readAgain(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Preset actions'));
  await tester.pump();
  await tester.tap(find.text('Read again from pedal'));
}
