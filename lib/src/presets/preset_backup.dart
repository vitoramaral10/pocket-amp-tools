// SPDX-License-Identifier: GPL-3.0-only

import 'dart:convert';
import 'dart:typed_data';

import 'block_models.dart';
import 'mefcs.dart';
import 'preset_session.dart';
import 'write_guard.dart';

/// The 80 preset bodies and the EQ table, as stored in the pedal's flash.
class PresetBackup {
  PresetBackup({
    required this.identity,
    required this.created,
    required this.presets,
    required this.eq,
    this.oldLayout = false,
  }) {
    if (presets.length != presetCount * presetSize ||
        eq.length != eqTableLength) {
      throw const FormatException('Backup has the wrong size.');
    }
    for (int i = 0; i < eqHeader.length; i++) {
      if (eq[i] != eqHeader[i]) {
        throw const FormatException('Backup EQ table is not valid.');
      }
    }
  }

  /// Reads a backup. Version 2 and 3 files are restored from their plain
  /// fields (version 2 names knobs, version 3 lists them by position);
  /// version 1 files from their raw data.
  factory PresetBackup.fromJson(String text) {
    final Object? j = jsonDecode(text);
    if (j is! Map<String, Object?> ||
        !<Object?>[format, formatV2, formatV1].contains(j['format'])) {
      throw const FormatException('Not a Pocket AMP Tools preset backup.');
    }
    final String identity = j['pedal'] as String? ?? '?';
    final DateTime created = DateTime.parse(j['created'] as String);
    if (j['format'] == formatV1) {
      return PresetBackup(
        identity: identity,
        created: created,
        presets: base64Decode(j['presets'] as String),
        eq: base64Decode(j['eq'] as String),
      );
    }
    final Object? names = j['models'];
    if (names != null && names != modelListId) {
      throw FormatException(
        'This backup names models with the list "$names"; this version of '
        'the app uses "$modelListId", so the same names could mean other '
        'bytes.',
      );
    }
    final Object? list = j['presets'];
    if (list is! List<Object?> || list.length != presetCount) {
      throw const FormatException(
        '"presets" must list all $presetCount presets.',
      );
    }
    final Uint8List presets = Uint8List(presetCount * presetSize);
    final Uint8List eq = Uint8List(eqTableLength)..setAll(0, eqHeader);
    for (int id = 0; id < presetCount; id++) {
      final _Reader r = _Reader(_slot(id));
      final Map<String, Object?> f = r.map(list[id], '');
      if (f['preset'] != _slot(id)) {
        throw FormatException(
          'Preset ${id + 1} in the list is "${f['preset']}", expected '
          '"${_slot(id)}". Keep the presets in order.',
        );
      }
      presets.setAll(id * presetSize, r.preset(f));
      eq.setAll(eqHeaderLength + id * eqRecordLength, r.eq(f['eq'], 'eq'));
    }
    return PresetBackup(
      identity: identity,
      created: created,
      presets: presets,
      eq: eq,
    );
  }

  /// P01..P79 read from a pedal on older clone firmware ([isOldPresetArea]),
  /// which has no EQ table and does not answer past [oldFirmwareReadable].
  /// Only for viewing: the EQ table is a flat filler, P80 is cut short, and
  /// writing to that firmware was never tested, so it is neither restored
  /// nor saved to a file.
  factory PresetBackup.oldLayout(String identity, Uint8List area) {
    if (!isOldPresetArea(area)) {
      throw const FormatException(
        'This raw copy is not in the layout of PIXIE1 V0.07.',
      );
    }
    return PresetBackup(
      identity: identity,
      created: DateTime.now(),
      presets: Uint8List(presetCount * presetSize)
        ..setRange(0, oldFirmwareReadable, area),
      eq: Uint8List(eqTableLength)..setAll(0, eqHeader),
      oldLayout: true,
    );
  }

  static const String format = 'pocket-amp-upgrader/presets@3';
  static const String formatV2 = 'pocket-amp-upgrader/presets@2';
  static const String formatV1 = 'pocket-amp-upgrader/presets@1';

  final String identity;
  final DateTime created;
  final Uint8List presets;
  final Uint8List eq;

  /// See [PresetBackup.oldLayout].
  final bool oldLayout;

  /// Presets that hold real data: P80 is cut short in [oldLayout].
  int get usableCount => oldLayout ? oldPresetCount : presetCount;

  Uint8List preset(int id) =>
      Uint8List.sublistView(presets, id * presetSize, (id + 1) * presetSize);

  Uint8List eqRecord(int id) {
    final int at = eqHeaderLength + id * eqRecordLength;
    return Uint8List.sublistView(eq, at, at + eqRecordLength);
  }

  /// This bank with P01..P79 taken from the raw copy [area] of a pedal on
  /// older clone firmware (see [oldFirmwareReadable]); P80 and every EQ
  /// record stay as they are here. Throws [FormatException] when [area] is
  /// not laid out like that.
  PresetBackup withOldPresets(Uint8List area) {
    if (!isOldPresetArea(area)) {
      throw const FormatException(
        'This raw copy is not in the layout of PIXIE1 V0.07.',
      );
    }
    final PresetBackup b = copy();
    b.presets.setRange(0, oldPresetCount * presetSize, area);
    return b;
  }

  /// A copy whose bytes can be edited without touching this one.
  PresetBackup copy() => PresetBackup(
    identity: identity,
    created: created,
    presets: Uint8List.fromList(presets),
    eq: Uint8List.fromList(eq),
    oldLayout: oldLayout,
  );

  // --- editing, by preset id and block position ---------------------------

  int _le16(int at) => presets[at] | (presets[at + 1] << 8);
  void _setLe16(int at, int v) => presets
    ..[at] = v & 0xFF
    ..[at + 1] = (v >> 8) & 0xFF;

  int volume(int id) => _le16(id * presetSize);
  void setVolume(int id, int v) => _setLe16(id * presetSize, v);

  /// Block positions in the order the signal goes through them.
  List<int> chain(int id) =>
      presets.sublist(id * presetSize + 2, id * presetSize + 8);
  void setChain(int id, List<int> order) =>
      presets.setAll(id * presetSize + 2, order);

  bool isOn(int id, int block) => presets[id * presetSize + 8 + block] != 0;
  void setOn(int id, int block, bool on) =>
      presets[id * presetSize + 8 + block] = on ? 1 : 0;

  int model(int id, int block) => presets[id * presetSize + 14 + block];
  void setModel(int id, int block, int model) =>
      presets[id * presetSize + 14 + block] = model;

  int knob(int id, int block, int k) =>
      _le16(id * presetSize + 20 + block * 12 + k * 2);
  void setKnob(int id, int block, int k, int v) =>
      _setLe16(id * presetSize + 20 + block * 12 + k * 2, v);

  int _eqAt(int id) => eqHeaderLength + id * eqRecordLength;
  bool eqOn(int id) => eq[_eqAt(id)] != 0;
  void setEqOn(int id, bool on) => eq[_eqAt(id)] = on ? 1 : 0;
  bool eqAtHead(int id) => eq[_eqAt(id) + 1] == 1;
  void setEqAtHead(int id, bool head) => eq[_eqAt(id) + 1] = head ? 1 : 0;
  int eqBand(int id, int band) => eq[_eqAt(id) + 2 + band].toSigned(8);
  void setEqBand(int id, int band, int v) =>
      eq[_eqAt(id) + 2 + band] = v & 0xFF;

  /// One preset as the plain fields of a backup file.
  Map<String, Object> presetFields(int id) => _readable(id);

  /// Replaces preset [id] and its EQ with [fields], in the shape of
  /// [presetFields]; the "preset" key, if any, is ignored. With [keepEq] the
  /// stored EQ record stays as it is and "eq" is not read: for a record in
  /// a form the app cannot write back.
  void setPresetFields(
    int id,
    Map<String, Object?> fields, {
    bool keepEq = false,
  }) {
    final _Reader r = _Reader(_slot(id), strict: true);
    final Uint8List body = r.preset(fields);
    final Uint8List? record = keepEq ? null : r.eq(fields['eq'], 'eq');
    presets.setAll(id * presetSize, body);
    if (record != null) {
      eq.setAll(_eqAt(id), record);
    }
  }

  /// Every preset as plain fields. Holds every byte of the preset and of its
  /// EQ record, so the restore is built from it alone.
  List<Map<String, Object>> get readable => <Map<String, Object>>[
    for (int id = 0; id < presetCount; id++) _readable(id),
  ];

  Map<String, Object> _readable(int id) {
    final Uint8List p = preset(id);
    int le16(int at) => p[at] | (p[at + 1] << 8);
    return <String, Object>{
      'preset': _slot(id),
      'volume': le16(0),
      'chain': <Object>[
        for (final int b in p.sublist(2, 8))
          b < blockNames.length ? blockNames[b] : b,
      ],
      'blocks': <String, Object>{
        for (int b = 0; b < blockNames.length; b++)
          blockNames[b]: <String, Object>{
            'on': _flag(p[8 + b]),
            'model': _modelName(blockNames[b], p[14 + b]) ?? p[14 + b],
            'knobs': <Map<String, Object>>[
              for (final (int k, String label) in knobLabels(
                blockNames[b],
                p[14 + b],
              ).indexed)
                <String, Object>{
                  'label': label,
                  'value': le16(20 + b * 12 + k * 2),
                },
            ],
          },
      },
      'eq': _readableEq(eqRecord(id)),
    };
  }

  String toJson() => oldLayout
      ? throw StateError('An old-firmware bank is not saved to a file.')
      : const JsonEncoder.withIndent('  ').convert(<String, Object>{
          'format': format,
          'pedal': identity,
          'created': created.toUtc().toIso8601String(),
          'about':
              'The app restores from these fields: edit a value and restore the '
              'file to change it on the pedal. Model names follow firmware '
              'V1.05. Each block lists its six stored knob values in order; '
              'the "label" only says what the knob is and is not read back, so '
              'the position decides which knob a value goes to. Labels marked '
              'unused are values the model does not use. Knob values range '
              'from 0 to 100. The EQ lists its five bands in order, labelled '
              'by frequency the same way; band values range from -6 to +6, '
              'each step being 0.5 dB. Block names follow '
              'the order on the screen and are not confirmed for every '
              'position.',
          'models': modelListId,
          'presets': readable,
        });

  String get suggestedFileName {
    String two(int v) => v.toString().padLeft(2, '0');
    final DateTime t = created;
    return 'pocket-amp-presets-${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}.json';
  }
}

/// Names for the six block positions of a preset body, taken from the order
/// on the pedal's screen. Only MOD's position was checked on a pedal.
const List<String> blockNames = <String>[
  'FX',
  'AMP',
  'MOD',
  'DLY',
  'REV',
  'CAB',
];

String _slot(int id) => 'P${(id + 1).toString().padLeft(2, '0')}';

/// A flag byte: true/false for 1/0, the number itself for anything else, so
/// nothing is lost.
Object _flag(int v) => v < 2 ? v == 1 : v;

/// The model's name in [block], or null when the list does not have it.
String? modelName(String block, int model) => _modelName(block, model);

/// Names of the six knob values of [model] in [block].
List<String> knobNames(String block, int model) => _knobNames(block, model);

/// What the backup file shows next to each of the six knob values of
/// [model] in [block]. Only informational: values are read back by position.
List<String> knobLabels(String block, int model) => <String>[
  for (final String n in _knobNames(block, model))
    n.startsWith('knob') ? '$n (unused)' : n,
];

String? _modelName(String block, int model) {
  final List<(String, List<String>)> models = blockModels[block]!;
  return model < models.length ? models[model].$1 : null;
}

/// The six stored knob values, named after the model's knobs; the ones the
/// model does not use are "knob1".."knob6" by position.
List<String> _knobNames(String block, int model) {
  final List<(String, List<String>)> models = blockModels[block]!;
  final List<String> names = model < models.length
      ? models[model].$2
      : const <String>[];
  return <String>[
    for (int k = 0; k < 6; k++) k < names.length ? names[k] : 'knob${k + 1}',
  ];
}

/// Knob names as version 2 files wrote them, by their current name.
const Map<String, String> _formerKnobNames = <String, String>{
  'MidCut (ParamA)': 'ParamA',
  'Reso (ParamB)': 'ParamB',
  'T-Mode (Grit)': 'Grit',
};

/// Centre frequencies of the five EQ bands, in band order. What the backup
/// file shows next to each band value; values are read back by position.
const List<String> eqBandLabels = <String>[
  '100Hz',
  '250Hz',
  '800Hz',
  '2kHz',
  '10kHz',
];

/// An EQ record: on/off, position in the chain (0 tail, 1 head) and five
/// bands in the steps the pedal stores (0.5 dB each).
Map<String, Object> _readableEq(Uint8List r) => <String, Object>{
  'on': _flag(r[0]),
  'position': r[1] < 2 ? const <String>['tail', 'head'][r[1]] : r[1],
  'bands': <Map<String, Object>>[
    for (final (int i, int b) in r.sublist(2).indexed)
      <String, Object>{
        'label': i < eqBandLabels.length ? eqBandLabels[i] : 'band${i + 1}',
        'value': b.toSigned(8),
      },
  ],
};

/// Turns the plain fields of one preset back into bytes, naming the preset
/// and field in every error.
class _Reader {
  /// [strict] for edits typed, pasted or suggested: the chain must list each
  /// block once and models are named. A file may also carry what the pedal
  /// itself stored (model numbers past the list).
  _Reader(this.slot, {this.strict = false});
  final String slot;
  final bool strict;

  Never _bad(String where, String what) =>
      throw FormatException('$slot $where: $what.');

  Map<String, Object?> map(Object? v, String where) =>
      v is Map<String, Object?> ? v : _bad(where, 'expected an object');

  int number(Object? v, String where, int min, int max) =>
      v is int && v >= min && v <= max
      ? v
      : _bad(where, 'expected a whole number from $min to $max, got $v');

  /// true/false; a file may also carry the number the pedal stored.
  int flag(Object? v, String where) => v is bool
      ? (v ? 1 : 0)
      : strict
      ? _bad(where, 'expected true or false, got $v')
      : number(v, where, 2, 255);

  /// Volume and knobs: 0..100 for edits; any stored value in a file.
  int level(Object? v, String where) =>
      number(v, where, 0, strict ? 100 : 0xFFFF);

  /// One of [names]; with [beyond], also a number past the list (a model
  /// the list does not know, as the pedal stored it).
  int named(
    Object? v,
    String where,
    List<String> names, {
    bool beyond = false,
  }) {
    if (v is String) {
      final int i = names.indexOf(v);
      return i >= 0 ? i : _bad(where, '"$v" is not one of ${names.join(', ')}');
    }
    return beyond
        ? number(v, where, names.length, 255)
        : _bad(where, 'expected one of ${names.join(', ')}, got $v');
  }

  Uint8List preset(Map<String, Object?> f) {
    final Uint8List p = Uint8List(presetSize);
    void le16(int at, int v) => p
      ..[at] = v & 0xFF
      ..[at + 1] = v >> 8;
    le16(0, level(f['volume'], 'volume'));
    final Object? chain = f['chain'];
    if (chain is! List<Object?> || chain.length != 6) {
      _bad('chain', 'expected a list of 6 blocks');
    }
    for (int i = 0; i < 6; i++) {
      p[2 + i] = named(chain[i], 'chain', blockNames, beyond: !strict);
    }
    if (strict && !pedalTakesChain(p.sublist(2, 8))) {
      _bad('chain', 'each block must appear once, with FX and AMP first');
    }
    final Map<String, Object?> blocks = map(f['blocks'], 'blocks');
    for (int b = 0; b < blockNames.length; b++) {
      final String name = blockNames[b];
      final Map<String, Object?> block = map(blocks[name], 'blocks.$name');
      p[8 + b] = flag(block['on'], '$name.on');
      final int model = named(block['model'], '$name.model', <String>[
        for (final (String m, _) in blockModels[name]!) m,
      ], beyond: !strict);
      p[14 + b] = model;
      final List<String> want = _knobNames(name, model);
      final List<Object?> values = knobs(block['knobs'], name, want);
      for (int k = 0; k < 6; k++) {
        le16(20 + b * 12 + k * 2, level(values[k], '$name.${want[k]}'));
      }
    }
    return p;
  }

  /// The six knob values of a block, in order. A list is read by position:
  /// each entry a number or an object with a "value" (its "label" is not
  /// read). An object is read by the knob names in [want], as version 2
  /// files and older pasted presets carry them.
  List<Object?> knobs(Object? v, String block, List<String> want) {
    if (v is List<Object?>) {
      if (v.length != 6) {
        _bad('$block.knobs', 'expected a list of 6 knob values');
      }
      return <Object?>[
        for (final Object? e in v)
          e is Map<String, Object?>
              ? (e.containsKey('value')
                    ? e['value']
                    : _bad('$block.knobs', 'each knob needs a "value"'))
              : e,
      ];
    }
    final Map<String, Object?> named = map(v, '$block.knobs');
    // Files written before a knob was renamed carry its old name.
    final List<String> keys = <String>[
      for (final String k in want)
        named.containsKey(k) ? k : (_formerKnobNames[k] ?? k),
    ];
    if (named.length != 6 || !keys.every(named.containsKey)) {
      _bad(
        '$block.knobs',
        'expected a list of 6 knob values, or exactly ${want.join(', ')}',
      );
    }
    return <Object?>[for (final String k in keys) named[k]];
  }

  Uint8List eq(Object? v, String where) {
    final Map<String, Object?> e = map(v, where);
    final Object? bands = e['bands'];
    if (bands is! List<Object?> || bands.length != 5) {
      _bad('eq.bands', 'expected 5 bands');
    }
    return Uint8List.fromList(<int>[
      flag(e['on'], 'eq.on'),
      named(e['position'], 'eq.position', const <String>[
        'tail',
        'head',
      ], beyond: !strict),
      // A band is a number, or a labelled value as the file writes it; the
      // label is not read.
      for (final Object? b in bands)
        number(
              b is Map<String, Object?>
                  ? (b.containsKey('value')
                        ? b['value']
                        : _bad('eq.bands', 'each band needs a "value"'))
                  : b,
              'eq.bands',
              strict ? -6 : -128,
              strict ? 6 : 127,
            ) &
            0xFF,
    ]);
  }
}

/// Which slots differ between two backups.
class PresetDiff {
  const PresetDiff(this.presets, this.eq, {this.skippedEq = const <int>[]});
  final List<int> presets;
  final List<int> eq;

  /// EQ records left as they were on the pedal, because the wanted record
  /// is not one Save EQ takes (set by [restorePresetBank]).
  final List<int> skippedEq;
  bool get isEmpty => presets.isEmpty && eq.isEmpty;

  static PresetDiff between(PresetBackup want, PresetBackup have) => PresetDiff(
    <int>[
      for (int i = 0; i < presetCount; i++)
        if (!_same(want.preset(i), have.preset(i))) i,
    ],
    <int>[
      for (int i = 0; i < presetCount; i++)
        if (!_same(want.eqRecord(i), have.eqRecord(i))) i,
    ],
  );

  @override
  String toString() {
    String names(List<int> ids) => ids.isEmpty
        ? 'none'
        : ids
              .map((int i) => 'P${(i + 1).toString().padLeft(2, '0')}')
              .join(', ');
    return 'presets: ${names(presets)}; EQ: ${names(eq)}';
  }
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

/// Reads the whole preset bank (presets + EQ table) in 128-byte reads.
Future<PresetBackup> readPresetBank(
  PresetSession session,
  String identity, {
  void Function(double fraction)? onProgress,
}) async {
  const int total = eqTableAddress + eqTableLength;
  const int chunk = 128;
  final Uint8List area = Uint8List(total);
  for (int at = 0; at < total; at += chunk) {
    final int n = at + chunk > total ? total - at : chunk;
    area.setAll(at, await session.readRaw(at, n));
    onProgress?.call((at + n) / total);
  }
  try {
    return PresetBackup(
      identity: identity,
      created: DateTime.now(),
      presets: Uint8List.sublistView(area, 0, eqTableAddress),
      eq: Uint8List.sublistView(area, eqTableAddress),
    );
  } on FormatException catch (e) {
    throw UnknownPresetLayout(e.message, area);
  }
}

/// PIXIE1 V0.07 keeps presets in the same 92-byte bodies, with no EQ table.
/// It answers reads at or past this address with filler (the request's
/// checksum, seven zeros, then an empty preset), so only P01..P79 and the
/// start of P80 can be read (seen in the raw copies of issue #10).
const int oldFirmwareReadable = 7296;
const int oldPresetCount = oldFirmwareReadable ~/ presetSize;

/// Whether [area] holds P01..P79 in the preset layout: each chain lists the
/// six blocks once and every block is on or off.
bool isOldPresetArea(Uint8List area) {
  if (area.length < oldFirmwareReadable) {
    return false;
  }
  for (int id = 0; id < oldPresetCount; id++) {
    final int at = id * presetSize;
    final List<int> chain = area.sublist(at + 2, at + 8)..sort();
    if (!_same(chain, const <int>[0, 1, 2, 3, 4, 5]) ||
        area.sublist(at + 8, at + 14).any((int b) => b > 1)) {
      return false;
    }
  }
  return true;
}

/// The pedal answered, but its flash is not laid out like a Pocket AMP's
/// (seen on a PIXIE1 running V0.07). [area] holds the raw bytes read.
class UnknownPresetLayout extends FormatException {
  UnknownPresetLayout(super.message, this.area);
  final Uint8List area;
}

/// Writes back only what differs from [backup], commits once, and checks the
/// result by reading everything again. Returns what was restored.
Future<PresetDiff> restorePresetBank(
  PresetSession session,
  PresetBackup backup, {
  void Function(String step, double fraction)? onProgress,
  PresetBackup? expected,
}) async {
  if (backup.oldLayout) {
    throw const PresetIoException(
      'Presets read from older clone firmware are only shown, never written '
      'back. Nothing was written to the pedal.',
    );
  }
  final PresetBackup before = await readPresetBank(
    session,
    backup.identity,
    onProgress: (double f) => onProgress?.call('Reading the pedal', f),
  );
  // Edits are made against what was read. If the pedal changed since (a
  // preset saved on the pedal, or another unit plugged in), writing the
  // whole difference would undo that: stop and ask for a new read.
  if (expected != null) {
    // A slot that already holds what is being written did not move: that
    // is the state an earlier write leaves when only its store was lost,
    // and writing again must complete it.
    final PresetDiff seen = PresetDiff.between(expected, before);
    final PresetDiff moved = PresetDiff(
      <int>[
        for (final int i in seen.presets)
          if (!_same(before.preset(i), backup.preset(i))) i,
      ],
      <int>[
        for (final int i in seen.eq)
          if (!_same(before.eqRecord(i), backup.eqRecord(i))) i,
      ],
    );
    if (!moved.isEmpty) {
      throw PresetIoException(
        'The pedal changed since its presets were read ($moved). Nothing was '
        'written; read them again.',
      );
    }
  }
  final PresetDiff all = PresetDiff.between(backup, before);
  // EQ records Save EQ does not take stay as they are on the pedal, so the
  // rest of a backup still restores; the caller says which.
  final List<int> skippedEq = <int>[
    for (final int id in all.eq)
      if (!_eqWritable(id, backup.eqRecord(id))) id,
  ];
  final PresetDiff diff = PresetDiff(all.presets, <int>[
    for (final int id in all.eq)
      if (!skippedEq.contains(id)) id,
  ], skippedEq: skippedEq);
  // What this write changes must be something the firmware itself makes;
  // values the pedal already holds are written back as they are.
  final String? odd = _strangeChange(backup, before, diff);
  if (odd != null) {
    throw PresetIoException(
      'Cannot restore: $odd. Nothing was written to the pedal.',
    );
  }
  // Every packet is built before the first write, so a record this app
  // cannot write stops the restore with the pedal untouched.
  final List<(Uint8List, String)> writes;
  try {
    writes = <(Uint8List, String)>[
      for (final int id in diff.presets)
        (savePresetPacket(id, backup.preset(id)), 'saving P${id + 1}'),
      for (final int id in diff.eq)
        (saveEqPacket(id, backup.eqRecord(id)), 'saving the EQ of P${id + 1}'),
    ];
    for (final (Uint8List packet, _) in writes) {
      checkOutgoing(packet);
    }
  } on ArgumentError catch (e) {
    throw PresetIoException(
      'Cannot restore: ${e.message}. Nothing was written to the pedal.',
    );
  } on BlockedPacket catch (e) {
    throw PresetIoException(
      'Cannot restore: ${e.reason}. Nothing was written to the pedal.',
    );
  }
  const String notStored =
      'Nothing was stored yet: turning the pedal off brings back its old '
      'presets. Restore again to store them.';
  int done = 0;
  try {
    for (final (Uint8List packet, String what) in writes) {
      await session.write(packet, what);
      onProgress?.call('Writing presets', ++done / writes.length);
    }
  } on PresetIoException catch (e) {
    // Even the first save may have been taken without its answer arriving.
    throw PresetIoException('${e.message} $notStored');
  }
  if (writes.isNotEmpty) {
    // Saves go to a RAM mirror of the bank, which is also what reads
    // return. Check it before storing: this also makes sure every save was
    // taken, whatever a late acknowledgement said.
    final PresetBackup after = await readPresetBank(
      session,
      backup.identity,
      onProgress: (double f) => onProgress?.call('Checking', f),
    );
    final PresetDiff seen = PresetDiff.between(backup, after);
    final PresetDiff left = PresetDiff(seen.presets, <int>[
      for (final int id in seen.eq)
        if (!skippedEq.contains(id)) id,
    ]);
    if (!left.isEmpty) {
      throw PresetIoException('Restore did not take for $left. $notStored');
    }
  }
  // Store even when nothing differed: an earlier restore whose store was
  // lost leaves the mirror right and the flash old. Sent once: sending it
  // again while the pedal is still writing its flash is worse than an error.
  try {
    await session.write(commitPacket(), 'storing the presets', once: true);
  } on PresetIoException {
    throw const PresetIoException(
      'The pedal did not confirm storing the presets. Restore again before '
      'turning it off.',
    );
  }
  return diff;
}

bool _eqWritable(int id, List<int> record) {
  try {
    saveEqPacket(id, record);
    return true;
  } on ArgumentError {
    return false;
  }
}

/// Why [want] cannot be written over [have] for the slots in [diff], or
/// null. Only fields that change are checked: a model byte past the list or
/// a chain that is not an order is refused when this write would put it
/// there, and kept when the pedal already holds it.
String? _strangeChange(PresetBackup want, PresetBackup have, PresetDiff diff) {
  for (final int id in diff.presets) {
    // Any order of the six blocks: the firmware stores some that a live
    // Change Routing would not take (a factory preset does), and a backup
    // must bring them back. Edits made in the app keep FX and AMP first.
    final List<int> chain = want.chain(id);
    if (!_same(chain, have.chain(id)) &&
        (chain.toSet().length != 6 || chain.any((int b) => b > 5))) {
      return 'the chain of ${_slot(id)} must list each block once';
    }
    for (int b = 0; b < blockNames.length; b++) {
      final int model = want.model(id, b);
      if (model != have.model(id, b) &&
          model >= blockModels[blockNames[b]]!.length) {
        return '${_slot(id)} ${blockNames[b]} would get model ${model + 1}, '
            'which the pedal does not have';
      }
    }
  }
  return null;
}
