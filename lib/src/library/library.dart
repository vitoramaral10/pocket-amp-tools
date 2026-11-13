// SPDX-License-Identifier: GPL-3.0-only
//
// The user's own amp captures (.nam) and IRs (.wav), kept on the computer in
// `Documents/Pocket AMP Tools/Library/{Amps,Cabinets}`, plus a record of which
// file went to which pedal slot. The pedal cannot give a model or an IR back,
// so this record is the only way to know where a slot's sound came from.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../presets/ir_upload.dart';
import '../presets/nam_file.dart';

enum LibraryKind {
  amp('Amps', 'nam'),
  cab('Cabinets', 'wav');

  const LibraryKind(this.folder, this.extension);
  final String folder;
  final String extension;
}

class LibraryException implements Exception {
  const LibraryException(this.message);
  final String message;
  @override
  String toString() => message;
}

class LibraryItem {
  const LibraryItem(this.kind, this.file);
  final LibraryKind kind;
  final File file;

  String get fileName => file.uri.pathSegments.last;

  /// The file name without its extension.
  String get name => fileName.substring(0, fileName.length - 4);
}

class Library {
  Library(this.root);

  /// `.../Pocket AMP Tools/Library`.
  final Directory root;

  Directory _dir(LibraryKind k) =>
      Directory('${root.path}${Platform.pathSeparator}${k.folder}');
  File get _linksFile =>
      File('${root.path}${Platform.pathSeparator}links.json');

  /// The files of [kind], by name.
  Future<List<LibraryItem>> list(LibraryKind kind) async {
    final Directory d = _dir(kind);
    if (!await d.exists()) {
      return <LibraryItem>[];
    }
    final List<LibraryItem> items = <LibraryItem>[
      await for (final FileSystemEntity e in d.list())
        if (e is File && e.path.toLowerCase().endsWith('.${kind.extension}'))
          LibraryItem(kind, e),
    ];
    items.sort(
      (LibraryItem a, LibraryItem b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return items;
  }

  /// Copies [bytes] into the library as [fileName] after checking the pedal
  /// can take it; a name already in use gets " (2)", " (3)"...
  Future<LibraryItem> import(
    LibraryKind kind,
    String fileName,
    Uint8List bytes,
  ) async {
    check(kind, bytes);
    final String base = _baseName(fileName, kind);
    final Directory d = await _dir(kind).create(recursive: true);
    File f = _file(d, base, kind);
    for (int n = 2; await f.exists(); n++) {
      f = _file(d, '$base ($n)', kind);
    }
    await f.writeAsBytes(bytes, flush: true);
    return LibraryItem(kind, f);
  }

  /// Throws [InvalidNamFile] or [InvalidIrFile] when the pedal cannot take
  /// [bytes] as a [kind].
  static void check(LibraryKind kind, Uint8List bytes) {
    switch (kind) {
      case LibraryKind.amp:
        final String text;
        try {
          text = utf8.decode(bytes);
        } on FormatException {
          throw const InvalidNamFile('Not a .nam file (it is not text).');
        }
        namFileToImage(text, 'check');
      case LibraryKind.cab:
        parseIrWav(bytes);
    }
  }

  Future<LibraryItem> rename(LibraryItem item, String newName) async {
    final String base = _baseName('$newName.x', item.kind);
    if (base == item.name) {
      return item;
    }
    final File to = _file(item.file.parent, base, item.kind);
    if (await to.exists()) {
      throw LibraryException('"$base" is already in the library.');
    }
    final File moved = await item.file.rename(to.path);
    await _editLinks((Map<String, dynamic> kinds) {
      final Map<String, dynamic> slots = _slots(kinds, item.kind);
      slots.updateAll(
        (String _, dynamic f) =>
            f == item.fileName ? '$base.${item.kind.extension}' : f,
      );
    });
    return LibraryItem(item.kind, moved);
  }

  /// Deletes the file from the library; the pedal keeps what it has.
  Future<void> delete(LibraryItem item) async {
    await item.file.delete();
    await _editLinks((Map<String, dynamic> kinds) {
      _slots(
        kinds,
        item.kind,
      ).removeWhere((String _, dynamic f) => f == item.fileName);
    });
  }

  /// The library file each slot (0..19) of [kind] was last written from, for
  /// slots whose file is still in the library.
  Future<Map<int, String>> links(LibraryKind kind) async {
    final Map<String, dynamic> all = await _readLinks();
    final Map<String, dynamic> slots = _slots(all, kind);
    final Set<String> have = <String>{
      for (final LibraryItem i in await list(kind)) i.fileName,
    };
    return <int, String>{
      for (final MapEntry<String, dynamic> e in slots.entries)
        if (int.tryParse(e.key) != null && have.contains(e.value))
          int.parse(e.key): (e.value as String).substring(
            0,
            (e.value as String).length - 4,
          ),
    };
  }

  /// Records that slot [slot] of [kind] now holds [item].
  Future<void> link(LibraryKind kind, int slot, LibraryItem item) =>
      _editLinks((Map<String, dynamic> kinds) {
        _slots(kinds, kind)['$slot'] = item.fileName;
      });

  // shortcut: one record for every pedal, since the pedal has no serial
  // number to tell two units apart; key it by unit if that ever changes.
  Future<Map<String, dynamic>> _readLinks() async {
    try {
      final Object? j = jsonDecode(await _linksFile.readAsString());
      return j is Map<String, dynamic> ? j : <String, dynamic>{};
    } on FileSystemException {
      return <String, dynamic>{};
    } on FormatException {
      return <String, dynamic>{}; // a broken record only loses the links
    }
  }

  Future<void> _editLinks(void Function(Map<String, dynamic>) edit) async {
    final Map<String, dynamic> all = await _readLinks();
    edit(all);
    await root.create(recursive: true);
    await _linksFile.writeAsString(jsonEncode(all), flush: true);
  }

  static Map<String, dynamic> _slots(Map<String, dynamic> all, LibraryKind k) =>
      (all[k.name] ??= <String, dynamic>{}) as Map<String, dynamic>;

  static File _file(Directory d, String base, LibraryKind k) =>
      File('${d.path}${Platform.pathSeparator}$base.${k.extension}');

  /// A file name safe on every desktop system, without its extension.
  static String _baseName(String fileName, LibraryKind kind) {
    final int dot = fileName.lastIndexOf('.');
    final String raw = (dot > 0 ? fileName.substring(0, dot) : fileName)
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
        .trim();
    if (raw.isEmpty || raw == '.' || raw == '..') {
      throw const LibraryException('The name is empty.');
    }
    return raw.length > 80 ? raw.substring(0, 80) : raw;
  }
}
