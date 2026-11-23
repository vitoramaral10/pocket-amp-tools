import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_tools/src/presets/preset_meta.dart';
import 'package:pocket_amp_tools/src/sync/sync_data.dart';
import 'package:pocket_amp_tools/src/sync/sync_service.dart';
import 'package:pocket_amp_tools/src/ui/sync_page.dart';

SyncService _device(Directory tmp, String n) => SyncService(
  data: SyncData(
    library: Directory('${tmp.path}/$n/Library'),
    backups: Directory('${tmp.path}/$n'),
    details: PresetDetails(),
  ),
  stateFile: File('${tmp.path}/$n/sync.json'),
  discoveryPort: 0,
);

void main() {
  testWidgets('pairs from the page: the code is shown and confirmed', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final Directory tmp = Directory.systemTemp.createTempSync('sync_page_');
    // Made on the real clock: their queues must not wait on the test's.
    late final SyncService a, b;
    await tester.runAsync(() async {
      a = _device(tmp, 'a');
      b = _device(tmp, 'b');
      await a.load();
      await b.load();
      await b.rename('Phone');
    });
    await tester.pumpWidget(MaterialApp(home: SyncPage(service: b)));
    expect(find.text('Keep my devices in sync'), findsOneWidget);
    expect(find.text('Paired devices'), findsNothing, reason: 'off');

    await tester.tap(find.byType(Switch));
    Future<void> settle(bool Function() done) async {
      for (int i = 0; i < 100 && !done(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
    }

    await settle(() => find.textContaining('Looking…').evaluate().isNotEmpty);
    expect(find.textContaining('Looking…'), findsOneWidget);

    String? shownOnA;
    late Future<SyncPeer?> pairing;
    await tester.runAsync(() async {
      await a.setEnabled(true);
      pairing = a.pair(
        NearbyDevice(b.id, b.name, InternetAddress.loopbackIPv4, b.port!, ''),
        (String name, String code) async {
          shownOnA = code;
          return true;
        },
      );
    });
    await settle(
      () =>
          shownOnA != null &&
          find.text('${a.name} wants to pair').evaluate().isNotEmpty,
    );
    expect(find.text('${a.name} wants to pair'), findsOneWidget);
    expect(
      find.text('${shownOnA!.substring(0, 3)} ${shownOnA!.substring(3)}'),
      findsOneWidget,
      reason: 'the same code as on the other device',
    );
    await tester.tap(find.text('Codes match'));
    // The page's side of the pairing runs on the test clock: pump while
    // waiting for it.
    await settle(() => b.peers.isNotEmpty);
    await tester.pump();
    expect(find.text(a.name), findsOneWidget, reason: 'listed as paired');
    expect(find.byTooltip('Forget'), findsOneWidget);
    await tester.runAsync(() async {
      expect((await pairing)?.name, 'Phone');
      await a.setEnabled(false);
    });
    // B's side lives on the test clock: switched off from the page.
    await tester.tap(find.byType(Switch));
    await settle(() => b.port == null);
    expect(b.peers.keys, <String>[a.id], reason: 'paired on this side too');
    // A zero-length timer the last save leaves runs on the next tick.
    await tester.pump(const Duration(milliseconds: 1));
    tmp.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
