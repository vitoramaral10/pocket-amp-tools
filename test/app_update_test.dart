import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_amp_tools/src/app_update.dart';
import 'package:pocket_amp_tools/src/ui/settings_page.dart';

void main() {
  late Directory tmp;
  late AppUpdates u;
  int calls = 0;
  String tag = 'v0.7.0';
  bool offline = false;
  final MockClient github = MockClient((http.Request r) async {
    calls++;
    if (offline) {
      throw const SocketException('no network');
    }
    expect(r.url.host, 'api.github.com');
    return http.Response(
      jsonEncode(<String, Object>{
        'tag_name': tag,
        'html_url':
            'https://github.com/vitoramaral10/pocket-amp-tools/releases/tag/$tag',
      }),
      200,
    );
  });
  Future<AppRelease?> check(DateTime t) =>
      http.runWithClient(() => u.check(now: t), () => github);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('app_update_');
    u = AppUpdates(File('${tmp.path}/app-update.json'), current: '0.6.0');
    calls = 0;
    tag = 'v0.7.0';
    offline = false;
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('compares plain versions only', () {
    expect(isNewer('0.7.0', '0.6.0'), isTrue);
    expect(isNewer('v1.0.0', '0.12.3'), isTrue);
    expect(isNewer('0.6.10', '0.6.9'), isTrue);
    expect(isNewer('0.6.0', '0.6.0'), isFalse);
    expect(isNewer('0.5.9', '0.6.0'), isFalse);
    expect(isNewer('0.7.0-beta.1', '0.6.0'), isFalse);
  });

  test('tells of a newer release, asking GitHub once a day', () async {
    final DateTime t = DateTime(2026, 11, 22, 10);
    final AppRelease? r = await check(t);
    expect(r?.version, '0.7.0');
    expect(r?.url, endsWith('/releases/tag/v0.7.0'));
    expect(await check(t.add(const Duration(hours: 5))), isNotNull);
    expect(calls, 1, reason: 'the answer is kept for a day');
    tag = 'v0.8.0';
    expect((await check(t.add(const Duration(days: 1))))?.version, '0.8.0');
    expect(calls, 2);
  });

  test('a skipped version is not told again; a later one is', () async {
    final DateTime t = DateTime(2026, 11, 22, 10);
    await u.skip((await check(t))!.version);
    expect(await check(t), isNull);
    tag = 'v0.7.1';
    expect((await check(t.add(const Duration(days: 1))))?.version, '0.7.1');
  });

  test('nothing to tell when up to date, offline or turned off', () async {
    final DateTime t = DateTime(2026, 11, 22, 10);
    tag = 'v0.6.0';
    expect(await check(t), isNull);
    offline = true;
    expect(await check(t.add(const Duration(days: 2))), isNull);
    offline = false;
    tag = 'v0.7.0';
    await u.setEnabled(false);
    expect(await u.enabled(), isFalse);
    expect(await check(t.add(const Duration(days: 3))), isNull);
    expect(calls, 2, reason: 'off means no request at all');
  });

  testWidgets('the switch in Settings turns it off and on', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AppUpdatesCard(updates: u)),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    await tester.tap(find.byType(Switch));
    // The save runs on the test clock: give it real time and ticks.
    for (int i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(await tester.runAsync(u.enabled), isFalse);
  });
}
