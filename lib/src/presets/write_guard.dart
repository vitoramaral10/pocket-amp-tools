// SPDX-License-Identifier: GPL-3.0-only
//
// The last check before an M-EFCS packet leaves for the pedal. Each packet
// builder in mefcs.dart already refuses bad input; this checks the finished
// bytes again, independently, against the exact shapes measured on a Pocket
// AMP. Anything else is refused, so a bug elsewhere cannot write somewhere
// new.

import 'block_models.dart';
import 'amp_upload.dart';
import 'ir_upload.dart';
import 'mefcs.dart';
import 'preset_backup.dart' show blockNames;

class BlockedPacket implements Exception {
  const BlockedPacket(this.reason);
  final String reason;
  @override
  String toString() => 'Blocked an unexpected packet to the pedal: $reason.';
}

/// Throws [BlockedPacket] unless [p] is one of the packets this app may send.
void checkOutgoing(List<int> p) {
  if (p.length < 15 || p[0] != 0x00 || p[1] != 0x59 || p[5] != 0x00) {
    throw const BlockedPacket('not an M-EFCS request');
  }
  if ((p[3] | (p[4] << 8)) + 7 != p.length) {
    throw const BlockedPacket('length field does not match');
  }
  if (p.last != mefcsChecksum(p)) {
    throw const BlockedPacket('bad checksum');
  }
  final String? why = switch (p[2]) {
    0x23 => _read(p),
    0x22 => _write(p),
    _ => 'unknown command',
  };
  if (why != null) {
    throw BlockedPacket(why);
  }
}

bool _is(List<int> p, int from, List<int> bytes) {
  for (int i = 0; i < bytes.length; i++) {
    if (p[from + i] != bytes[i]) {
      return false;
    }
  }
  return true;
}

int _le24(List<int> p, int at) => p[at] | (p[at + 1] << 8) | (p[at + 2] << 16);

String? _read(List<int> p) {
  if (p.length != 15 || p[3] != 0x08) {
    return 'unknown read';
  }
  if (p[6] == 0x05) {
    // Only the two name banks.
    return _is(p, 7, const <int>[0, 0, 0]) &&
            (p[10] == 0x90 || p[10] == 0x80) &&
            _is(p, 11, const <int>[0x18, 0x01, 0x00])
        ? null
        : 'unknown read on route 05';
  }
  if (p[6] != 0x04) {
    return 'unknown route';
  }
  final int address = _le24(p, 7);
  final int length = _le24(p, 11);
  if (p[10] == 0x00) {
    return length > 0 &&
            length <= 128 &&
            address + length <= eqTableAddress + eqTableLength
        ? null
        : 'read outside the preset area';
  }
  if (p[10] == 0x10) {
    return address == 0 && length == presetSize ? null : 'bad live read';
  }
  return 'unknown read selector';
}

String? _write(List<int> p) {
  if (p[6] == 0x05) {
    return _irWrite(p);
  }
  if (p[6] != 0x04) {
    return 'write outside routes 04 and 05';
  }
  final int address = _le24(p, 7);
  switch (p.length) {
    case 15: // Commit, one literal packet.
      return _is(p, 3, const <int>[8, 0, 0, 4, 0, 0, 0, 0xF0, 0, 0, 0])
          ? null
          : 'unknown 15-byte write';
    case 16: // Load Preset, Toggle Block, Change Model.
      if (p[3] != 0x09 || p[8] != 0 || p[9] != 0) {
        return 'unknown 16-byte write';
      }
      if (_is(p, 10, const <int>[0xE0, 0x01, 0x00, 0x00])) {
        return p[7] < presetCount && p[14] == 1 ? null : 'bad Load Preset';
      }
      if (!_is(p, 10, const <int>[0x10, 0x01, 0x00, 0x00])) {
        return 'unknown 16-byte write';
      }
      if (p[7] >= 8 && p[7] <= 13) {
        return p[14] <= 1 ? null : 'bad Toggle Block';
      }
      if (p[7] >= 14 && p[7] <= 19) {
        final int models = blockModels[blockNames[p[7] - 14]]!.length;
        return p[14] < models ? null : 'model ${p[14]} does not exist';
      }
      return 'Toggle/Model outside the block bytes';
    case 17: // Change Knob.
      final int value = p[14] | (p[15] << 8);
      return p[3] == 0x0A &&
              p[8] == 0 &&
              p[9] == 0 &&
              _is(p, 10, const <int>[0x10, 0x02, 0x00, 0x00]) &&
              p[7] >= 20 &&
              p[7] <= 90 &&
              p[7].isEven &&
              value <= 100
          ? null
          : 'bad Change Knob';
    case 21: // Change Routing.
      final List<int> order = p.sublist(14, 20);
      return p[3] == 0x0E &&
              _is(p, 7, const <int>[0x02, 0, 0, 0x10, 0x06, 0, 0]) &&
              pedalTakesChain(order)
          ? null
          : 'a chain the pedal does not take';
    case 22: // Save EQ.
      final int record = address - eqTableAddress - eqHeaderLength;
      return p[3] == 0x0F &&
              _is(p, 10, const <int>[0x00, eqRecordLength, 0x00, 0x00]) &&
              record >= 0 &&
              record % eqRecordLength == 0 &&
              record ~/ eqRecordLength < presetCount &&
              p[14] <= 1 &&
              p[15] <= 1 &&
              p
                  .sublist(16, 21)
                  .every((int b) => b.toSigned(8) >= -6 && b.toSigned(8) <= 6)
          ? null
          : 'bad Save EQ';
    case 107: // Save Preset.
      if (p[3] != 0x64 ||
          !_is(p, 10, const <int>[0x00, presetSize, 0x00, 0x00]) ||
          address % presetSize != 0 ||
          address ~/ presetSize >= presetCount) {
        return 'bad Save Preset';
      }
      return _presetBody(p.sublist(14, 14 + presetSize));
  }
  return 'unknown write';
}

/// Route 05: only the IR upload, in the shapes traced from the official app,
/// and the AMP network upload, which differs in the apply value and slot kind.
String? _irWrite(List<int> p) {
  if (p.length == 16 && p[3] == 0x09) {
    if (_is(p, 7, const <int>[0, 0, 0, 0xA0, 0x01, 0, 0]) &&
        (p[14] == 0x02 || p[14] == 0x01)) {
      return null; // apply the buffer (2 CAB, 1 AMP)
    }
    return p[7] < irSlotCount &&
            (p[8] == 0x01 || p[8] == 0x00) &&
            _is(p, 9, const <int>[0, 0xF0, 0x01, 0, 0, 0x00])
        ? null
        : 'unknown 16-byte write on route 05';
  }
  final int offset = p[7] | (p[8] << 8) | (p[9] << 16) | (p[10] << 24);
  final int n = p[11] | (p[12] << 8);
  if (p[13] != 0 || p.length != 14 + n + 1) {
    return 'bad IR buffer write';
  }
  final List<int> data = p.sublist(14, 14 + n);
  if (offset == 0 && isNamHeader(data)) {
    return n == irChunkLength ? null : 'network chunk off the grid';
  }
  if (offset == 0 && !_isIrHeader(data)) {
    return 'IR buffer without a valid CAB header';
  }
  if (irChunkGrid[offset] == n || (offset == 0 && n == irHeaderLength)) {
    return null;
  }
  // The other network chunks: the grid of a 7548- or 7836-byte image.
  if (ampChunkGrid(namImageLength)[offset] == n ||
      ampChunkGrid(namBendImageLength)[offset] == n) {
    return null;
  }
  return 'IR chunk off the grid';
}

/// The ranges the firmware itself keeps in a preset body: volume and knobs
/// 0..100, chain bytes below 6, on/off 0 or 1. A stored body outside them is
/// a broken preset in flash. Model bytes are left out: the model lists are not
/// confirmed, and the pedal's own presets must still be restorable.
String? _presetBody(List<int> body) {
  int le16(int at) => body[at] | (body[at + 1] << 8);
  if (le16(0) > 100) {
    return 'volume ${le16(0)} above 100';
  }
  for (int i = 2; i < 8; i++) {
    if (body[i] > 5) {
      return 'chain byte ${body[i]} is not a block';
    }
  }
  for (int i = 8; i < 14; i++) {
    if (body[i] > 1) {
      return 'block state ${body[i]} is not on or off';
    }
  }
  for (int at = 20; at < presetSize; at += 2) {
    if (le16(at) > 100) {
      return 'knob value ${le16(at)} above 100';
    }
  }
  return null;
}

/// "CAB\0", a printable name ending in NUL and padded with NULs to byte 17,
/// then 01 and the level byte: the header the official app was seen to send.
bool _isIrHeader(List<int> d) {
  if (d.length < irHeaderLength || !_is(d, 0, irHeaderMagic) || d[18] != 0x01) {
    return false;
  }
  final List<int> name = d.sublist(4, 18);
  final int end = name.indexOf(0);
  return end >= 0 &&
      name.sublist(0, end).every((int c) => c >= 0x20 && c < 0x7F) &&
      name.sublist(end).every((int c) => c == 0);
}
