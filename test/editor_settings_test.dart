// SPDX-License-Identifier: GPL-3.0-only

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_tools/src/ui/editor_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    final Directory dir = await Directory.systemTemp.createTemp('editor');
    addTearDown(() => dir.delete(recursive: true));
    const MethodChannel channel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async => dir.path);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
  });

  test('asking before a write is on until turned off, and is kept', () async {
    expect(await EditorSettings.confirmWrite(), isTrue);
    await EditorSettings.setConfirmWrite(false);
    expect(await EditorSettings.confirmWrite(), isFalse);
    await EditorSettings.setConfirmWrite(true);
    expect(await EditorSettings.confirmWrite(), isTrue);
  });

  testWidgets('the zoom lays the app out smaller, fills the window and is '
      'kept', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() => EditorSettings.zoom.value = 1);
    int taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        builder: (BuildContext context, Widget? child) =>
            AppZoom(child: child!),
        home: Scaffold(
          body: SizedBox.expand(
            child: GestureDetector(key: const Key('page'), onTap: () => taps++),
          ),
        ),
      ),
    );
    final Finder page = find.byKey(const Key('page'));
    double ratio() => MediaQuery.devicePixelRatioOf(tester.element(page));
    expect(tester.getSize(page), const Size(800, 600));

    await tester.runAsync(() => EditorSettings.setZoom(2));
    await tester.pump();
    expect(tester.getSize(page), const Size(400, 300));
    expect(MediaQuery.sizeOf(tester.element(page)), const Size(400, 300));
    expect(ratio(), 2);
    expect(tester.getBottomRight(page), const Offset(800, 600));
    await tester.tapAt(const Offset(790, 590));
    expect(taps, 1);

    await tester.runAsync(() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.minus);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      // the save the key started
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(EditorSettings.zoom.value, 1.75);

    EditorSettings.zoom.value = 1;
    await tester.runAsync(EditorSettings.loadZoom);
    expect(EditorSettings.zoom.value, 1.75);

    // A narrow window keeps a layout at least 360 wide.
    tester.view.physicalSize = const Size(500, 600);
    await tester.pump();
    expect(MediaQuery.sizeOf(tester.element(page)).width, 360);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a phone has no zoom', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    EditorSettings.zoom.value = 2;
    addTearDown(() => EditorSettings.zoom.value = 1);
    await tester.pumpWidget(
      MaterialApp(
        builder: (BuildContext context, Widget? child) =>
            AppZoom(child: child!),
        home: const SizedBox.expand(key: Key('page')),
      ),
    );
    expect(
      MediaQuery.sizeOf(tester.element(find.byKey(const Key('page')))),
      tester.view.physicalSize / tester.view.devicePixelRatio,
    );
    debugDefaultTargetPlatformOverride = null;
  });
}
