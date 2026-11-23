// SPDX-License-Identifier: GPL-3.0-only
//
// The things that travel between devices, as keys and bytes:
//   amp/<file>.nam, cab/<file>.wav  the library
//   links                           which library file went to which slot
//   backup/<file>.json              preset backups
//   preset/P01..P80, labels         names, notes, labels and ratings
// Secrets (assistant key, TONE3000 sign-in), consent and settings stay on
// each device. What comes in is checked as strictly as a file the user
// picks: a paired device is trusted to sync, not to write anywhere.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../library/library.dart';
import '../presets/mefcs.dart';
import '../presets/preset_backup.dart';
import '../presets/preset_meta.dart';
import 'sync_index.dart';

class SyncData {
  SyncData({
    required this.library,
    required this.backups,
    required this.details,
  });

  /// `.../Pocket AMP Tools/Library`.
  final Directory library;

  /// `.../Pocket AMP Tools`, where backups are kept.
  final Directory backups;

  /// The live preset details: changes go through it so the app shows them
  /// and its next save keeps them.
  final PresetDetails details;

  // Hashes of files by path, kept while size, modified time and change time
  // stay the same. The change time moves on every write and no tool can set
  // it back, so a rewrite that keeps the size and modified time is seen too.
  final Map<String, (int, DateTime, DateTime, String)> _hashes =
      <String, (int, DateTime, DateTime, String)>{};

  static const int _maxFile = 16 << 20;
  static const int _maxBackup = 4 << 20;
  static final RegExp _name = RegExp(r'^[^\\/:*?"<>|\x00-\x1F]{1,120}$');

  /// Every item on this device now: key -> sha256 of its bytes.
  Future<Map<String, String>> scan() async {
    final Map<String, String> out = <String, String>{};
    for (final LibraryKind k in LibraryKind.values) {
      await _scanDir(
        Directory('${library.path}${Platform.pathSeparator}${k.folder}'),
        '.${k.extension}',
        '${_prefix(k)}/',
        _maxFile,
        out,
      );
    }
    await _scanDir(backups, '.json', 'backup/', _maxBackup, out);
    final File links = _links;
    if (links.existsSync()) {
      out['links'] = await _hash(links);
    }
    for (int id = 0; id < presetCount; id++) {
      if (!details.metas[id].isEmpty) {
        out[_presetKey(id)] = sha256Hex(_metaBytes(id));
      }
    }
    out['labels'] = sha256Hex(_labelBytes());
    return out;
  }

  /// The bytes of [key], as [scan] hashed them.
  Future<Uint8List> read(String key) async {
    if (key == 'labels') {
      return _labelBytes();
    }
    if (_presetId(key) case final int id) {
      return _metaBytes(id);
    }
    return _fileOf(key).readAsBytes();
  }

  /// Stores [data] as [key]; throws [FormatException] when it is not what
  /// that key holds.
  Future<void> write(String key, Uint8List data) async {
    if (key == 'labels') {
      final Object? j = jsonDecode(utf8.decode(data));
      if (j is! Map<String, Object?>) {
        throw const FormatException('labels: expected an object');
      }
      details.fromJson(<String, Object?>{'labels': j});
      details.changed();
      return;
    }
    if (_presetId(key) case final int id) {
      details.metas[id] = PresetMeta.fromJson(jsonDecode(utf8.decode(data)));
      details.changed();
      return;
    }
    final File f = _fileOf(key);
    switch (key.split('/').first) {
      case 'amp':
        Library.check(LibraryKind.amp, data);
      case 'cab':
        Library.check(LibraryKind.cab, data);
      case 'backup':
        if (data.length > _maxBackup) {
          throw const FormatException('backup too large');
        }
        PresetBackup.fromJson(utf8.decode(data));
      case 'links':
        if (data.length > 1 << 20) {
          throw const FormatException('links: too large');
        }
        _checkLinks(jsonDecode(utf8.decode(data)));
    }
    await f.parent.create(recursive: true);
    final File tmp = File('${f.path}.sync');
    await tmp.writeAsBytes(data, flush: true);
    await tmp.rename(f.path);
  }

  /// Removes [key] from this device.
  Future<void> delete(String key) async {
    if (key == 'labels') {
      return; // the label lists always exist
    }
    if (_presetId(key) case final int id) {
      details.metas[id] = PresetMeta();
      details.changed();
      return;
    }
    final File f = _fileOf(key);
    if (await f.exists()) {
      await f.delete();
    }
  }

  /// Throws unless [j] is a links record this app's [Library] reads: slot
  /// maps of 0..19 to file names, and the list of captures with a cabinet.
  static void _checkLinks(Object? j) {
    bool file(Object? v, String ext) =>
        v is String &&
        _name.hasMatch(v) &&
        v.trim() == v &&
        !v.startsWith('.') &&
        v.length > ext.length &&
        v.toLowerCase().endsWith(ext);
    if (j is! Map<String, Object?>) {
      throw const FormatException('links: expected an object');
    }
    for (final LibraryKind k in LibraryKind.values) {
      final Object? slots = j[k.name];
      if (slots == null) {
        continue;
      }
      if (slots is! Map<String, Object?> ||
          slots.entries.any((MapEntry<String, Object?> e) {
            final int? n = int.tryParse(e.key);
            return n == null ||
                n < 0 ||
                n > 19 ||
                '$n' != e.key ||
                !file(e.value, '.${k.extension}');
          })) {
        throw FormatException('links: bad ${k.name} slots');
      }
    }
    final Object? withCab = j['ampWithCab'];
    if (withCab != null &&
        (withCab is! List || withCab.any((Object? v) => !file(v, '.nam')))) {
      throw const FormatException('links: bad ampWithCab');
    }
  }

  File get _links => File('${library.path}${Platform.pathSeparator}links.json');

  /// The file [key] names; throws [FormatException] for any other key, so a
  /// key from another device can never point outside these folders.
  File _fileOf(String key) {
    if (key == 'links') {
      return _links;
    }
    final int slash = key.indexOf('/');
    final String kind = slash < 0 ? key : key.substring(0, slash);
    final String name = slash < 0 ? '' : key.substring(slash + 1);
    final (Directory? dir, String ext) = switch (kind) {
      'amp' => (_kindDir(LibraryKind.amp), '.nam'),
      'cab' => (_kindDir(LibraryKind.cab), '.wav'),
      'backup' => (backups, '.json'),
      _ => (null, ''),
    };
    if (dir == null ||
        !_name.hasMatch(name) ||
        name.trim() != name ||
        !name.toLowerCase().endsWith(ext) ||
        name.length == ext.length ||
        name.startsWith('.')) {
      throw FormatException('not a key this app syncs: $key');
    }
    return File('${dir.path}${Platform.pathSeparator}$name');
  }

  Directory _kindDir(LibraryKind k) =>
      Directory('${library.path}${Platform.pathSeparator}${k.folder}');

  static String _prefix(LibraryKind k) => k == LibraryKind.amp ? 'amp' : 'cab';

  static String _presetKey(int id) =>
      'preset/P${(id + 1).toString().padLeft(2, '0')}';

  static int? _presetId(String key) {
    final RegExpMatch? m = RegExp(r'^preset/P(\d\d)$').firstMatch(key);
    final int? n = m == null ? null : int.parse(m[1]!);
    return n != null && n >= 1 && n <= presetCount ? n - 1 : null;
  }

  Uint8List _metaBytes(int id) =>
      utf8.encode(jsonEncode(details.metas[id].toJson()));

  Uint8List _labelBytes() =>
      utf8.encode(jsonEncode(details.toJson()['labels']));

  Future<void> _scanDir(
    Directory d,
    String ext,
    String prefix,
    int max,
    Map<String, String> out,
  ) async {
    if (!await d.exists()) {
      return;
    }
    await for (final FileSystemEntity e in d.list(followLinks: false)) {
      final String name = e.uri.pathSegments.last;
      if (e is! File ||
          !name.toLowerCase().endsWith(ext) ||
          !_name.hasMatch(name) ||
          name.trim() != name ||
          name.startsWith('.')) {
        continue;
      }
      try {
        if (await e.length() <= max) {
          out['$prefix$name'] = await _hash(e);
        }
      } on FileSystemException {
        // Gone while listing: it is simply not there.
      }
    }
  }

  Future<String> _hash(File f) async {
    final FileStat st = await f.stat();
    final (int, DateTime, DateTime, String)? was = _hashes[f.path];
    if (was != null &&
        was.$1 == st.size &&
        was.$2 == st.modified &&
        was.$3 == st.changed) {
      return was.$4;
    }
    final String h = sha256Hex(await f.readAsBytes());
    _hashes[f.path] = (st.size, st.modified, st.changed, h);
    return h;
  }
}
