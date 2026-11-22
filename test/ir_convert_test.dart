// SPDX-License-Identifier: GPL-3.0-only

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_tools/src/presets/ir_convert.dart';
import 'package:pocket_amp_tools/src/presets/ir_upload.dart';

import 'ir_upload_test.dart' show wav;

/// A WAV of [samples] (one list per channel) as [bits]-bit integers, or as
/// floats when [float]; [extensible] writes WAVE_FORMAT_EXTENSIBLE.
Uint8List make(
  List<List<double>> samples, {
  int rate = 48000,
  int bits = 24,
  bool float = false,
  bool extensible = false,
}) {
  final int ch = samples.length, n = samples.first.length, by = bits ~/ 8;
  final int fmtSize = extensible ? 40 : 16;
  final int data = n * ch * by;
  final ByteData d = ByteData(12 + 8 + fmtSize + 8 + data);
  void ascii(int at, String t) {
    for (int i = 0; i < 4; i++) {
      d.setUint8(at + i, t.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  d.setUint32(4, d.lengthInBytes - 8, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  d.setUint32(16, fmtSize, Endian.little);
  d.setUint16(20, extensible ? 0xFFFE : (float ? 3 : 1), Endian.little);
  d.setUint16(22, ch, Endian.little);
  d.setUint32(24, rate, Endian.little);
  d.setUint32(28, rate * ch * by, Endian.little);
  d.setUint16(32, ch * by, Endian.little);
  d.setUint16(34, bits, Endian.little);
  if (extensible) {
    d.setUint16(36, 22, Endian.little);
    d.setUint16(38, bits, Endian.little);
    d.setUint32(40, 0, Endian.little);
    final List<int> guid = <int>[
      float ? 3 : 1, 0, 0, 0, 0, 0, 0x10, 0, //
      0x80, 0, 0, 0xAA, 0, 0x38, 0x9B, 0x71,
    ];
    for (int i = 0; i < 16; i++) {
      d.setUint8(44 + i, guid[i]);
    }
  }
  final int dataAt = 20 + fmtSize;
  ascii(dataAt, 'data');
  d.setUint32(dataAt + 4, data, Endian.little);
  int at = dataAt + 8;
  for (int i = 0; i < n; i++) {
    for (int c = 0; c < ch; c++) {
      final double v = samples[c][i];
      if (float) {
        d.setFloat32(at, v, Endian.little);
      } else if (bits == 16) {
        d.setInt16(at, (v * 32767).round(), Endian.little);
      } else {
        final int x = (v * 8388607).round();
        d.setUint8(at, x & 0xFF);
        d.setUint8(at + 1, (x >> 8) & 0xFF);
        d.setUint8(at + 2, (x >> 16) & 0xFF);
      }
      at += by;
    }
  }
  return d.buffer.asUint8List();
}

/// The pedal samples of a converted file, as numbers from -1 to 1.
List<double> samplesOf(Uint8List converted) {
  final Uint8List pcm = parseIrWav(converted); // the pedal takes it
  return <double>[
    for (int i = 0; i < irSampleCount; i++)
      (((pcm[i * 3 + 2] << 24) | (pcm[i * 3 + 1] << 16) | (pcm[i * 3] << 8))
                  .toSigned(32) >>
              8) /
          8388607,
  ];
}

void main() {
  test('a file already in the pedal format is kept byte for byte', () {
    final Uint8List exact = wav();
    expect(toPedalIrWav(exact), exact);
  });

  test('a sine keeps its pitch and level through 48 kHz to 44.1 kHz', () {
    List<double> sine(int rate, int n) => <double>[
      for (int i = 0; i < n; i++) 0.5 * math.sin(2 * math.pi * 1000 * i / rate),
    ];
    final List<double> got = samplesOf(
      toPedalIrWav(make(<List<double>>[sine(48000, 4000)])),
    );
    final List<double> want = sine(44100, irSampleCount);
    // Away from both ends, where the filter has whole input to work on.
    for (int i = 100; i < 1900; i++) {
      expect(got[i], closeTo(want[i], 0.01), reason: 'sample $i');
    }
  });

  test('stereo is mixed to mono and a short IR is padded with silence', () {
    final List<double> left = <double>[
      1,
      0.5,
      0.25,
      for (int i = 0; i < 997; i++) 0,
    ];
    final List<double> right = <double>[
      0,
      0.5,
      0.25,
      for (int i = 0; i < 997; i++) 0,
    ];
    final List<double> got = samplesOf(
      toPedalIrWav(make(<List<double>>[left, right], rate: 44100, bits: 16)),
    );
    expect(got[0], closeTo(0.5, 0.001));
    expect(got[1], closeTo(0.5, 0.001));
    expect(got[2], closeTo(0.25, 0.001));
    expect(got.sublist(1000).every((double v) => v == 0), isTrue);
  });

  test('a long IR is cut to 2048 samples and faded, not clicked off', () {
    final List<double> noise = <double>[
      for (int i = 0; i < 20000; i++)
        0.3 * math.sin(i * 1.7) * math.cos(i * 0.31),
    ];
    final List<double> got = samplesOf(
      toPedalIrWav(make(<List<double>>[noise], rate: 96000)),
    );
    expect(got.last.abs(), lessThan(0.001));
    expect(got[1000].abs(), greaterThan(0));
  });

  test(
    'float and extensible files are read; a level over 1 is brought down',
    () {
      final List<double> loud = <double>[
        2,
        -1,
        for (int i = 0; i < 2046; i++) 0,
      ];
      for (final bool ext in <bool>[false, true]) {
        final List<double> got = samplesOf(
          toPedalIrWav(
            make(
              <List<double>>[loud],
              rate: 44100,
              bits: 32,
              float: true,
              extensible: ext,
            ),
          ),
        );
        expect(got[0], closeTo(1, 0.001));
        expect(got[1], closeTo(-0.5, 0.001));
      }
    },
  );

  test('what cannot be an IR is refused with the reason', () {
    expect(
      () => toPedalIrWav(make(<List<double>>[List<double>.filled(500, 0)])),
      throwsA(
        isA<InvalidIrFile>().having(
          (InvalidIrFile e) => e.message,
          'message',
          contains('silent'),
        ),
      ),
    );
    expect(() => toPedalIrWav(Uint8List(40)), throwsA(isA<InvalidIrFile>()));
    final Uint8List adpcm = make(<List<double>>[
      <double>[0.5, 0.5],
    ], bits: 16)..[20] = 2; // format 2: ADPCM
    expect(
      () => toPedalIrWav(adpcm),
      throwsA(
        isA<InvalidIrFile>().having(
          (InvalidIrFile e) => e.message,
          'message',
          contains('format 2'),
        ),
      ),
    );
  });
}
