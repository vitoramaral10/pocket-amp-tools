import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_tools/src/pedal_updater.dart';
import 'package:pocket_amp_tools/src/presets/amp_upload.dart';
import 'package:pocket_amp_tools/src/presets/preset_service.dart';
import 'package:pocket_amp_tools/src/presets/write_guard.dart';

import 'support/fake_pedal.dart';

String hex(List<int> b) => b
    .map((int x) => x.toRadixString(16).padLeft(2, '0').toUpperCase())
    .join(' ');

/// A network image as the converter writes it: header, then small weights.
Uint8List namImage({String name = 'ENGL FB25 L', int length = 7548}) {
  final Uint8List b = Uint8List(length);
  b.setAll(0, namHeaderMagic);
  b.setAll(4, name.codeUnits);
  b.setAll(18, <int>[100, 100, 60, 60]);
  final ByteData f = ByteData.sublistView(b);
  for (int at = 60; at + 4 <= length && at < 7544; at += 4) {
    f.setFloat32(at, (at % 97) / 970, Endian.little);
  }
  if (length == namBendImageLength) {
    b.setAll(7544, 'BEND'.codeUnits);
  }
  return b;
}

void main() {
  test('apply and store differ from the IR ones only in the AMP bytes', () {
    expect(
      hex(ampApplyPacket()),
      '00 59 22 09 00 00 05 00 00 00 A0 01 00 00 01 58',
    );
    expect(
      hex(ampSaveToSlotPacket(19)),
      '00 59 22 09 00 00 05 13 00 00 F0 01 00 00 00 F6',
    );
    expect(ampChunkGrid(namImageLength).values.last, 443);
    expect(ampChunkGrid(namBendImageLength).values.last, 731);
  });

  test('an upload is the chunks, apply and store, all allowed', () {
    for (final int length in <int>[namImageLength, namBendImageLength]) {
      final List<(Uint8List, String)> packets = ampUploadPackets(
        19,
        namImage(length: length),
      );
      expect(packets, hasLength(10));
      for (final (Uint8List p, _) in packets) {
        expect(() => checkOutgoing(p), returnsNormally);
      }
      expect(packets.last.$2, 'storing the network in slot 20');
    }
  });

  test('bad images are refused before anything is sent', () {
    expect(
      () => ampUploadPackets(0, namImage(length: 7000)),
      throwsA(isA<InvalidAmpImage>()),
    );
    final Uint8List cab = namImage()..setAll(0, 'CAB\x00'.codeUnits);
    expect(() => ampUploadPackets(0, cab), throwsA(isA<InvalidAmpImage>()));
    final Uint8List nan = namImage();
    ByteData.sublistView(nan).setFloat32(100, double.nan, Endian.little);
    expect(() => ampUploadPackets(0, nan), throwsA(isA<InvalidAmpImage>()));
    expect(() => ampUploadPackets(20, namImage()), throwsArgumentError);
  });

  test('the guard refuses a network chunk 0 of the wrong size', () {
    final List<(Uint8List, String)> packets = ampUploadPackets(0, namImage());
    final Uint8List first = packets.first.$1;
    // Chunk 0 cut to 500 bytes, checksum left stale on purpose: the size
    // check must refuse it before anything else matters.
    final Uint8List short = Uint8List.fromList(<int>[
      ...first.sublist(0, 11),
      500 & 0xFF,
      500 >> 8,
      0,
      ...first.sublist(14, 514),
      0,
    ]);
    expect(() => checkOutgoing(short), throwsA(anything));
  });

  test(
    'uploading puts the image in the AMP slot and leaves CABs alone',
    () async {
      final FakePedal pedal = FakePedal(
        image: Uint8List(1024),
        bank: demoBank(),
      );
      final Uint8List bank = Uint8List.fromList(pedal.bank!);
      final List<String> cabs = List<String>.of(pedal.cabNames);
      final Uint8List image = namImage();
      final List<String> names = await PresetService(pedal)
          .uploadAmp(DetectedPedal(pedal.port, 'Pocket AMP_105'), 19, image);
      expect(names[19], 'ENGL FB25 L');
      expect(pedal.ampSlots[19]!.sublist(0, image.length), image);
      expect(pedal.irSlots, isEmpty);
      expect(pedal.cabNames, cabs);
      expect(pedal.bank, bank, reason: 'presets untouched');
    },
  );
}
