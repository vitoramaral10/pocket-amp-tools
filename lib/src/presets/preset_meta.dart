// SPDX-License-Identifier: GPL-3.0-only

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'mefcs.dart';

/// The label categories a preset can be tagged with, in display order.
enum MetaCategory {
  genres('Genres', 'Genre'),
  uses('Usage', 'Use'),
  tags('Tags', 'Tag');

  const MetaCategory(this.title, this.singular);
  final String title;
  final String singular;
}

/// What the user wrote about one preset slot. The pedal stores none of it.
class PresetMeta {
  PresetMeta({
    this.name = '',
    this.description = '',
    Map<MetaCategory, Set<String>>? labels,
    this.rating = 0,
  }) : labels = <MetaCategory, Set<String>>{
         for (final MetaCategory c in MetaCategory.values)
           c: <String>{...?labels?[c]},
       };

  factory PresetMeta.fromJson(Object? j) {
    if (j is! Map<String, Object?>) {
      return PresetMeta();
    }
    final Object? r = j['rating'];
    return PresetMeta(
      name: j['name'] is String ? j['name']! as String : '',
      description: j['description'] is String
          ? j['description']! as String
          : '',
      labels: <MetaCategory, Set<String>>{
        for (final MetaCategory c in MetaCategory.values)
          c: _strings(j[c.name]).toSet(),
      },
      rating: r is int ? r.clamp(0, 5) : 0,
    );
  }

  String name;
  String description;
  final Map<MetaCategory, Set<String>> labels;

  /// 1 to 5 stars; 0 when not rated.
  int rating;

  bool get isEmpty =>
      name.isEmpty &&
      description.isEmpty &&
      rating == 0 &&
      labels.values.every((Set<String> s) => s.isEmpty);

  Map<String, Object> toJson() => <String, Object>{
    if (name.isNotEmpty) 'name': name,
    if (description.isNotEmpty) 'description': description,
    for (final MetaCategory c in MetaCategory.values)
      if (labels[c]!.isNotEmpty) c.name: labels[c]!.toList(),
    if (rating > 0) 'rating': rating,
  };
}

List<String> _strings(Object? v) => v is List<Object?>
    ? <String>[
        for (final Object? e in v)
          if (e is String && e.trim().isNotEmpty) e.trim(),
      ]
    : <String>[];

const Map<MetaCategory, List<String>> defaultLabels =
    <MetaCategory, List<String>>{
      MetaCategory.genres: <String>[
        'Blues',
        'Rock',
        'Hard rock',
        'Metal',
        'Punk',
        'Pop',
        'Indie',
        'Funk',
        'Jazz',
        'Country',
        'Ambient',
      ],
      MetaCategory.uses: <String>[
        'Rhythm',
        'Solo',
        'Riffs',
        'Arpeggios',
        'Clean',
        'Ambient',
      ],
      MetaCategory.tags: <String>[],
    };

/// Names, descriptions, labels and ratings of the 80 slots, the labels the
/// user can pick from, and the filter on the preset list. Saved to a file in
/// the app's folder on every change, once [open] has read it.
///
/// shortcut: one set for every pedal, keyed by slot; key by pedal identity
/// if people edit several pedals.
class PresetDetails extends ChangeNotifier {
  PresetDetails();

  final List<PresetMeta> metas = <PresetMeta>[
    for (int i = 0; i < presetCount; i++) PresetMeta(),
  ];

  final Map<MetaCategory, List<String>> labels = <MetaCategory, List<String>>{
    for (final MetaCategory c in MetaCategory.values)
      c: List<String>.of(defaultLabels[c]!),
  };

  /// Selected filter values: OR within a category, AND across categories.
  final Map<MetaCategory, Set<String>> filter = <MetaCategory, Set<String>>{
    for (final MetaCategory c in MetaCategory.values) c: <String>{},
  };

  /// Presets rated below this are hidden; 0 hides none.
  int minRating = 0;

  File? _file;
  Future<void> _saving = Future<void>.value();

  static Future<File> defaultFile() async => File(
    '${(await getApplicationSupportDirectory()).path}'
    '${Platform.pathSeparator}preset-details.json',
  );

  /// Reads [file] (the app's file by default) and saves there from now on.
  /// A file that cannot be read is never overwritten: it is moved aside
  /// (`….unreadable-<time>`) and a new one is started; if it cannot be moved,
  /// nothing is saved this session.
  Future<void> open([File? file]) async {
    try {
      final File f = file ?? await defaultFile();
      try {
        // A small file, read in one go so the names are there on the first
        // frame that shows presets.
        if (f.existsSync()) {
          fromJson(jsonDecode(f.readAsStringSync()));
        }
      } catch (e) {
        debugPrint('Preset details not loaded: $e');
        f.renameSync(
          '${f.path}.unreadable-${DateTime.now().millisecondsSinceEpoch}',
        );
      }
      _file = f;
      notifyListeners();
    } catch (e) {
      debugPrint('Preset details not saved this session: $e');
    }
  }

  /// Completes when every change so far is in the file.
  Future<void> get saved => _saving;

  void fromJson(Object? j) {
    if (j is! Map<String, Object?>) {
      throw const FormatException('expected an object');
    }
    final Object? l = j['labels'];
    if (l is Map<String, Object?>) {
      for (final MetaCategory c in MetaCategory.values) {
        if (l[c.name] is List<Object?>) {
          labels[c] = _strings(l[c.name]).toSet().toList();
        }
      }
    }
    final Object? p = j['presets'];
    if (p is Map<String, Object?>) {
      for (int id = 0; id < presetCount; id++) {
        metas[id] = PresetMeta.fromJson(p[_slot(id)]);
      }
    }
  }

  Map<String, Object> toJson() => <String, Object>{
    'format': 'pocket-amp-tools/preset-details@1',
    'labels': <String, Object>{
      for (final MetaCategory c in MetaCategory.values) c.name: labels[c]!,
    },
    'presets': <String, Object>{
      for (int id = 0; id < presetCount; id++)
        if (!metas[id].isEmpty) _slot(id): metas[id].toJson(),
    },
  };

  /// Call after changing a [PresetMeta] in [metas].
  void changed() {
    notifyListeners();
    final File? f = _file;
    if (f == null) {
      return;
    }
    final String text = const JsonEncoder.withIndent('  ').convert(toJson());
    // In order, and through a temporary file so a crash never leaves half a
    // file behind.
    _saving = _saving.then((_) async {
      try {
        final File tmp = File('${f.path}.tmp');
        await tmp.writeAsString(text, flush: true);
        await tmp.rename(f.path);
      } catch (e) {
        debugPrint('Preset details not saved: $e');
      }
    });
  }

  /// Adds [label] to [c]; false if empty or already there (any case).
  bool addLabel(MetaCategory c, String label) {
    final String l = label.trim();
    if (l.isEmpty ||
        labels[c]!.any((String x) => x.toLowerCase() == l.toLowerCase())) {
      return false;
    }
    labels[c]!.add(l);
    changed();
    return true;
  }

  /// [typed] as it is spelled among the labels of [c], added if it is new.
  String useLabel(MetaCategory c, String typed) {
    final String l = typed.trim();
    for (final String x in offered(c)) {
      if (x.toLowerCase() == l.toLowerCase()) {
        return x;
      }
    }
    addLabel(c, l);
    return l;
  }

  /// Removes [label] from [c], from every preset and from the filter.
  void removeLabel(MetaCategory c, String label) {
    labels[c]!.remove(label);
    for (final PresetMeta m in metas) {
      m.labels[c]!.remove(label);
    }
    filter[c]!.remove(label);
    changed();
  }

  /// The labels to offer for [c]: the list, then any a preset still carries
  /// that the list does not (from an older file).
  List<String> offered(MetaCategory c) => <String>{
    ...labels[c]!,
    for (final PresetMeta m in metas) ...m.labels[c]!,
  }.toList();

  bool get filtering =>
      minRating > 0 || filter.values.any((Set<String> s) => s.isNotEmpty);

  bool matches(int id) {
    final PresetMeta m = metas[id];
    if (m.rating < minRating) {
      return false;
    }
    for (final MetaCategory c in MetaCategory.values) {
      final Set<String> want = filter[c]!;
      if (want.isNotEmpty && !want.any(m.labels[c]!.contains)) {
        return false;
      }
    }
    return true;
  }

  void setFilter(MetaCategory c, String label, bool on) {
    on ? filter[c]!.add(label) : filter[c]!.remove(label);
    notifyListeners();
  }

  void setMinRating(int r) {
    minRating = r;
    notifyListeners();
  }

  void clearFilter() {
    for (final Set<String> s in filter.values) {
      s.clear();
    }
    minRating = 0;
    notifyListeners();
  }
}

String _slot(int id) => 'P${(id + 1).toString().padLeft(2, '0')}';
