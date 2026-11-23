// SPDX-License-Identifier: GPL-3.0-only
//
// One sync over an open link. Both sides run the same steps, each sending
// before it reads (the socket buffers, so neither waits on the other):
//   index  every item this side knows, with hash and time
//   want   the items the other side has newer
//   item*  each wanted item: a header, then its bytes; then "end"
// Then each side applies what it took: writes what arrived, deletes what
// the other side deleted later, and records the winners in its index; and
// says "done", so both know the other finished.

import 'dart:typed_data';

import 'sync_channel.dart';
import 'sync_data.dart';
import 'sync_index.dart';

class SyncResult {
  SyncResult(this.index);

  /// This side's index after the sync.
  final SyncIndex index;
  int received = 0;
  int deleted = 0;
  int sent = 0;

  /// Items that arrived but could not be stored, with why.
  final List<String> failed = <String>[];

  bool get changedHere => received > 0 || deleted > 0;
}

Future<SyncResult> exchange(
  SyncLink link,
  SyncData data,
  SyncIndex local,
) async {
  await link.sendJson(<String, Object?>{
    't': 'index',
    'entries': indexToJson(local),
  });
  final Map<String, Object?> theirs = await link.receiveJson();
  if (theirs['t'] != 'index') {
    throw const SyncException('The other device sent something unexpected.');
  }
  final SyncIndex remote = indexFromJson(theirs['entries']);
  final List<String> take = keysToTake(local, remote);
  final List<String> fetch = <String>[
    for (final String k in take)
      if (!remote[k]!.deleted) k,
  ];
  await link.sendJson(<String, Object?>{'t': 'want', 'keys': fetch});
  final Map<String, Object?> want = await link.receiveJson();
  final Object? keys = want['keys'];
  if (want['t'] != 'want' || keys is! List) {
    throw const SyncException('The other device sent something unexpected.');
  }

  final SyncResult r = SyncResult(<String, SyncEntry>{...local});
  for (final Object? k in keys) {
    final SyncEntry? mine = k is String ? local[k] : null;
    Uint8List? bytes;
    if (mine != null && !mine.deleted) {
      try {
        bytes = await data.read(k! as String);
        if (sha256Hex(bytes) != mine.hash) {
          bytes = null; // changed since the scan: next sync sends it
        }
      } on Object {
        bytes = null;
      }
    }
    await link.sendJson(<String, Object?>{
      't': 'item',
      'key': k,
      'ok': bytes != null,
    });
    if (bytes != null) {
      await link.sendBytes(bytes);
      r.sent++;
    }
  }
  await link.sendJson(<String, Object?>{'t': 'end'});

  final Set<String> asked = fetch.toSet();
  while (true) {
    final Map<String, Object?> m = await link.receiveJson();
    if (m['t'] == 'end') {
      break;
    }
    final Object? key = m['key'];
    if (m['t'] != 'item' || key is! String || !asked.remove(key)) {
      throw const SyncException('The other device sent something unexpected.');
    }
    if (m['ok'] != true) {
      continue;
    }
    final Uint8List bytes = await link.receiveBytes();
    final SyncEntry want = remote[key]!;
    if (sha256Hex(bytes) != want.hash) {
      r.failed.add('$key: arrived damaged');
      continue;
    }
    try {
      await data.write(key, bytes);
      // What this side stores may be a tidied copy (preset details): keep
      // its own hash with the winner's time, so it is not taken as an edit.
      r.index[key] = SyncEntry(sha256Hex(await data.read(key)), want.time);
      r.received++;
    } on Object catch (e) {
      r.failed.add('$key: $e');
    }
  }

  for (final String k in take) {
    if (!remote[k]!.deleted) {
      continue;
    }
    try {
      await data.delete(k);
      r.index[k] = remote[k]!;
      r.deleted++;
    } on Object catch (e) {
      r.failed.add('$k: $e');
    }
  }
  // Deletes this side never had are kept, so the item cannot come back
  // from a third device that still holds it.
  for (final MapEntry<String, SyncEntry> e in remote.entries) {
    if (e.value.deleted && !r.index.containsKey(e.key)) {
      r.index[e.key] = e.value;
    }
  }
  // Both sides end together, each with all it took stored.
  await link.sendJson(<String, Object?>{'t': 'done'});
  if ((await link.receiveJson(const Duration(minutes: 2)))['t'] != 'done') {
    throw const SyncException('The other device sent something unexpected.');
  }
  return r;
}
