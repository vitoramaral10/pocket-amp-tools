// Renders the README and website screenshots from the real UI, with a fake
// pedal on V1.03 and the official V1.05 package:
//
//   POCKET_AMP_FWSC=/path/Pocket\ AMP.fwsc \
//     flutter test test_screens --update-goldens
//
// The PNGs land in test_screens/goldens/.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_amp_tools/main.dart';

import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pocket_amp_tools/src/presets/mefcs.dart';
import 'package:pocket_amp_tools/src/presets/preset_backup.dart';
import 'package:pocket_amp_tools/src/presets/preset_service.dart';

import '../test/support/fake_pedal.dart';

/// Documents in a temporary folder, for the Backups screen.
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

void main() {
  final String? fwsc = Platform.environment['POCKET_AMP_FWSC'];
  final String fonts =
      '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts';

  // Each screen gets its own app folder where the introduction was seen,
  // so it does not cover the screen.
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

  for (final Brightness b in Brightness.values) {
    testWidgets('ready to update, ${b.name}', (WidgetTester tester) async {
      // Real shadows instead of the test framework's flat outlines.
      debugDisableShadows = false;
      tester.view.physicalSize = const Size(1440, 2200);
      tester.view.devicePixelRatio = 2;
      tester.platformDispatcher.platformBrightnessTestValue = b;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

      final Uint8List pkg = File(fwsc!).readAsBytesSync();
      await http.runWithClient(() async {
        await tester.pumpWidget(
          // With presets to give: they are read on detection, and a pedal
          // without them leaves that read waiting past the end of the test.
          PocketAmpApp(
            backend: FakePedal(image: Uint8List(1024), bank: demoBank()),
          ),
        );
        // Detection and the download run on real time, as in home_page_test.
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 2)),
        );
        await tester.pump();
        await tester.tap(find.text('Firmware'));
        await tester.pump();
        await tester.tap(find.text('Download from M-VAVE'));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 1)),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
      }, () => MockClient((_) async => http.Response.bytes(pkg, 200)));

      await expectLater(
        find.byType(PocketAmpApp),
        matchesGoldenFile('goldens/ready-${b.name}.png'),
      );
      debugDisableShadows = true; // checked before tear-down runs
    }, skip: fwsc == null);
  }

  // The new layout at a common desktop window size (1280x800), and narrow.
  for (final Brightness b in Brightness.values) {
    for (final (String name, Size size) in <(String, Size)>[
      ('presets', const Size(2560, 1600)),
      ('presets-narrow', const Size(840, 1720)),
      ('firmware', const Size(2560, 1600)),
      ('library', const Size(2560, 1600)),
      ('backups', const Size(2560, 1600)),
      // A phone (360x780 at 3x), for the store listing and the website.
      ('phone-presets', const Size(1080, 2340)),
      ('phone-library', const Size(1080, 2340)),
      ('phone-backups', const Size(1080, 2340)),
    ]) {
      final bool phone = name.startsWith('phone-');
      final String screen = phone ? name.substring(6) : name;
      testWidgets('$name, ${b.name}', (WidgetTester tester) async {
        debugDisableShadows = false;
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = phone ? 3 : 2;
        tester.platformDispatcher.platformBrightnessTestValue = b;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

        final Uint8List bank = demoBank();
        final Uint8List pkg = File(fwsc!).readAsBytesSync();
        Future<void> settle() async {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 600)),
          );
          for (int i = 0; i < 40; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
        }

        await http.runWithClient(() async {
          await tester.pumpWidget(
            PocketAmpApp(
              backend: FakePedal(image: Uint8List(1024), bank: bank),
            ),
          );
          await settle();
          if (screen == 'firmware') {
            await tester.tap(find.text('Firmware'));
            await tester.pump();
            await tester.tap(find.text('Download from M-VAVE'));
            await settle();
            return;
          }
          if (screen == 'backups') {
            final Directory dir = Directory.systemTemp.createTempSync('pa-');
            addTearDown(() => dir.deleteSync(recursive: true));
            File('${dir.path}/onboarded').writeAsStringSync('1');
            PathProviderPlatform.instance = _Paths(dir.path);
            await tester.runAsync(() async {
              for (final (int days, String id) in <(int, String)>[
                (0, 'Pocket AMP_105'),
                (3, 'Pocket AMP_103'),
                (21, 'Pocket AMP_103'),
              ]) {
                await PresetService.keepCopy(
                  PresetBackup(
                    identity: id,
                    created: DateTime(
                      2026,
                      11,
                      10,
                      15,
                      4,
                    ).subtract(Duration(days: days, hours: days)),
                    presets: Uint8List.sublistView(bank, 0, eqTableAddress),
                    eq: Uint8List.sublistView(bank, eqTableAddress),
                  ),
                );
              }
            });
            // The list is read from disk, which runs on real time only: open
            // the section inside runAsync so its reads start there.
            await tester.runAsync(() async {
              await tester.tap(find.text('Backups'));
              await tester.pump();
              await Future<void>.delayed(const Duration(milliseconds: 500));
            });
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            return;
          }
          if (screen == 'library') {
            final Directory dir = Directory.systemTemp.createTempSync('pa-');
            addTearDown(() => dir.deleteSync(recursive: true));
            PathProviderPlatform.instance = _Paths(dir.path);
            File('${dir.path}/onboarded').writeAsStringSync('1');
            // A few captures, two of them already on the pedal. Only the
            // names are shown, so the files can be empty.
            final String lib = '${dir.path}/Pocket AMP Tools/Library';
            for (final String f in <String>[
              'British 800 Crunch',
              'Chime Top Boost',
              'Modern High Gain Lead',
              'Tweed Clean',
            ]) {
              File('$lib/Amps/$f.nam').createSync(recursive: true);
            }
            File('$lib/links.json').writeAsStringSync(
              '{"amp": {"18": "Tweed Clean.nam", '
              '"19": "British 800 Crunch.nam"}}',
            );
            // The library is read from disk, which runs on real time only.
            await tester.runAsync(() async {
              await tester.tap(find.text('Library'));
              await tester.pump();
              await Future<void>.delayed(const Duration(milliseconds: 500));
            });
            await tester.pump();
            await settle();
            await settle();
            return;
          }
          await tester.tap(find.text('Read presets from the pedal'));
          await settle();
          await settle();
          if (name == 'presets') {
            await tester.tap(find.text('P05'));
          }
          await tester.pump();
          if (phone) {
            return; // the editor as it opens, with the AMP block
          }
          // One edit, so the "write" button and the changed marker show:
          // open the FX block and flip its switch.
          await tester.tap(find.text('FX').first);
          await tester.pumpAndSettle();
          await tester.tap(find.byType(Switch).first);
          await tester.pumpAndSettle();
        }, () => MockClient((_) async => http.Response.bytes(pkg, 200)));
        // Let the "Read all 80 presets" snackbar leave the picture.
        await tester.pump(const Duration(seconds: 5));
        await tester.pump(const Duration(seconds: 1));

        await expectLater(
          find.byType(PocketAmpApp),
          matchesGoldenFile('goldens/layout-$name-${b.name}.png'),
        );
        debugDisableShadows = true;
        expect(bank.length, eqTableAddress + eqTableLength);
      }, skip: fwsc == null);
    }
  }
}
