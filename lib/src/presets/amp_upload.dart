// SPDX-License-Identifier: GPL-3.0-only
//
// Uploading a "NAM\0" network image to one of the 20 AMP slots. Same route
// and steps as the IR upload (ir_upload.dart); what changes is read from the
// firmware: the first chunk's magic is not "CAB\0", so the buffer is the AMP
// one, the apply value is 1 (AMP) and the slot write has kind 0 (AMP).
//
// The image carries its own name (bytes 4..17), so there is no naming step.

import 'dart:typed_data';

import 'ir_upload.dart';
import 'mefcs.dart';

const int namImageLength = 7548;

/// With the optional "BEND" tail (initial ring state).
const int namBendImageLength = 7836;
const int ampSlotCount = 20;
const List<int> namHeaderMagic = <int>[0x4E, 0x41, 0x4D, 0x00]; // "NAM\0"

/// Offset -> size of the chunks for an image of [length] bytes.
Map<int, int> ampChunkGrid(int length) => <int, int>{
  for (int at = 0; at < length; at += irChunkLength)
    at: length - at < irChunkLength ? length - at : irChunkLength,
};

/// "NAM\0", a printable name ending in NUL padded to byte 17, then the 100
/// the loader forces.
bool isNamHeader(List<int> d) {
  if (d.length < 22 || !_starts(d, namHeaderMagic) || d[18] != 100) {
    return false;
  }
  final List<int> name = d.sublist(4, 18);
  final int end = name.indexOf(0);
  return end > 0 &&
      name.sublist(0, end).every((int c) => c >= 0x20 && c < 0x7F) &&
      name.sublist(end).every((int c) => c == 0);
}

/// The name stored in a valid image.
String namImageName(List<int> image) {
  final List<int> name = image.sublist(4, 18);
  return String.fromCharCodes(name.sublist(0, name.indexOf(0)));
}

class InvalidAmpImage implements Exception {
  const InvalidAmpImage(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Checks what the firmware checks before it stores the image: size, header,
/// and no inf or NaN among the 1871 floats from byte 60 to 7544.
void checkNamImage(List<int> image) {
  if (image.length != namImageLength && image.length != namBendImageLength) {
    throw InvalidAmpImage(
      'A network image has $namImageLength or $namBendImageLength bytes, '
      'not ${image.length}.',
    );
  }
  if (!isNamHeader(image)) {
    throw const InvalidAmpImage('Not a "NAM" network image.');
  }
  if (image.length == namBendImageLength &&
      !_starts(image.sublist(7544), const <int>[0x42, 0x45, 0x4E, 0x44])) {
    throw const InvalidAmpImage('A 7836-byte image must end with "BEND".');
  }
  final ByteData f = ByteData.sublistView(Uint8List.fromList(image));
  for (int at = 60; at < 7544; at += 4) {
    if (!f.getFloat32(at, Endian.little).isFinite) {
      throw const InvalidAmpImage('The image has an inf or NaN weight.');
    }
  }
}

/// The packets that put [image] in AMP slot [slot] (0..19), in order.
List<(Uint8List, String)> ampUploadPackets(int slot, List<int> image) {
  if (slot < 0 || slot >= ampSlotCount) {
    throw ArgumentError('invalid AMP slot $slot');
  }
  checkNamImage(image);
  return <(Uint8List, String)>[
    for (final MapEntry<int, int> e in ampChunkGrid(image.length).entries)
      (
        irBufferPacket(e.key, image.sublist(e.key, e.key + e.value)),
        'sending the network',
      ),
    (ampApplyPacket(), 'applying the network'),
    (ampSaveToSlotPacket(slot), 'storing the network in slot ${slot + 1}'),
  ];
}

/// Plays the network in the buffer. Stores nothing.
Uint8List ampApplyPacket() => _sealed(<int>[
  0x00, 0x59, 0x22, 0x09, 0x00, 0x00, 0x05, //
  0x00, 0x00, 0x00, 0xA0, 0x01, 0x00, 0x00, 0x01, 0x00,
]);

/// Copies the buffer to AMP slot [slot] (0..19). Writes to flash.
Uint8List ampSaveToSlotPacket(int slot) {
  if (slot < 0 || slot >= ampSlotCount) {
    throw ArgumentError('invalid AMP slot $slot');
  }
  return _sealed(<int>[
    0x00, 0x59, 0x22, 0x09, 0x00, 0x00, 0x05, //
    slot, 0x00, 0x00, 0xF0, 0x01, 0x00, 0x00, 0x00, 0x00,
  ]);
}

bool _starts(List<int> d, List<int> prefix) {
  for (int i = 0; i < prefix.length; i++) {
    if (d[i] != prefix[i]) {
      return false;
    }
  }
  return true;
}

Uint8List _sealed(List<int> p) {
  p[p.length - 1] = mefcsChecksum(p);
  return Uint8List.fromList(p);
}
