// SPDX-License-Identifier: GPL-3.0-only

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_tools/src/presets/block_models.dart';
import 'package:pocket_amp_tools/src/presets/mefcs.dart';
import 'package:pocket_amp_tools/src/presets/preset_backup.dart';
import 'package:pocket_amp_tools/src/presets/preset_meta.dart';
import 'package:pocket_amp_tools/src/ui/presets_page.dart';

import 'support/fake_pedal.dart';

Future<PresetWorkspace> _open(
  WidgetTester tester, {
  void Function(PresetDetails)? details,
  List<String>? calls,
  bool pedal = false,
}) async {
  tester.view.physicalSize = const Size(1000, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final Uint8List a = demoBank();
  final PresetWorkspace w = PresetWorkspace()
    ..load(
      PresetBackup(
        identity: 'Pocket AMP_105',
        created: DateTime.utc(2026),
        presets: Uint8List.sublistView(a, 0, eqTableAddress),
        eq: Uint8List.sublistView(a, eqTableAddress),
      ),
      'test',
    );
  details?.call(w.details);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PresetsPage(
          workspace: w,
          canUsePedal: pedal,
          busy: false,
          task: null,
          fraction: null,
          message: null,
          messageIsError: false,
          onRead: () => calls?.add('read'),
          onOpen: () => calls?.add('open'),
          onSave: () => calls?.add('save'),
          onWrite: () => calls?.add('write'),
        ),
      ),
    ),
  );
  await tester.pump();
  return w;
}

void main() {
  test('reads a preset number with or without the P', () {
    expect(parseSlot('15'), 14);
    expect(parseSlot(' p15 '), 14);
    expect(parseSlot('P01'), 0);
    expect(parseSlot('80'), 79);
    expect(parseSlot('80', 79), isNull, reason: 'older firmware stops at P79');
    for (final String bad in <String>['', '0', '81', 'P', 'x', '-3']) {
      expect(parseSlot(bad), isNull, reason: bad);
    }
  });

  testWidgets('arrows step through presets and F2 jumps to one', (
    WidgetTester tester,
  ) async {
    final PresetWorkspace w = await _open(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    expect(w.selected, 0, reason: 'stays on the first preset');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(w.selected, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    expect(w.selected, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '75');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(w.selected, 74);
    final Finder row = find.descendant(
      of: find.byType(ListTile),
      matching: find.text('P75'),
    );
    expect(tester.getRect(row).bottom, lessThanOrEqualTo(800));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(w.selected, 75, reason: 'arrows still work after the dialog');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '?');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.text('Keyboard shortcuts'), findsOneWidget);
    expect(find.text('Go to a preset by number'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Keyboard shortcuts'), findsNothing);
  });

  testWidgets('arrows skip presets the filter hides, F2 does not', (
    WidgetTester tester,
  ) async {
    final PresetWorkspace w = await _open(
      tester,
      details: (PresetDetails d) {
        d.metas[3].rating = 5;
        d.metas[10].rating = 5;
        d.minRating = 4;
      },
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(w.selected, 3);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(w.selected, 10);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(w.selected, 10, reason: 'last preset the filter shows');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    expect(w.selected, 3);

    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '50');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(w.selected, 49, reason: 'jumps past the filter');
  });

  testWidgets('Home, End, Page Up/Down and up/down move through the list', (
    WidgetTester tester,
  ) async {
    final PresetWorkspace w = await _open(tester);
    Future<int> press(LogicalKeyboardKey k) async {
      await tester.sendKeyEvent(k);
      return w.selected;
    }

    expect(await press(LogicalKeyboardKey.end), 79);
    expect(await press(LogicalKeyboardKey.pageUp), 69);
    expect(await press(LogicalKeyboardKey.arrowUp), 68);
    expect(await press(LogicalKeyboardKey.arrowDown), 69);
    expect(await press(LogicalKeyboardKey.home), 0);
    expect(await press(LogicalKeyboardKey.pageDown), 10);
  });

  testWidgets('from a preset the filter hides, keys land on shown ones', (
    WidgetTester tester,
  ) async {
    final PresetWorkspace w = await _open(
      tester,
      details: (PresetDetails d) {
        for (final int id in <int>[3, 10, 20, 30]) {
          d.metas[id].rating = 5;
        }
        d.minRating = 4;
      },
    );
    w.select(15);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(w.selected, 20);
    w.select(15);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    expect(w.selected, 10);
    w.select(15);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    expect(w.selected, 30, reason: 'stops at the last shown preset');
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    expect(w.selected, 3);
  });

  Future<void> ctrl(
    WidgetTester tester,
    LogicalKeyboardKey k, {
    bool shift = false,
  }) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    }
    await tester.sendKeyEvent(k);
    if (shift) {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  }

  testWidgets('Ctrl+O, Ctrl+Shift+S and Ctrl+R follow what the menu allows', (
    WidgetTester tester,
  ) async {
    final List<String> calls = <String>[];
    await _open(tester, calls: calls);
    await ctrl(tester, LogicalKeyboardKey.keyO);
    await ctrl(tester, LogicalKeyboardKey.keyS);
    await ctrl(tester, LogicalKeyboardKey.keyS, shift: true);
    await ctrl(tester, LogicalKeyboardKey.keyR);
    // No pedal in this test, so writing and reading again stay off.
    expect(calls, <String>['open', 'save']);
  });

  testWidgets('Ctrl+S writes to the pedal when there is something to write', (
    WidgetTester tester,
  ) async {
    final List<String> calls = <String>[];
    await _open(tester, calls: calls, pedal: true);
    await ctrl(tester, LogicalKeyboardKey.keyS);
    expect(calls, <String>['write'], reason: 'a file draft can be written');
  });

  testWidgets('number keys open the blocks in chain order', (
    WidgetTester tester,
  ) async {
    final PresetWorkspace w = await _open(tester);
    final PresetBackup d = w.draft!;
    final List<int> chips = <int>[
      if (d.eqAtHead(0)) PresetWorkspace.eqBlock,
      ...d.chain(0),
      if (!d.eqAtHead(0)) PresetWorkspace.eqBlock,
    ];
    const List<LogicalKeyboardKey> digits = <LogicalKeyboardKey>[
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7,
    ];
    for (final (int i, int block) in chips.indexed) {
      await tester.sendKeyEvent(digits[i], character: '${i + 1}');
      expect(w.openBlock, block, reason: 'key ${i + 1}');
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.digit9, character: '9');
    expect(w.openBlock, chips.last, reason: 'no ninth chip');
  });

  testWidgets('Space turns the open block off and on, [ ] change its model', (
    WidgetTester tester,
  ) async {
    final PresetWorkspace w = await _open(tester);
    final PresetBackup d = w.draft!;
    const int amp = 1;
    w.open(amp);
    final bool on = d.isOn(0, amp);
    final int model = d.model(0, amp);
    final int n = blockModels['AMP']!.length;

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(d.isOn(0, amp), !on);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(d.isOn(0, amp), on);

    await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight, character: ']');
    expect(d.model(0, amp), (model + 1) % n);
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft, character: '[');
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft, character: '[');
    expect(d.model(0, amp), (model - 1) % n, reason: 'wraps around');
  });

  testWidgets('Ctrl+F opens the filter and Esc clears it', (
    WidgetTester tester,
  ) async {
    final PresetWorkspace w = await _open(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('Filter presets'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing, reason: 'Esc closes it');

    w.details.minRating = 4;
    expect(w.details.filtering, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(w.details.filtering, isFalse);
  });

  testWidgets('Ctrl+Shift+C and Ctrl+Shift+V copy one preset onto another', (
    WidgetTester tester,
  ) async {
    String? clip;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          clip = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        } else if (call.method == 'Clipboard.getData') {
          return <String, Object?>{'text': clip};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final PresetWorkspace w = await _open(tester);
    Future<void> ctrlShift(LogicalKeyboardKey k) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(k);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }

    await ctrlShift(LogicalKeyboardKey.keyC);
    expect(clip, isNotNull);
    w.select(5);
    await ctrlShift(LogicalKeyboardKey.keyV);
    Map<String, Object?> body(int id) =>
        Map<String, Object?>.of(w.draft!.presetFields(id))..remove('preset');
    expect(body(5), body(0));
  });

  testWidgets('Ctrl+Z discards the changes back to the pedal', (
    WidgetTester tester,
  ) async {
    final PresetWorkspace w = await _open(tester);
    await ctrl(tester, LogicalKeyboardKey.keyZ);
    expect(
      w.draft,
      isNotNull,
      reason: 'nothing read from a pedal to go back to',
    );
    final PresetBackup pedal = w.draft!.copy();
    w.written(pedal);
    final int volume = w.draft!.volume(0);
    w.draft!.setVolume(0, volume == 0 ? 1 : 0);
    w.edited();
    expect(w.changed, isNotEmpty);
    await ctrl(tester, LogicalKeyboardKey.keyZ);
    expect(w.changed, isEmpty);
    expect(w.draft!.volume(0), volume);
  });

  testWidgets('each chain chip shows the number key that opens it', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final PresetWorkspace w = await _open(tester);
    final PresetBackup d = w.draft!;
    final List<String> names = <String>[
      if (d.eqAtHead(0)) 'EQ',
      for (final int b in d.chain(0)) blockNames[b],
      if (!d.eqAtHead(0)) 'EQ',
    ];
    for (final (int i, String name) in names.indexed) {
      final Finder chip = find.byWidgetPredicate(
        (Widget x) => x is Semantics && x.properties.hint == 'Key ${i + 1}',
      );
      expect(chip, findsOneWidget, reason: 'key ${i + 1}');
      expect(
        find.descendant(of: chip, matching: find.text(name)),
        findsOneWidget,
        reason: 'key ${i + 1} is $name',
      );
    }
    debugDefaultTargetPlatformOverride = null;
  });
}
