import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_tools/src/presets/mefcs.dart';
import 'package:pocket_amp_tools/src/presets/preset_backup.dart';
import 'package:pocket_amp_tools/src/presets/preset_meta.dart';
import 'package:pocket_amp_tools/src/ui/presets_page.dart';

import 'support/fake_pedal.dart';

const MetaCategory g = MetaCategory.genres;
const MetaCategory u = MetaCategory.uses;
const MetaCategory t = MetaCategory.tags;

PresetDetails _sample() {
  final PresetDetails l = PresetDetails();
  l.metas[0]
    ..labels[g]!.add('Blues')
    ..labels[u]!.add('Solo')
    ..labels[t]!.add('Headphones')
    ..rating = 4;
  l.metas[1]
    ..labels[g]!.add('Blues')
    ..labels[u]!.add('Rhythm')
    ..labels[t]!.add('Headphones')
    ..rating = 5;
  l.metas[2]
    ..labels[g]!.add('Blues')
    ..labels[u]!.add('Solo')
    ..rating = 5;
  l.metas[3]
    ..labels[g]!.add('Rock')
    ..labels[u]!.add('Solo')
    ..labels[t]!.add('Headphones')
    ..rating = 5;
  l.metas[4]
    ..labels[g]!.add('Blues')
    ..labels[u]!.add('Riffs')
    ..labels[t]!.add('Headphones')
    ..rating = 5;
  l.metas[5]
    ..labels[g]!.add('Blues')
    ..labels[u]!.add('Solo')
    ..labels[t]!.add('Headphones')
    ..rating = 3;
  return l;
}

List<int> _shown(PresetDetails l) => <int>[
  for (int i = 0; i < l.metas.length; i++)
    if (l.matches(i)) i,
];

void main() {
  test('OR within a category, AND across, rating as a floor', () {
    final PresetDetails l = _sample();
    expect(_shown(l), hasLength(80));
    l
      ..setFilter(g, 'Blues', true)
      ..setFilter(u, 'Solo', true)
      ..setFilter(u, 'Rhythm', true)
      ..setFilter(t, 'Headphones', true)
      ..setMinRating(4);
    // The issue's example: Blues, Solo or Rhythm, Headphones, 4 stars up.
    expect(_shown(l), <int>[0, 1]);
    l.clearFilter();
    expect(l.filtering, isFalse);
    expect(_shown(l), hasLength(80));
  });

  test('removing a label takes it off every preset and the filter', () {
    final PresetDetails l = _sample()..setFilter(g, 'Blues', true);
    l.removeLabel(g, 'Blues');
    expect(l.labels[g], isNot(contains('Blues')));
    expect(
      l.metas.any((PresetMeta m) => m.labels[g]!.contains('Blues')),
      isFalse,
    );
    expect(l.filtering, isFalse);
  });

  test('labels are added once, ignoring case and spaces', () {
    final PresetDetails l = PresetDetails();
    expect(l.addLabel(g, '  Italian Neomelodic '), isTrue);
    expect(l.addLabel(g, 'italian neomelodic'), isFalse);
    expect(l.addLabel(g, '   '), isFalse);
    expect(l.labels[g]!.last, 'Italian Neomelodic');
  });

  group('file', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('library'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 200));

    test('edits are saved and read back', () async {
      final File f = File('${dir.path}/preset-details.json');
      final PresetDetails a = PresetDetails();
      await a.open(f);
      a.metas[6]
        ..name = 'British Clean Echo'
        ..description = 'Mostly clean.'
        ..labels[t]!.add('Mario')
        ..rating = 2;
      a.addLabel(t, 'Mario');
      a.changed();
      await settle();

      final PresetDetails b = PresetDetails();
      await b.open(f);
      final PresetMeta m = b.metas[6];
      expect(m.name, 'British Clean Echo');
      expect(m.description, 'Mostly clean.');
      expect(m.labels[t], <String>{'Mario'});
      expect(m.rating, 2);
      expect(b.labels[t], <String>['Mario']);
      expect(b.metas[0].isEmpty, isTrue);
      expect(
        (jsonDecode(f.readAsStringSync()) as Map<String, Object?>)['presets'],
        hasLength(1),
      );
    });

    test('a file it cannot read is never overwritten', () async {
      final File f = File('${dir.path}/preset-details.json')
        ..writeAsStringSync('{not json');
      final PresetDetails l = PresetDetails();
      await l.open(f);
      l.metas[0].name = 'x';
      l.changed();
      await l.saved;
      // Moved aside as it was, and a new file takes the edits.
      final File aside = dir.listSync().whereType<File>().singleWhere(
        (File x) => x.path.contains('.unreadable-'),
      );
      expect(aside.readAsStringSync(), '{not json');
      expect(f.readAsStringSync(), contains('"name": "x"'));
    });

    test('odd values in the file are dropped, not fatal', () async {
      final File f = File('${dir.path}/preset-details.json')
        ..writeAsStringSync(
          jsonEncode(<String, Object?>{
            'labels': <String, Object?>{
              'genres': <Object?>['Blues', 3, ''],
            },
            'presets': <String, Object?>{
              'P01': <String, Object?>{'rating': 9, 'tags': 'Mario'},
              'P02': 'nope',
            },
          }),
        );
      final PresetDetails l = PresetDetails();
      await l.open(f);
      expect(l.labels[g], <String>['Blues']);
      expect(l.labels[u], defaultLabels[u]);
      expect(l.metas[0].rating, 5);
      expect(l.metas[0].labels[t], isEmpty);
      expect(l.metas[1].isEmpty, isTrue);
    });
  });

  PresetWorkspace workspace() {
    final Uint8List bank = demoBank();
    final PresetWorkspace w = PresetWorkspace()
      ..load(
        PresetBackup(
          identity: 'Pocket AMP_105',
          created: DateTime.utc(2026),
          presets: Uint8List.sublistView(bank, 0, eqTableAddress),
          eq: Uint8List.sublistView(bank, eqTableAddress),
        ),
        'x',
      );
    addTearDown(w.dispose);
    return w;
  }

  Future<void> show(WidgetTester tester, PresetWorkspace w, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PresetsPage(
            workspace: w,
            canUsePedal: false,
            busy: false,
            task: null,
            fraction: null,
            message: null,
            messageIsError: false,
            onRead: () {},
            onOpen: () {},
            onSave: () {},
            onWrite: () {},
          ),
        ),
      ),
    );
  }

  testWidgets('name, rate and filter presets in the editor', (
    WidgetTester tester,
  ) async {
    final PresetWorkspace w = workspace();
    await show(tester, w, const Size(1400, 1000));

    // Nothing to show yet, and no form taking room on the page.
    expect(find.widgetWithText(TextField, 'Name'), findsNothing);
    await tester.tap(find.byTooltip('Name, labels and rating'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Name'),
      'British Clean Echo',
    );
    await tester.tap(find.text('Add genre'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(InputChip, 'Blues'));
    // Typing a label that exists in another case picks it.
    await tester.enterText(find.widgetWithText(TextField, 'New genre'), 'pop');
    await tester.tap(find.byTooltip('Add'));
    await tester.tap(find.text('Done').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('4 of 5'));
    // A change from outside the dialog (the assistant) reaches the field.
    w.details.metas[0].description = 'Mostly clean.';
    w.details.changed();
    await tester.pump();
    expect(find.widgetWithText(TextField, 'Mostly clean.'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    final PresetMeta m = w.details.metas[0];
    expect(m.name, 'British Clean Echo');
    expect(m.labels[g], <String>{'Blues', 'Pop'});
    expect(m.rating, 4);
    expect(
      w.details.labels[g]!.where((String l) => l.toLowerCase() == 'pop'),
      <String>['Pop'],
    );
    // Naming a preset is not an edit of the pedal's presets.
    expect(w.changed, isEmpty);
    // The list names the preset after it, and the page sums it up.
    expect(find.widgetWithText(ListTile, 'British Clean Echo'), findsOneWidget);
    expect(find.text('British Clean Echo'), findsNWidgets(2));
    expect(find.text('Blues, Pop'), findsOneWidget);
    // Four in the summary, one beside the rating in the list.
    expect(find.byIcon(Icons.star), findsNWidgets(5));
    expect(find.text('80 presets'), findsOneWidget);

    await tester.tap(find.byTooltip('Filter presets'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilterChip, 'Blues'),
      ),
    );
    await tester.pump();
    expect(
      find.text(
        'Any value within a group, every group at once. '
        '1 of 80 presets match.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('1 of 80 presets'), findsOneWidget);
    expect(find.text('P02'), findsNothing);

    // A preset the filter hides stays open; clearing brings the list back.
    w.select(1);
    await tester.pump();
    expect(find.text('P02'), findsNothing);
    await tester.tap(find.byTooltip('Clear the filter'));
    await tester.pump();
    expect(find.text('80 presets'), findsOneWidget);
    expect(find.text('P02'), findsOneWidget);

    w.details.setMinRating(5);
    await tester.pump();
    expect(find.text('No preset matches the filter.'), findsOneWidget);
  });

  testWidgets('on a phone the picker, the filter and the dialogs fit', (
    WidgetTester tester,
  ) async {
    final PresetWorkspace w = workspace();
    w.details.metas[4]
      ..name = 'Deluxe Clean Direct with a rather long name'
      ..description = 'Warm, smooth clean tone with rolled-off highs.'
      ..labels[g]!.addAll(<String>['Blues', 'Country', 'Pop'])
      ..rating = 4;
    w.select(4);
    await show(tester, w, const Size(360, 780));
    // No list here: the summary and the slot picker carry the name.
    expect(find.byType(ListTile), findsNothing);
    expect(find.text('Blues, Country, Pop'), findsOneWidget);

    await tester.tap(find.byTooltip('Name, labels and rating'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Change'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Filter presets'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, 'Country'));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Filter presets (on)'), findsOneWidget);

    // The picker offers what the filter lets through, by slot and name.
    w.select(0);
    await tester.pump();
    await tester.tap(find.text('P01'));
    await tester.pumpAndSettle();
    expect(find.textContaining('P05  Deluxe Clean'), findsOneWidget);
    expect(find.text('P02'), findsNothing);
  });

  testWidgets('the discard and write buttons fit a phone', (
    WidgetTester tester,
  ) async {
    final PresetWorkspace w = workspace();
    w.load(w.draft!, 'pedal', fromPedal: true); // changes count against it
    await show(tester, w, const Size(360, 780));
    w.draft!.setVolume(0, 1);
    w.edited();
    await tester.pump();
    // An overflow would have failed the test by now.
    expect(find.text('Discard changes'), findsOneWidget);
    expect(find.text('Write 1 preset to pedal'), findsOneWidget);
  });
}
