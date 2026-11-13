// SPDX-License-Identifier: GPL-3.0-only
//
// Writing the preset area as raw flash (route 05, type 7), for Bluetooth.
//
// A Save Preset on route 04 makes the pedal copy the whole area through an
// 8 KB buffer, and with Bluetooth connected the firmware refuses it (NAK)
// for want of memory. Route 05 erases and writes flash with no buffer, so
// the app does the copy itself: read the 4 KB sector, change the records,
// erase it and write it back. From the reconstructed V1.05 firmware:
// the preset area of Speaker Mode bank b is at 0x3C000 + b * 0x2000 from the
// user area at 0xBF000, the first erase or write mutes the sound until about
// half a second after the last one, and a frame carries at most 1024 bytes.
//
// Between an erase and the end of its write the sector reads as FF: a
// dropped link there leaves those presets blank until the next restore.

import 'dart:typed_data';

import 'mefcs.dart';
import 'preset_backup.dart';
import 'preset_session.dart';

const int rawAreaBase = 0x3C000;
const int rawAreaEnd = 0x40000;
const int rawBankSize = 0x2000;
const int rawSectorSize = 0x1000;
const int rawFrameMax = 1024;
const int _type7 = 0x70000000;

List<int> _u32(int v) => <int>[
  v & 0xFF,
  (v >> 8) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 24) & 0xFF,
];

Uint8List _seal(List<int> p) {
  p[p.length - 1] = mefcsChecksum(p);
  return Uint8List.fromList(p);
}

/// Reads [length] bytes of raw flash at user-area offset [offset].
Uint8List rawReadPacket(int offset, int length) => _seal(<int>[
  0x00, 0x59, 0x23, 0x08, 0x00, 0x00, 0x05, //
  ..._u32(_type7 | offset),
  length & 0xFF, (length >> 8) & 0xFF, 0x00,
  0x00,
]);

/// Erases the 4 KB sector at [offset].
Uint8List rawErasePacket(int offset) => _seal(<int>[
  0x00, 0x59, 0x21, 0x05, 0x00, 0x00, 0x05, //
  ..._u32(_type7 | offset),
  0x00,
]);

/// Writes [bytes] (at most [rawFrameMax]) to erased flash at [offset].
Uint8List rawWritePacket(int offset, List<int> bytes) {
  final int n = 8 + bytes.length;
  return _seal(<int>[
    0x00, 0x59, 0x22, n & 0xFF, n >> 8, 0x00, 0x05, //
    ..._u32(_type7 | offset),
    bytes.length & 0xFF, bytes.length >> 8, 0x00,
    ...bytes,
    0x00,
  ]);
}

/// The preset area as it lies in flash: presets, then the EQ table.
Uint8List areaOf(PresetBackup b) =>
    Uint8List.fromList(<int>[...b.presets, ...b.eq]);

Future<Uint8List> _readRange(PresetSession s, int offset, int length) async {
  final BytesBuilder out = BytesBuilder(copy: false);
  for (int at = 0; at < length; at += rawFrameMax) {
    final int n = length - at < rawFrameMax ? length - at : rawFrameMax;
    out.add(await s.readFlashRaw(offset + at, n));
  }
  return out.takeBytes();
}

/// Whether [bank] (raw, from the start of a bank) holds [area]: presets and
/// EQ records, the EQ header left out.
bool _holds(Uint8List bank, Uint8List area) {
  for (int i = 0; i < area.length; i++) {
    final bool header =
        i >= eqTableAddress && i < eqTableAddress + eqHeaderLength;
    if (!header && bank[i] != area[i]) {
      return false;
    }
  }
  return true;
}

/// Writes the records of [want] listed in [diff] over [have], which is what
/// the pedal holds now. Finds which bank that is by reading both; when both
/// hold it, both are written so they stay alike.
Future<void> writeAreaRaw(
  PresetSession s,
  PresetBackup have,
  PresetBackup want,
  PresetDiff diff, {
  void Function(String step, double fraction)? onProgress,
}) async {
  final Uint8List now = areaOf(have);
  final Uint8List next = Uint8List.fromList(now);
  for (final int id in diff.presets) {
    next.setAll(id * presetSize, want.preset(id));
  }
  for (final int id in diff.eq) {
    next.setAll(
      eqTableAddress + eqHeaderLength + eqRecordLength * id,
      want.eqRecord(id),
    );
  }
  final List<Uint8List> banks = <Uint8List>[];
  for (int b = 0; b < 2; b++) {
    onProgress?.call('Reading the flash', b / 2);
    banks.add(await _readRange(s, rawAreaBase + b * rawBankSize, rawBankSize));
  }
  final List<int> targets = <int>[
    for (int b = 0; b < 2; b++)
      if (_holds(banks[b], now)) b,
  ];
  if (targets.isEmpty) {
    throw const PresetIoException(
      'Could not find the presets in the pedal flash. Nothing was written.',
    );
  }
  final List<(int, Uint8List)> sectors = <(int, Uint8List)>[];
  for (final int b in targets) {
    final Uint8List image = Uint8List.fromList(banks[b])..setAll(0, next);
    for (int at = 0; at < rawBankSize; at += rawSectorSize) {
      final Uint8List sector = Uint8List.sublistView(
        image,
        at,
        at + rawSectorSize,
      );
      final Uint8List old = Uint8List.sublistView(
        banks[b],
        at,
        at + rawSectorSize,
      );
      if (!_same(sector, old)) {
        sectors.add((rawAreaBase + b * rawBankSize + at, sector));
      }
    }
  }
  int done = 0;
  for (final (int offset, Uint8List sector) in sectors) {
    try {
      await s.write(rawErasePacket(offset), 'erasing flash');
      for (int at = 0; at < rawSectorSize; at += rawFrameMax) {
        await s.write(
          rawWritePacket(offset + at, sector.sublist(at, at + rawFrameMax)),
          'writing flash',
        );
      }
      if (!_same(await _readRange(s, offset, rawSectorSize), sector)) {
        throw const PresetIoException(
          'The flash did not read back as written.',
        );
      }
    } on PresetIoException catch (e) {
      throw PresetIoException(
        '${e.message} Writing stopped in the middle of a flash sector: some '
        'presets on the pedal may be blank now. Keep the pedal on and '
        'restore again.',
      );
    }
    onProgress?.call('Writing presets', ++done / sectors.length);
  }
  if (sectors.isNotEmpty) {
    // The pedal stays muted, refusing Save Preset, until shortly after the
    // last raw write.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
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
