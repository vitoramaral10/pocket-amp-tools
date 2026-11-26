import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_tools/src/presets/mefcs.dart';
import 'package:pocket_amp_tools/src/presets/preset_backup.dart';
import 'package:pocket_amp_tools/src/presets/preset_meta.dart';
import 'package:pocket_amp_tools/src/sync/sync_channel.dart';
import 'package:pocket_amp_tools/src/sync/sync_data.dart';
import 'package:pocket_amp_tools/src/sync/sync_service.dart';

import 'support/fake_pedal.dart';

class _Device {
  _Device(Directory tmp, String n, {Duration tick = const Duration(seconds: 3)})
    : root = Directory('${tmp.path}/$n/Pocket AMP Tools'),
      details = PresetDetails() {
    service = SyncService(
      data: SyncData(
        library: Directory('${root.path}/Library'),
        backups: root,
        details: details,
      ),
      stateFile: File('${tmp.path}/$n/sync.json'),
      discoveryPort: 0, // no broadcast in tests: devices are met by hand
      tick: tick,
      onChanged: () => changes++,
    );
  }

  final Directory root;
  final PresetDetails details;
  late final SyncService service;
  int changes = 0;

  File file(String path) => File('${root.path}/$path');

  NearbyDevice get asNearby => NearbyDevice(
    service.id,
    service.name,
    InternetAddress.loopbackIPv4,
    service.port!,
    '',
  );
}

void main() {
  late Directory tmp;
  late _Device a, b;
  final Uint8List nam = File('test/fixtures/a2_lite_synthetic.nam')
      .readAsBytesSync();

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('sync_');
    a = _Device(tmp, 'a');
    b = _Device(tmp, 'b');
    for (final _Device d in <_Device>[a, b]) {
      await d.service.load();
      await d.service.setEnabled(true);
    }
    a.service.nearby[b.service.id] = b.asNearby;
    b.service.nearby[a.service.id] = a.asNearby;
  });
  tearDown(() async {
    await a.service.setEnabled(false);
    await b.service.setEnabled(false);
    tmp.deleteSync(recursive: true);
  });

  /// Syncs from [from] and waits until [to] recorded its side too.
  Future<void> sync(_Device from, _Device to) async {
    final DateTime? was = to.service.peers[from.service.id]?.lastSync;
    await from.service.syncNow();
    for (int i = 0; i < 100; i++) {
      final SyncPeer? p = to.service.peers[from.service.id];
      if (p != null && (p.lastSync != was || p.lastError != null)) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> pair() async {
    String? askedB;
    b.service.onPairRequest = (String name, String code) async {
      askedB = code;
      return true;
    };
    String? askedA;
    final SyncPeer? p = await a.service.pair(b.asNearby, (
      String name,
      String code,
    ) async {
      askedA = code;
      return true;
    });
    expect(p?.id, b.service.id);
    expect(askedA, hasLength(6));
    expect(askedA, askedB, reason: 'both screens show the same code');
    for (int i = 0; i < 50 && b.service.peers.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(b.service.peers.keys, <String>[a.service.id]);
  }

  test(
    'pairs, then syncs the library, backups and details both ways',
    () async {
      await pair();
      a.file('Library/Amps/ENGL.nam')
        ..createSync(recursive: true)
        ..writeAsBytesSync(nam);
      final Uint8List bank = demoBank();
      final PresetBackup backup = PresetBackup(
        identity: 'Pocket AMP_105',
        created: DateTime.utc(2026),
        presets: Uint8List.sublistView(bank, 0, eqTableAddress),
        eq: Uint8List.sublistView(bank, eqTableAddress),
      );
      a.file(backup.suggestedFileName).writeAsStringSync(backup.toJson());
      a.details.metas[2] = PresetMeta(name: 'Lead', rating: 4);
      b.details.metas[5] = PresetMeta(name: 'Clean');

      await sync(a, b);
      expect(b.file('Library/Amps/ENGL.nam').readAsBytesSync(), nam);
      expect(b.file(backup.suggestedFileName).existsSync(), isTrue);
      expect(b.details.metas[2].name, 'Lead');
      expect(a.details.metas[5].name, 'Clean');
      expect(a.changes, 1);
      expect(b.changes, 1);

      // A delete on one side travels; an edit made later on the other too.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      b.file('Library/Amps/ENGL.nam').deleteSync();
      a.details.metas[5] = PresetMeta(name: 'Clean 2');
      await sync(b, a);
      expect(a.file('Library/Amps/ENGL.nam').existsSync(), isFalse);
      expect(b.details.metas[5].name, 'Clean 2');

      // Nothing left to do: a third sync moves nothing.
      final int before = a.changes + b.changes;
      await sync(a, b);
      expect(a.service.peers[b.service.id]!.lastResult, 'received 0, sent 0');
      expect(b.service.peers[a.service.id]!.lastResult, 'received 0, sent 0');
      expect(a.changes + b.changes, before);
      expect(a.service.peers[b.service.id]!.lastResult, 'received 0, sent 0');
    },
  );

  test('a file that is not what its key says is not stored', () async {
    await pair();
    a.file('Library/Amps/Broken.nam')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"not": "a capture"}');
    await sync(a, b);
    expect(b.file('Library/Amps/Broken.nam').existsSync(), isFalse);
    expect(
      b.service.peers[a.service.id]!.lastError,
      contains('amp/Broken.nam'),
    );
  });

  test(
    'an unpaired device cannot sync, and pairing needs the page open',
    () async {
      await expectLater(
        connectToSync(
          a.service,
          InternetAddress.loopbackIPv4,
          b.service.port!,
          b.service.id,
        ),
        throwsA(isA<SyncException>()),
      );
      b.service.onPairRequest = null;
      await expectLater(
        a.service.pair(b.asNearby, (_, _) async => true),
        throwsA(
          isA<SyncException>().having(
            (SyncException e) => e.message,
            'message',
            contains('Open the Sync page'),
          ),
        ),
      );
    },
  );

  test('a "no" on either screen pairs nothing', () async {
    b.service.onPairRequest = (_, _) async => false;
    expect(await a.service.pair(b.asNearby, (_, _) async => true), isNull);
    expect(a.service.peers, isEmpty);
    expect(b.service.peers, isEmpty);
  });

  test('the state survives a restart', () async {
    await pair();
    final SyncService again = SyncService(
      data: SyncData(
        library: Directory('${a.root.path}/Library'),
        backups: a.root,
        details: a.details,
      ),
      stateFile: File('${tmp.path}/a/sync.json'),
      discoveryPort: 0,
    );
    await again.load();
    expect(again.id, a.service.id);
    expect(again.enabled, isTrue);
    expect(again.peers.keys, <String>[b.service.id]);
    await again.setEnabled(false);
  });

  test('a change reaches the other device on its own', () async {
    await a.service.setEnabled(false);
    await b.service.setEnabled(false);
    a = _Device(tmp, 'a2', tick: const Duration(milliseconds: 100));
    b = _Device(tmp, 'b2', tick: const Duration(milliseconds: 100));
    for (final _Device d in <_Device>[a, b]) {
      await d.service.load();
      await d.service.setEnabled(true);
    }
    // What the broadcast hellos would say, kept fresh.
    final Timer hellos = Timer.periodic(const Duration(milliseconds: 50), (_) {
      for (final (_Device me, _Device other) in <(_Device, _Device)>[
        (a, b),
        (b, a),
      ]) {
        me.service.nearby[other.service.id] = other.asNearby
          ..revision = other.service.revision;
      }
    });
    addTearDown(hellos.cancel);
    await pair();
    a.file('Library/Amps/ENGL.nam')
      ..createSync(recursive: true)
      ..writeAsBytesSync(nam);
    final File there = b.file('Library/Amps/ENGL.nam');
    // The file lands before the round ends and reports the change.
    for (int i = 0; i < 100 && (!there.existsSync() || b.changes == 0); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(there.existsSync(), isTrue);
    expect(b.changes, 1);
  });
}
