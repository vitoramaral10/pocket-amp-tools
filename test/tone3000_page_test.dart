// SPDX-License-Identifier: GPL-3.0-only

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_amp_tools/src/library/library.dart';
import 'package:pocket_amp_tools/src/presets/ir_upload.dart';
import 'package:pocket_amp_tools/src/tone3000/tone3000.dart';
import 'package:pocket_amp_tools/src/ui/tone3000_page.dart';

import 'ir_upload_test.dart' show wav;

http.Response _json(Object? body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

void main() {
  testWidgets('signs in, lists the tones the pedal takes and gets a capture', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final Directory tmp = Directory.systemTemp.createTempSync('t3k_ui_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final Library lib = Library(Directory('${tmp.path}/Library'));
    final String a2 = File('test/fixtures/a2_lite_synthetic.nam')
        .readAsStringSync();
    final List<String> opened = <String>[];
    bool approved = false;

    final MockClient service = MockClient((http.Request r) async {
      switch (r.url.path) {
        case '/api/v1/oauth/device_authorization':
          return _json(<String, Object?>{
            'device_code': 'dev',
            'user_code': 'ABCD-EFGH',
            'verification_uri': 'https://www.tone3000.com/activate',
            'verification_uri_complete':
                'https://www.tone3000.com/activate?user_code=ABCD-EFGH',
            'expires_in': 600,
            'interval': 5,
          });
        case '/api/v1/oauth/token':
          return approved
              ? _json(<String, Object?>{
                  'access_token': 'a1',
                  'refresh_token': 'r1',
                  'expires_in': 3600,
                })
              : _json(<String, Object?>{'error': 'authorization_pending'}, 400);
        case '/api/v1/tones/trending':
          return _json(<String, Object?>{
            'data': <Object?>[
              <String, Object?>{
                'id': 7,
                'title': 'Plexi crunch',
                'gear': 'amp',
                'format': 'nam',
                'a2_models_count': 2,
                'license': 'cc-by',
                'url': 'https://www.tone3000.com/tones/plexi-7',
                'user': <String, Object?>{'username': 'someone'},
              },
              <String, Object?>{'id': 9, 'title': 'A cab', 'format': 'ir'},
            ],
          });
        case '/api/v1/tones/search':
          return r.url.queryParameters['query'] == 'nothing'
              ? _json(<String, Object?>{'data': <Object?>[]})
              : _json(<String, Object?>{
                  'data': <Object?>[
                    <String, Object?>{
                      'id': 11,
                      'title': 'Found ${r.url.queryParameters['query']}',
                      'format': 'nam',
                      'a2_models_count': 1,
                      'user': <String, Object?>{'username': 'finder'},
                    },
                  ],
                });
        case '/api/v1/models':
          return _json(<String, Object?>{
            'data': <Object?>[
              for (final String name in <String>['Clean', 'Lead'])
                <String, Object?>{
                  'id': name.length,
                  'name': name,
                  'size': 'standard',
                  'model_url': 'https://www.tone3000.com/files/$name.nam',
                },
            ],
          });
        case '/files/Clean.nam':
          return http.Response(a2, 200);
        case '/files/Lead.nam':
          return http.Response('{"architecture": "WaveNet"}', 200);
      }
      return http.Response('', 404);
    });

    // Real time passes for the file work; under a loaded machine it takes
    // longer, so wait for what is expected instead of a fixed time.
    Future<void> settle([Finder? until, int max = 400]) async {
      for (int i = 0; i < (until == null ? 40 : max); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 50));
        if (until != null && until.evaluate().isNotEmpty) {
          return;
        }
      }
    }

    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Tone3000Browser(
              client: Tone3000(
                store: File('${tmp.path}/tone3000.json'),
                clientId: 'pk',
                wait: (_) =>
                    Future<void>.delayed(const Duration(milliseconds: 20)),
              ),
              onImport: (String name, Uint8List bytes, Tone _) =>
                  lib.import(LibraryKind.amp, name, bytes),
              open: (String url) async {
                opened.add(url);
                return true;
              },
            ),
          ),
        ),
      );
      await settle();
      await tester.tap(find.text('Sign in with TONE3000'));
      await settle();
      expect(find.text('ABCD-EFGH'), findsOneWidget);
      expect(opened, <String>[
        'https://www.tone3000.com/activate?user_code=ABCD-EFGH',
      ]);
      expect(find.text('Plexi crunch'), findsNothing);

      approved = true;
      await settle(find.text('Plexi crunch'));
      expect(find.text('Plexi crunch'), findsOneWidget);
      expect(find.text('by someone · amp · NAM · cc-by'), findsOneWidget);
      expect(find.text('A cab'), findsNothing);
      expect(find.textContaining('1 other tone is not shown'), findsOneWidget);
      expect(find.textContaining('Powered by TONE3000'), findsOneWidget);
      expect(find.bySemanticsLabel('TONE3000'), findsOneWidget);

      await tester.tap(find.text('Get'));
      await settle(find.text('Which capture of "Plexi crunch"?'));
      expect(find.text('Which capture of "Plexi crunch"?'), findsOneWidget);
      await tester.tap(find.text('Clean'));
      await settle(find.text('Added "Clean" to your library.'));
      expect(find.text('Added "Clean" to your library.'), findsOneWidget);

      // A file that is not a whole A2 capture is refused, with the reason.
      await tester.tap(find.text('Get'));
      await settle(find.text('Lead'));
      await tester.tap(find.text('Lead'));
      await settle(find.textContaining('not a whole A2 capture'));
      expect(find.textContaining('not a whole A2 capture'), findsOneWidget);

      // Searching replaces the list; picking a list brings it back.
      await tester.enterText(find.byType(TextField), ' rectifier ');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await settle();
      expect(find.text('Found rectifier'), findsOneWidget);
      expect(find.text('Plexi crunch'), findsNothing);
      await tester.enterText(find.byType(TextField), 'nothing');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await settle();
      expect(find.text('No A2 NAM capture matches "nothing".'), findsOneWidget);
      await tester.tap(find.text('Trending'));
      await settle();
      expect(find.text('Plexi crunch'), findsOneWidget);

      await tester.tap(find.text('Sign out'));
      await settle();
      expect(find.text('Sign in with TONE3000'), findsOneWidget);
    }, () => service);

    final List<LibraryItem> items = (await tester.runAsync(
      () => lib.list(LibraryKind.amp),
    ))!;
    expect(items.map((LibraryItem i) => i.name), <String>['Clean']);
    expect(File('${tmp.path}/tone3000.json').existsSync(), isFalse);
  });

  testWidgets('in IR mode it lists IRs and converts the one picked', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final Directory tmp = Directory.systemTemp.createTempSync('t3k_ir_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final Library lib = Library(Directory('${tmp.path}/Library'));
    File('${tmp.path}/tone3000.json').writeAsStringSync(
      jsonEncode(<String, Object?>{
        'access_token': 'a1',
        'refresh_token': 'r1',
        'expires': DateTime.now()
            .add(const Duration(hours: 1))
            .toIso8601String(),
      }),
    );
    final MockClient service = MockClient((http.Request r) async {
      switch (r.url.path) {
        case '/api/v1/tones/trending':
          expect(r.url.queryParameters['gear'], 'cab');
          return _json(<String, Object?>{
            'data': <Object?>[
              <String, Object?>{
                'id': 5,
                'title': 'V30 cab',
                'gear': 'cab',
                'format': 'ir',
                'irs_count': 1,
                'user': <String, Object?>{'username': 'micman'},
              },
              <String, Object?>{
                'id': 6,
                'title': 'An amp',
                'format': 'nam',
                'a2_models_count': 1,
              },
            ],
          });
        case '/api/v1/models':
          return _json(<String, Object?>{
            'data': <Object?>[
              <String, Object?>{
                'id': 50,
                'name': 'SM57 cap edge',
                'model_url': 'https://www.tone3000.com/files/57.wav',
              },
            ],
          });
        case '/files/57.wav':
          return http.Response.bytes(
            wav(channels: 2, rate: 48000, bits: 16, frames: 4000),
            200,
          );
      }
      return http.Response('', 404);
    });

    Future<void> settle([Finder? until]) async {
      for (int i = 0; i < 400; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 50));
        if (until == null ? i >= 40 : until.evaluate().isNotEmpty) {
          return;
        }
      }
    }

    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Tone3000Browser(
              client: Tone3000(
                store: File('${tmp.path}/tone3000.json'),
                clientId: 'pk',
              ),
              ir: true,
              onImport: (String name, Uint8List bytes, Tone _) =>
                  lib.import(LibraryKind.cab, name, bytes),
              open: (_) async => true,
            ),
          ),
        ),
      );
      await settle(find.text('V30 cab'));
      expect(find.text('An amp'), findsNothing);
      expect(find.text('by micman · cab · IR'), findsOneWidget);
      await tester.tap(find.text('Get'));
      await settle(find.text('Added "SM57 cap edge" to your library.'));
    }, () => service);

    final List<LibraryItem> items = (await tester.runAsync(
      () => lib.list(LibraryKind.cab),
    ))!;
    expect(items.single.name, 'SM57 cap edge');
    final Uint8List stored = (await tester.runAsync(
      () => items.single.file.readAsBytes(),
    ))!;
    expect(parseIrWav(stored), hasLength(irPcmLength));
  });
}
