// SPDX-License-Identifier: GPL-3.0-only
//
// The small part of the M-EFCS editor protocol needed to back up and restore
// presets and EQ: flash reads, Save Preset, Save EQ and Commit. Packet shapes
// were measured on a Pocket AMP (see the pocket-amp editor project).
//
//   packet  00 59 <22 write | 23 read> <len LE16 = total-7> 00 <route> ...
//           last byte = 0xFF - (sum of bytes 5..n-2) % 256
//   wire    F0 + 7-bit packed packet (always with a trailing group) + F7

import 'dart:typed_data';

const int presetCount = 80;
const int presetSize = 92;
const int eqHeaderLength = 18;
const int eqRecordLength = 7;
const int eqTableAddress = 7360;
const int eqTableLength = eqHeaderLength + presetCount * eqRecordLength;
const List<int> eqHeader = <int>[
  0x50, 0x41, 0x54, 0x43, 0x48, 0x45, 0x4E, 0x44, 0, // PATCHEND\0
  0x45, 0x51, 0x73, 0x74, 0x61, 0, 0, 0, 0, //          EQsta\0...
];

int mefcsChecksum(List<int> packet) {
  int total = 0;
  for (int i = 5; i < packet.length - 1; i++) {
    total += packet[i];
  }
  return 0xFF - (total % 256);
}

Uint8List _seal(List<int> bytes) {
  bytes[bytes.length - 1] = mefcsChecksum(bytes);
  return Uint8List.fromList(bytes);
}

/// Reads [length] bytes of the preset/EQ flash area at [address].
Uint8List readFlashPacket(int address, int length) => _seal(<int>[
  0x00, 0x59, 0x23, 0x08, 0x00, 0x00, 0x04, //
  address & 0xFF, (address >> 8) & 0xFF, (address >> 16) & 0xFF,
  0x00,
  length & 0xFF, (length >> 8) & 0xFF, (length >> 16) & 0xFF,
  0x00,
]);

/// Writes a preset body to the RAM mirror of the preset bank. Persisted by
/// [commitPacket].
Uint8List savePresetPacket(int presetId, List<int> body) {
  if (presetId < 0 || presetId >= presetCount || body.length != presetSize) {
    throw ArgumentError('invalid preset $presetId');
  }
  final int address = presetId * presetSize;
  return _seal(<int>[
    0x00, 0x59, 0x22, 0x64, 0x00, 0x00, 0x04, //
    address & 0xFF, (address >> 8) & 0xFF, (address >> 16) & 0xFF,
    0x00, presetSize, 0x00, 0x00,
    ...body,
    0x00,
  ]);
}

/// Bit 7 of an EQ record's position byte: a custom firmware's 7-band record,
/// whose other five bytes are packed fields with no invalid value.
const int eqSevenBandBit = 0x80;

/// Writes one 7-byte EQ record (on, position, five bands). Persisted by
/// [commitPacket]. A 7-band record is only written with [sevenBand], for a
/// pedal that already holds one: the stock firmware cannot read it.
Uint8List saveEqPacket(
  int presetId,
  List<int> record, {
  bool sevenBand = false,
}) {
  final String slot = 'P${(presetId + 1).toString().padLeft(2, '0')}';
  if (presetId < 0 ||
      presetId >= presetCount ||
      record.length != eqRecordLength ||
      record[0] > 1) {
    throw ArgumentError('the EQ of $slot is not a record this app can write');
  }
  if (record[1] & eqSevenBandBit != 0) {
    if (!sevenBand) {
      throw ArgumentError(
        'the EQ of $slot is a 7-band record, and this pedal has no 7-band EQ',
      );
    }
    if (record[1] & ~eqSevenBandBit > 6) {
      throw ArgumentError('the EQ of $slot is not a record this app can write');
    }
  } else if (record[1] > 1 ||
      record.skip(2).any((int b) {
        final int v = b >= 128 ? b - 256 : b;
        return v < -6 || v > 6;
      })) {
    throw ArgumentError('the EQ of $slot is not a record this app can write');
  }
  final int address =
      eqTableAddress + eqHeaderLength + eqRecordLength * presetId;
  return _seal(<int>[
    0x00, 0x59, 0x22, 0x0F, 0x00, 0x00, 0x04, //
    address & 0xFF, (address >> 8) & 0xFF, (address >> 16) & 0xFF,
    0x00, eqRecordLength, 0x00, 0x00,
    ...record,
    0x00,
  ]);
}

/// Flushes the preset bank (presets and EQ) from RAM to flash.
Uint8List commitPacket() => _seal(<int>[
  0x00, 0x59, 0x22, 0x08, 0x00, 0x00, 0x04, //
  0x00, 0x00, 0x00, 0xF0, 0x00, 0x00, 0x00, 0x00,
]);

/// Raw packet -> SysEx. Unlike the update protocol, M-EFCS always emits the
/// final 7-bit group, even when no bits are pending; the pedal expects it.
Uint8List mefcsWrap(List<int> packet) {
  final List<int> out = <int>[0xF0];
  int acc = 0;
  int bits = 0;
  for (final int b in packet) {
    acc |= b << bits;
    bits += 8;
    while (bits >= 7) {
      out.add(acc & 0x7F);
      acc >>= 7;
      bits -= 7;
    }
  }
  out
    ..add(acc & 0x7F)
    ..add(0xF7);
  return Uint8List.fromList(out);
}

/// SysEx -> raw packet, or null when it is not a complete M-EFCS packet with
/// a valid checksum.
Uint8List? mefcsUnwrap(List<int> sysex) {
  if (sysex.length < 3 || sysex.first != 0xF0 || sysex.last != 0xF7) {
    return null;
  }
  final List<int> raw = <int>[];
  int acc = 0;
  int bits = 0;
  for (int i = 1; i < sysex.length - 1; i++) {
    if (sysex[i] > 0x7F) {
      return null;
    }
    acc |= sysex[i] << bits;
    bits += 7;
    if (bits >= 8) {
      raw.add(acc & 0xFF);
      acc >>= 8;
      bits -= 8;
    }
  }
  if (raw.length < 7 || raw[0] != 0x00 || raw[1] != 0x59) {
    return null;
  }
  final int total = (raw[3] | (raw[4] << 8)) + 7;
  if (raw.length < total) {
    return null;
  }
  final Uint8List packet = Uint8List.fromList(raw.sublist(0, total));
  return packet.last == mefcsChecksum(packet) ? packet : null;
}

bool isAck(List<int> packet) =>
    packet.length == 8 &&
    packet[0] == 0x00 &&
    packet[1] == 0x59 &&
    packet[2] == 0x00 &&
    packet[3] == 0x01 &&
    packet[7] == 0xFF;
