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

/// Writes one 7-byte EQ record (on, position, five bands). Persisted by
/// [commitPacket].
Uint8List saveEqPacket(int presetId, List<int> record) {
  if (presetId < 0 ||
      presetId >= presetCount ||
      record.length != eqRecordLength ||
      record[0] > 1 ||
      record[1] > 1 ||
      record.skip(2).any((int b) {
        final int v = b >= 128 ? b - 256 : b;
        return v < -6 || v > 6;
      })) {
    throw ArgumentError(
      'the EQ of P${(presetId + 1).toString().padLeft(2, '0')} is not a record '
      'this app can write',
    );
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

// --- live editing -----------------------------------------------------------
//
// Each packet below was checked byte by byte on a Pocket AMP.
// They write only the live RAM of the active preset: switching presets or
// turning the pedal off brings back what is stored. Every packet is also
// checked by write_guard.dart before it is sent.

/// Live RAM of the active preset: 92 bytes in the preset body layout.
Uint8List readLivePacket() => _seal(<int>[
  0x00, 0x59, 0x23, 0x08, 0x00, 0x00, 0x04, //
  0x00, 0x00, 0x00, 0x10, presetSize, 0x00, 0x00,
  0x00,
]);

/// Model names stored in flash, 20 records of 14 bytes: AMP (`amp` true) or
/// CAB. The answer comes back whole, first character included (read five
/// times on a V1.05 pedal).
Uint8List readNamesPacket({required bool amp}) => _seal(<int>[
  0x00, 0x59, 0x23, 0x08, 0x00, 0x00, 0x05, //
  0x00, 0x00, 0x00, amp ? 0x90 : 0x80, 0x18, 0x01, 0x00,
  0x00,
]);

/// Makes [presetId] the active preset, as the pedal's own buttons do.
Uint8List loadPresetPacket(int presetId) {
  if (presetId < 0 || presetId >= presetCount) {
    throw ArgumentError('invalid preset $presetId');
  }
  return _seal(<int>[
    0x00, 0x59, 0x22, 0x09, 0x00, 0x00, 0x04, //
    presetId, 0x00, 0x00, 0xE0, 0x01, 0x00, 0x00, 0x01,
    0x00,
  ]);
}

/// Knob [k] (0..5) of block position [block] (0..5), 0..100.
Uint8List changeKnobPacket(int block, int k, int value) {
  if (block < 0 || block > 5 || k < 0 || k > 5 || value < 0 || value > 100) {
    throw ArgumentError('invalid knob $block/$k = $value');
  }
  return _seal(<int>[
    0x00, 0x59, 0x22, 0x0A, 0x00, 0x00, 0x04, //
    20 + block * 12 + k * 2, 0x00, 0x00, 0x10, 0x02, 0x00, 0x00,
    value, 0x00,
    0x00,
  ]);
}

/// Turns block position [block] (0..5) on or off.
Uint8List toggleBlockPacket(int block, bool on) {
  if (block < 0 || block > 5) {
    throw ArgumentError('invalid block $block');
  }
  return _seal(<int>[
    0x00, 0x59, 0x22, 0x09, 0x00, 0x00, 0x04, //
    8 + block, 0x00, 0x00, 0x10, 0x01, 0x00, 0x00, on ? 1 : 0,
    0x00,
  ]);
}

/// Changes the model of block position [block]. The pedal resets that
/// block's knobs to the new model's defaults; read the live RAM after it.
Uint8List changeModelPacket(int block, int model, int modelCount) {
  if (block < 0 || block > 5 || model < 0 || model >= modelCount) {
    throw ArgumentError('invalid model $model for block $block');
  }
  return _seal(<int>[
    0x00, 0x59, 0x22, 0x09, 0x00, 0x00, 0x04, //
    14 + block, 0x00, 0x00, 0x10, 0x01, 0x00, 0x00, model,
    0x00,
  ]);
}

/// Whether the pedal takes [order] as a new chain. Measured on V1.05: a
/// Change Routing is acknowledged but ignored unless FX and AMP (positions 0
/// and 1) are the first two blocks, in either order; the rest is free. Some
/// stored presets break this (factory P26), and they still load.
bool pedalTakesChain(List<int> order) =>
    order.length == 6 &&
    order.toSet().length == 6 &&
    order.every((int b) => b >= 0 && b <= 5) &&
    <int>{order[0], order[1]}.containsAll(<int>[0, 1]);

/// Sets the signal chain: [order] lists the six block positions, each once.
Uint8List changeRoutingPacket(List<int> order) {
  if (!pedalTakesChain(order)) {
    throw ArgumentError(
      'the chain must list each block once, with FX and AMP first',
    );
  }
  return _seal(<int>[
    0x00, 0x59, 0x22, 0x0E, 0x00, 0x00, 0x04, //
    0x02, 0x00, 0x00, 0x10, 0x06, 0x00, 0x00, ...order,
    0x00,
  ]);
}
