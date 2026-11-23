// Renders the TONE3000 screenshots for the website from the real browser,
// signed in, with made-up tones (no real creator's work in the pictures):
//
//   flutter test test_screens/tone3000_screens_test.dart --update-goldens
//
// The PNGs land in test_screens/goldens/tone3000-*.png.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_amp_tools/src/library/library.dart';
import 'package:pocket_amp_tools/src/tone3000/tone3000.dart';
import 'package:pocket_amp_tools/src/ui/app_theme.dart';
import 'package:pocket_amp_tools/src/ui/tone3000_page.dart';

Future<void> _loadFont(String family, List<String> files) async {
  final FontLoader loader = FontLoader(family);
  for (final String f in files) {
    final Uint8List b = File(f).readAsBytesSync();
    loader.addFont(Future<ByteData>.value(ByteData.sublistView(b)));
  }
  await loader.load();
}

http.Response _json(Object? body) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), 200);

/// Made-up tones, of the kinds TONE3000 lists.
const List<(String, String, String, String)>
_tones = <(String, String, String, String)>[
  (
    'Plexi 1968, bridged channels, edge of breakup',
    'example_studio',
    'amp',
    'cc-by',
  ),
  ('British 800 with a 4x12 V30, crunch', 'capture_lab', 'amp-cab', 'cc-by'),
  ('Boutique overdrive, low gain', 'pedal_nerd', 'pedal', 'cc0'),
  ('American clean combo, bright switch on', 'example_studio', 'amp', 'cc-by'),
  ('Modern high gain head, rhythm channel', 'tone_bench', 'amp', 'cc-by-sa'),
  ('Tweed deluxe, volume at 6', 'capture_lab', 'amp-cab', 'cc-by'),
  ('Fuzz into a clean amp', 'pedal_nerd', 'full-rig', 'cc0'),
];

void main() {
  final String fonts =
      '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts';

  setUpAll(() async {
    await _loadFont('Roboto', <String>[
      '$fonts/Roboto-Regular.ttf',
      '$fonts/Roboto-Medium.ttf',
      '$fonts/Roboto-Bold.ttf',
    ]);
    await _loadFont('MaterialIcons', <String>[
      '$fonts/MaterialIcons-Regular.otf',
    ]);
  });

  final MockClient service = MockClient((http.Request r) async {
    switch (r.url.path) {
      case '/api/v1/oauth/device_authorization':
        return _json(<String, Object?>{
          'device_code': 'dev',
          'user_code': 'K7QM-4XRT',
          'verification_uri': 'https://www.tone3000.com/activate',
          'verification_uri_complete':
              'https://www.tone3000.com/activate?user_code=K7QM-4XRT',
          'expires_in': 600,
          'interval': 5,
        });
      case '/api/v1/oauth/token':
        return _json(<String, Object?>{
          'access_token': 'a',
          'refresh_token': 'r',
          'expires_in': 3600,
        });
      case '/api/v1/tones/trending':
        return _json(<String, Object?>{
          'data': <Object?>[
            for (final (int i, (String t, String who, String gear, String l))
                in _tones.indexed)
              <String, Object?>{
                'id': i + 1,
                'title': t,
                'gear': gear,
                'format': 'nam',
                'a2_models_count': 3,
                'license': l,
                'url': 'https://www.tone3000.com/tones/example-$i',
                'user': <String, Object?>{'username': who},
              },
          ],
        });
      case '/api/v1/models':
        return _json(<String, Object?>{
          'data': <Object?>[
            for (final String n in <String>[
              'Clean, neck pickup',
              'Crunch, bridge pickup',
              'Lead, gain at 7',
            ])
              <String, Object?>{
                'id': n.length,
                'name': n,
                'size': 'standard',
                'model_url': 'https://www.tone3000.com/files/x.nam',
              },
          ],
        });
    }
    return http.Response('', 404);
  });

  for (final (String name, Size size, double dpr) in <(String, Size, double)>[
    ('desktop', const Size(1100, 760), 2),
    ('phone', const Size(390, 844), 3),
  ]) {
    for (final Brightness b in Brightness.values) {
      // The capture chooser renders its dialog shadow solid black in a test,
      // so only the list is taken.
      for (final String step in <String>['list']) {
        testWidgets('$name $step ${b.name}', (WidgetTester tester) async {
          tester.view.physicalSize = size * dpr;
          tester.view.devicePixelRatio = dpr;
          addTearDown(tester.view.reset);
          final Directory tmp = Directory.systemTemp.createTempSync('t3k_');
          addTearDown(() => tmp.deleteSync(recursive: true));
          final bool phone = size.width < 600;
          Future<void> settle([Finder? until]) async {
            for (int i = 0; i < 200; i++) {
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
            final Widget browser = Tone3000Browser(
              client: Tone3000(
                store: File('${tmp.path}/tone3000.json'),
                clientId: 'pk',
                wait: (_) =>
                    Future<void>.delayed(const Duration(milliseconds: 1)),
              ),
              onImport: (_, _, _) async =>
                  LibraryItem(LibraryKind.amp, File('${tmp.path}/x.nam')),
              open: (_) async => true,
            );
            await tester.pumpWidget(
              MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: themeFrom(
                  b == Brightness.dark ? darkColors : lightColors,
                ),
                home: Builder(
                  builder: (BuildContext context) => Scaffold(
                    backgroundColor: phone
                        ? null
                        : Theme.of(context).colorScheme.surfaceContainerLowest,
                    body: phone
                        ? SafeArea(child: browser)
                        : Center(
                            child: Card(
                              clipBehavior: Clip.antiAlias,
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 640,
                                  maxHeight: 720,
                                ),
                                child: browser,
                              ),
                            ),
                          ),
                  ),
                ),
              ),
            );
            await settle(find.text('Sign in with TONE3000'));
            await tester.tap(find.text('Sign in with TONE3000'));
            await settle(find.text(_tones.first.$1));
            if (step == 'choose') {
              await tester.tap(find.text('Get').at(1));
              await settle(find.text('Lead, gain at 7'));
            }
          }, () => service);
          await tester.pump(const Duration(seconds: 1));
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('goldens/tone3000-$name-$step-${b.name}.png'),
          );
        });
      }
    }
  }
}
