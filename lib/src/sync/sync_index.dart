// SPDX-License-Identifier: GPL-3.0-only
//
// What each device holds, item by item, and which side wins when two
// devices differ. An item is a key ("amp/Name.nam", "preset/P01"...) with the
// hash of its content and the time this device first saw that content. The
// newer edit wins; a delete is an edit with no content, so it travels too.

import 'dart:convert';

import 'package:crypto/crypto.dart';

class SyncEntry {
  const SyncEntry(this.hash, this.time);

  /// sha256 of the content in hex; empty when the item was deleted.
  final String hash;

  /// Milliseconds since the epoch when this content (or delete) was made.
  final int time;

  bool get deleted => hash.isEmpty;

  /// Whether this entry is the one kept over [other]: the later one, and on
  /// a tie the larger hash, so both devices pick the same.
  bool beats(SyncEntry other) =>
      time != other.time ? time > other.time : hash.compareTo(other.hash) > 0;

  List<Object> toJson() => <Object>[hash, time];

  static SyncEntry? fromJson(Object? j) =>
      j is List && j.length == 2 && j[0] is String && j[1] is int
      ? SyncEntry(j[0] as String, j[1] as int)
      : null;

  @override
  bool operator ==(Object other) =>
      other is SyncEntry && other.hash == hash && other.time == time;

  @override
  int get hashCode => Object.hash(hash, time);

  @override
  String toString() =>
      deleted ? 'deleted@$time' : '${hash.substring(0, 8)}@$time';
}

typedef SyncIndex = Map<String, SyncEntry>;

String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// [old] brought up to date with what is on this device [now] (key -> hash):
/// new or changed content is stamped [clock], what went away is a delete
/// stamped [clock]. A stamp is never older than the entry it replaces, so a
/// wrong clock cannot make a new edit lose to the old one.
SyncIndex refreshIndex(SyncIndex old, Map<String, String> now, int clock) {
  int stamp(SyncEntry? was) =>
      was == null || clock > was.time ? clock : was.time + 1;
  return <String, SyncEntry>{
    for (final MapEntry<String, String> e in now.entries)
      e.key: old[e.key]?.hash == e.value
          ? old[e.key]!
          : SyncEntry(e.value, stamp(old[e.key])),
    for (final MapEntry<String, SyncEntry> e in old.entries)
      if (!now.containsKey(e.key))
        e.key: e.value.deleted ? e.value : SyncEntry('', stamp(e.value)),
  };
}

/// The keys where [remote] wins over [local] with other content: what this
/// device must take (fetch, or delete when the winner is a delete).
List<String> keysToTake(SyncIndex local, SyncIndex remote) => <String>[
  for (final MapEntry<String, SyncEntry> e in remote.entries)
    if (local[e.key] == null
        ? !e.value.deleted
        : e.value.hash != local[e.key]!.hash && e.value.beats(local[e.key]!))
      e.key,
];

/// A short fingerprint of [index]: two devices with the same one hold the
/// same things.
String indexRevision(SyncIndex index) {
  final List<String> keys = <String>[
    for (final MapEntry<String, SyncEntry> e in index.entries)
      if (!e.value.deleted) e.key,
  ]..sort();
  return sha256Hex(
    utf8.encode(
      <String>[for (final String k in keys) '$k ${index[k]!.hash}'].join('\n'),
    ),
  ).substring(0, 16);
}

Map<String, Object> indexToJson(SyncIndex index) => <String, Object>{
  for (final MapEntry<String, SyncEntry> e in index.entries)
    e.key: e.value.toJson(),
};

SyncIndex indexFromJson(Object? j) => <String, SyncEntry>{
  if (j is Map)
    for (final MapEntry<dynamic, dynamic> e in j.entries)
      if (e.key is String)
        if (SyncEntry.fromJson(e.value) case final SyncEntry s)
          e.key as String: s,
};

List<int> sha256Bytes(List<int> bytes) => sha256.convert(bytes).bytes;
