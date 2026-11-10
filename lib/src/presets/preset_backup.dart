// SPDX-License-Identifier: GPL-3.0-only

import 'dart:convert';
import 'dart:typed_data';

import 'mefcs.dart';
import 'preset_session.dart';

/// The 80 preset bodies and the EQ table, as stored in the pedal's flash.
class PresetBackup {
  PresetBackup({
    required this.identity,
    required this.created,
    required this.presets,
    required this.eq,
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

  factory PresetBackup.fromJson(String text) {
    final Object? j = jsonDecode(text);
    if (j is! Map<String, Object?> || j['format'] != format) {
      throw const FormatException('Not a Pocket AMP Upgrader preset backup.');
    }
    return PresetBackup(
      identity: j['pedal'] as String? ?? '?',
      created: DateTime.parse(j['created'] as String),
      presets: base64Decode(j['presets'] as String),
      eq: base64Decode(j['eq'] as String),
    );
  }

  static const String format = 'pocket-amp-upgrader/presets@1';

  final String identity;
  final DateTime created;
  final Uint8List presets;
  final Uint8List eq;

  Uint8List preset(int id) =>
      Uint8List.sublistView(presets, id * presetSize, (id + 1) * presetSize);

  Uint8List eqRecord(int id) {
    final int at = eqHeaderLength + id * eqRecordLength;
    return Uint8List.sublistView(eq, at, at + eqRecordLength);
  }

  /// The same data as plain fields, for reading and comparing backups.
  /// Restore never reads it back.
  List<Map<String, Object>> get readable => <Map<String, Object>>[
    for (int id = 0; id < presetCount; id++) _readable(id),
  ];

  Map<String, Object> _readable(int id) {
    final Uint8List p = preset(id);
    int le16(int at) => p[at] | (p[at + 1] << 8);
    return <String, Object>{
      'preset': 'P${(id + 1).toString().padLeft(2, '0')}',
      'volume': le16(0),
      'chain': <Object>[
        for (final int b in p.sublist(2, 8))
          b < blockNames.length ? blockNames[b] : b,
      ],
      'blocks': <String, Object>{
        for (int b = 0; b < blockNames.length; b++)
          blockNames[b]: <String, Object>{
            'on': p[8 + b] != 0,
            'model': p[14 + b],
            'knobs': <int>[
              for (int k = 0; k < 6; k++) le16(20 + b * 12 + k * 2),
            ],
          },
      },
      'eq': _readableEq(eqRecord(id)),
    };
  }

  String toJson() =>
      const JsonEncoder.withIndent('  ').convert(<String, Object>{
        'format': format,
        'pedal': identity,
        'created': created.toUtc().toIso8601String(),
        'about':
            'The app restores from "presets" and "eq". "readable" shows the '
            'same data as plain fields, for reading and comparing; editing it '
            'changes nothing. Block names follow the order on the screen and '
            'are not confirmed for every position.',
        'readable': readable,
        'presets': base64Encode(presets),
        'eq': base64Encode(eq),
      });

  String get suggestedFileName {
    String two(int v) => v.toString().padLeft(2, '0');
    final DateTime t = created;
    return 'pocket-amp-presets-${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}.json';
  }
}

/// Names for the six block positions of a preset body, taken from the order
/// on the pedal's screen. Only MOD's position was checked on a pedal; what
/// each model number and knob means is not mapped yet.
const List<String> blockNames = <String>[
  'FX',
  'AMP',
  'MOD',
  'DLY',
  'REV',
  'CAB',
];

/// An EQ record: on/off, position in the chain (0 tail, 1 head) and five
/// bands in the steps the pedal stores. A custom firmware with a 7-band EQ
/// sets bit 7 of the position byte and packs 7 gains of 5 bits (dB), a 4-bit
/// level (2 dB steps) and a model bit into the other five bytes.
Map<String, Object> _readableEq(Uint8List r) {
  final int at = r[1] & 0x7F;
  final Map<String, Object> eq = <String, Object>{
    'on': r[0] != 0,
    'position': at < 2 ? const <String>['tail', 'head'][at] : at,
  };
  if (r[1] & eqSevenBandBit == 0) {
    return eq
      ..['bands'] = <int>[for (final int b in r.sublist(2)) b.toSigned(8)];
  }
  int bits = 0;
  for (int i = 0; i < 5; i++) {
    bits |= r[2 + i] << (8 * i);
  }
  // The firmware reads the most negative value of a field as 0.
  int field(int bit, int n) {
    final int v = ((bits >> bit) & ((1 << n) - 1)).toSigned(n);
    return v == -(1 << (n - 1)) ? 0 : v;
  }

  return eq
    ..['bands_db'] = <int>[for (int i = 0; i < 7; i++) field(5 * i, 5)]
    ..['level_db'] = 2 * field(35, 4)
    ..['model'] = (bits >> 39) & 1;
}

/// Which slots differ between two backups.
class PresetDiff {
  const PresetDiff(this.presets, this.eq);
  final List<int> presets;
  final List<int> eq;
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
}) async {
  final PresetBackup before = await readPresetBank(
    session,
    backup.identity,
    onProgress: (double f) => onProgress?.call('Reading the pedal', f),
  );
  final PresetDiff diff = PresetDiff.between(backup, before);
  if (diff.isEmpty) {
    return diff;
  }
  // A pedal that holds a 7-band EQ record runs the firmware that reads them.
  final bool sevenBand = <int>[
    for (int id = 0; id < presetCount; id++) before.eqRecord(id)[1],
  ].any((int position) => position & eqSevenBandBit != 0);
  // Every packet is built before the first write, so a record this app
  // cannot write stops the restore with the pedal untouched.
  final List<(Uint8List, String)> writes;
  try {
    writes = <(Uint8List, String)>[
      for (final int id in diff.presets)
        (savePresetPacket(id, backup.preset(id)), 'saving P${id + 1}'),
      for (final int id in diff.eq)
        (
          saveEqPacket(id, backup.eqRecord(id), sevenBand: sevenBand),
          'saving the EQ of P${id + 1}',
        ),
    ];
  } on ArgumentError catch (e) {
    throw PresetIoException(
      'Cannot restore: ${e.message}. Nothing was written to the pedal.',
    );
  }
  int done = 0;
  for (final (Uint8List packet, String what) in writes) {
    await session.write(packet, what);
    onProgress?.call('Writing presets', ++done / writes.length);
  }
  await session.write(commitPacket(), 'storing the presets');
  final PresetBackup after = await readPresetBank(
    session,
    backup.identity,
    onProgress: (double f) => onProgress?.call('Checking', f),
  );
  final PresetDiff left = PresetDiff.between(backup, after);
  if (!left.isEmpty) {
    throw PresetIoException('Restore did not stick for $left.');
  }
  return diff;
}
