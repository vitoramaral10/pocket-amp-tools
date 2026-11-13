// SPDX-License-Identifier: GPL-3.0-only

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_tools/src/ui/editor_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('asking before a write is on until turned off, and is kept', () async {
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

    expect(await EditorSettings.confirmWrite(), isTrue);
    await EditorSettings.setConfirmWrite(false);
    expect(await EditorSettings.confirmWrite(), isFalse);
    await EditorSettings.setConfirmWrite(true);
    expect(await EditorSettings.confirmWrite(), isTrue);
  });
}
