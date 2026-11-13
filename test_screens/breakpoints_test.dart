// Renders every screen at one width per Material 3 window size class and
// fails on any layout overflow:
//
//   flutter test test_screens/breakpoints_test.dart --update-goldens
//
// The PNGs land in test_screens/goldens/bp-*.png for a visual pass.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pocket_amp_tools/main.dart';
import 'package:pocket_amp_tools/src/presets/mefcs.dart';
import 'package:pocket_amp_tools/src/presets/preset_backup.dart';
import 'package:pocket_amp_tools/src/presets/preset_service.dart';
import 'package:pocket_amp_tools/src/ui/settings_page.dart';

import '../test/support/fake_pedal.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.dir);
  final String dir;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

Future<void> _loadFont(String family, List<String> files) async {
  final FontLoader loader = FontLoader(family);
  for (final String f in files) {
    final Uint8List b = File(f).readAsBytesSync();
    loader.addFont(Future<ByteData>.value(ByteData.sublistView(b)));
  }
  await loader.load();
}

// One size per class: compact, medium, expanded, large, extra-large.
const List<(String, Size)> _sizes = <(String, Size)>[
  ('compact', Size(360, 780)),
  ('medium', Size(700, 1000)),
  ('expanded', Size(1000, 720)),
  ('large', Size(1400, 900)),
  ('xlarge', Size(1800, 1000)),
];

const List<String> _screens = <String>[
  'presets-empty',
  'presets',
  'assistant',
  'library',
  'firmware',
  'backups',
  'settings',
];

void main() {
  final String fonts =
      '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts';

  setUp(() {
    final Directory dir = Directory.systemTemp.createTempSync('pa-');
    File('${dir.path}/onboarded').writeAsStringSync('1');
    // Names, labels and ratings for a few slots, as a user would give them.
    File('${dir.path}/preset-details.json').writeAsStringSync(
      '{"labels": {"tags": ["Headphones", "Live"]}, "presets": {'
      '"P01": {"name": "British Clean Echo", "genres": ["Blues", "Pop"], '
      '"uses": ["Rhythm", "Arpeggios"], "tags": ["Headphones"], "rating": 4, '
      '"description": "Mostly clean and bright, with a short echo behind."}, '
      '"P02": {"name": "RAT British Rock", "genres": ["Rock", "Punk"], '
      '"uses": ["Riffs"], "rating": 3}, '
      '"P04": {"name": "High Gain Lead", "genres": ["Hard rock"], '
      '"uses": ["Riffs", "Solo"], "tags": ["Live"], "rating": 5}}}',
    );
    PathProviderPlatform.instance = _Paths(dir.path);
    addTearDown(() => dir.deleteSync(recursive: true));
  });

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

  for (final (String cls, Size size) in _sizes) {
    for (final String screen in _screens) {
      testWidgets('$screen at $cls', (WidgetTester tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

        Future<void> settle() async {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 600)),
          );
          for (int i = 0; i < 40; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
        }

        Future<void> go(String section) async {
          await tester.runAsync(() async {
            await tester.tap(find.text(section).last);
            await tester.pump();
            await Future<void>.delayed(const Duration(milliseconds: 500));
          });
          await settle();
        }

        await tester.pumpWidget(
          PocketAmpApp(
            backend: FakePedal(image: Uint8List(1024), bank: demoBank()),
          ),
        );
        await settle();
        switch (screen) {
          case 'presets' || 'assistant':
            await tester.tap(find.text('Read presets from the pedal'));
            await settle();
            await settle();
            if (screen == 'assistant') {
              await tester.tap(find.byTooltip('Assistant'));
              await settle();
            }
          case 'library':
            await go('Library');
          case 'firmware':
            await go('Firmware');
          case 'backups':
            await tester.runAsync(() async {
              final Uint8List bank = demoBank();
              for (final int days in <int>[0, 3, 21]) {
                await PresetService.keepCopy(
                  PresetBackup(
                    identity: 'Pocket AMP_103',
                    created: DateTime(
                      2026,
                      11,
                      10,
                    ).subtract(Duration(days: days)),
                    presets: Uint8List.sublistView(bank, 0, eqTableAddress),
                    eq: Uint8List.sublistView(bank, eqTableAddress),
                  ),
                );
              }
            });
            await go('Backups');
          case 'settings':
            await tester.runAsync(() async {
              tester
                  .state<NavigatorState>(find.byType(Navigator).first)
                  .push(
                    MaterialPageRoute<void>(
                      builder: (_) => const SettingsPage(),
                    ),
                  );
              await tester.pump();
              await Future<void>.delayed(const Duration(milliseconds: 500));
            });
            await settle();
        }

        await expectLater(
          find.byType(PocketAmpApp),
          matchesGoldenFile('goldens/bp-$screen-$cls.png'),
        );
      });
    }
  }
}
