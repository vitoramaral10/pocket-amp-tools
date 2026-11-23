import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_tools/src/sync/sync_index.dart';

void main() {
  test('changes and deletes are stamped, unchanged items keep their time', () {
    final SyncIndex a = refreshIndex(<String, SyncEntry>{}, <String, String>{
      'amp/A.nam': 'h1',
      'preset/P01': 'm1',
    }, 100);
    expect(a['amp/A.nam'], const SyncEntry('h1', 100));
    final SyncIndex b = refreshIndex(a, <String, String>{
      'amp/A.nam': 'h2',
    }, 200);
    expect(b['amp/A.nam'], const SyncEntry('h2', 200));
    expect(b['preset/P01'], const SyncEntry('', 200), reason: 'a delete');
    final SyncIndex c = refreshIndex(b, <String, String>{
      'amp/A.nam': 'h2',
    }, 300);
    expect(c, b, reason: 'nothing changed');
    // A clock that went back still makes the new edit win.
    final SyncIndex d = refreshIndex(c, <String, String>{
      'amp/A.nam': 'h3',
    }, 50);
    expect(d['amp/A.nam']!.beats(c['amp/A.nam']!), isTrue);
  });

  test('the newer edit wins on both sides, deletes included', () {
    final SyncIndex here = <String, SyncEntry>{
      'same': const SyncEntry('x', 10),
      'older': const SyncEntry('a', 10),
      'newer': const SyncEntry('b', 30),
      'gone-there': const SyncEntry('c', 10),
      'only-here': const SyncEntry('d', 10),
    };
    final SyncIndex there = <String, SyncEntry>{
      'same': const SyncEntry('x', 99),
      'older': const SyncEntry('a2', 20),
      'newer': const SyncEntry('b2', 20),
      'gone-there': const SyncEntry('', 20),
      'only-there': const SyncEntry('e', 10),
      'deleted-there': const SyncEntry('', 10),
    };
    expect(keysToTake(here, there), <String>[
      'older',
      'gone-there',
      'only-there',
    ]);
    expect(keysToTake(there, here), <String>['newer', 'only-here']);
    // A tie is broken the same way on both sides.
    const SyncEntry p = SyncEntry('p', 5), q = SyncEntry('q', 5);
    expect(p.beats(q), isNot(q.beats(p)));
  });

  test('the revision tells same contents apart from different ones', () {
    final SyncIndex a = <String, SyncEntry>{
      'k': const SyncEntry('h', 1),
      'gone': const SyncEntry('', 3),
    };
    expect(
      indexRevision(a),
      indexRevision(<String, SyncEntry>{'k': const SyncEntry('h', 9)}),
      reason: 'times and deletes do not matter',
    );
    expect(
      indexRevision(a),
      isNot(indexRevision(<String, SyncEntry>{'k': const SyncEntry('i', 1)})),
    );
    expect(indexFromJson(indexToJson(a)), a);
  });
}
