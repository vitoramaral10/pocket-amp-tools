// SPDX-License-Identifier: GPL-3.0-only
//
// Turns an IR WAV of any common shape into the one the pedal takes: 44.1 kHz,
// mono, 24-bit, 2048 samples. A file already in that shape is kept as it is,
// byte for byte; anything else is mixed to mono, resampled with a windowed
// sinc, cut or padded to 2048 samples and written as 24-bit PCM.

import 'dart:math' as math;
import 'dart:typed_data';

import 'ir_upload.dart';

const int _pedalRate = 44100;

/// [wav] as a WAV the pedal can take (see [parseIrWav]).
Uint8List toPedalIrWav(List<int> wav) {
  try {
    parseIrWav(wav);
    return Uint8List.fromList(wav); // already right: nothing is touched
  } on InvalidIrFile {
    // Converted below.
  }
  final _Audio a = _read(wav);
  List<double> s = a.mono;
  if (a.rate != _pedalRate) {
    s = _resample(s, a.rate, _pedalRate);
  }
  final bool cut = s.length > irSampleCount;
  final Float64List out = Float64List(irSampleCount);
  for (int i = 0; i < irSampleCount && i < s.length; i++) {
    out[i] = s[i];
  }
  if (cut) {
    // A hard stop in the tail would click; fade the last 64 samples out.
    const int fade = 64;
    for (int i = 0; i < fade; i++) {
      out[irSampleCount - fade + i] *= 0.5 + 0.5 * math.cos(math.pi * i / fade);
    }
  }
  // Leave the level alone unless it would clip in 24 bits.
  double peak = 0;
  for (final double v in out) {
    peak = math.max(peak, v.abs());
  }
  if (peak == 0) {
    throw const InvalidIrFile('The WAV is silent.');
  }
  final double gain = peak > 1 ? 1 / peak : 1;
  return _write24(out, gain);
}

class _Audio {
  const _Audio(this.rate, this.mono);
  final int rate;
  final List<double> mono;
}

/// KSDATAFORMAT_SUBTYPE_PCM and _IEEE_FLOAT share all but the first byte.
const List<int> _subformatTail = <int>[
  0x00, 0x00, 0x00, 0x00, 0x10, 0x00, //
  0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71,
];

_Audio _read(List<int> b) {
  final ByteData d = ByteData.sublistView(Uint8List.fromList(b));
  if (b.length < 12 ||
      String.fromCharCodes(b.sublist(0, 4)) != 'RIFF' ||
      String.fromCharCodes(b.sublist(8, 12)) != 'WAVE') {
    throw const InvalidIrFile('Not a WAV file.');
  }
  int? format, channels, rate, bits, align;
  int? dataStart, dataSize;
  for (int pos = 12; pos + 8 <= b.length;) {
    final String id = String.fromCharCodes(b.sublist(pos, pos + 4));
    final int size = d.getUint32(pos + 4, Endian.little);
    final int start = pos + 8;
    if (id == 'data') {
      // Some writers leave the size wrong; take what the file holds.
      dataStart = start;
      dataSize = math.min(size, b.length - start);
      break;
    }
    if (start + size > b.length) {
      throw InvalidIrFile('The "$id" chunk runs past the end of the file.');
    }
    if (id == 'fmt ' && size >= 16) {
      format = d.getUint16(start, Endian.little);
      channels = d.getUint16(start + 2, Endian.little);
      rate = d.getUint32(start + 4, Endian.little);
      align = d.getUint16(start + 12, Endian.little);
      bits = d.getUint16(start + 14, Endian.little);
      if (format == 0xFFFE && size >= 40) {
        final List<int> guid = b.sublist(start + 24, start + 40);
        bool tail = true;
        for (int i = 0; i < _subformatTail.length; i++) {
          tail &= guid[2 + i] == _subformatTail[i];
        }
        format = tail && guid[1] == 0 ? guid[0] : 0xFFFE;
      }
    }
    pos = start + size + (size.isOdd ? 1 : 0);
  }
  if (format == null || dataStart == null || dataSize == null) {
    throw const InvalidIrFile('The WAV has no format or no audio.');
  }
  final int ch = channels ?? 0, r = rate ?? 0, bt = bits ?? 0;
  final int bytesPer = bt ~/ 8;
  final bool pcm = format == 1 && <int>[8, 16, 24, 32].contains(bt);
  final bool float = format == 3 && (bt == 32 || bt == 64);
  if (!pcm && !float) {
    throw InvalidIrFile(
      'The app reads integer PCM (8, 16, 24 or 32-bit) and float WAVs; this '
      'one is format $format at $bt bits.',
    );
  }
  if (ch < 1 || r < 8000 || r > 384000 || (align ?? 0) < ch * bytesPer) {
    throw const InvalidIrFile('The WAV header does not make sense.');
  }
  final int frame = align!;
  final int frames = dataSize ~/ frame;
  if (frames == 0) {
    throw const InvalidIrFile('The WAV has no audio.');
  }
  double sample(int at) => switch ((float, bt)) {
    (true, 32) => d.getFloat32(at, Endian.little),
    (true, _) => d.getFloat64(at, Endian.little),
    (false, 8) => (d.getUint8(at) - 128) / 128,
    (false, 16) => d.getInt16(at, Endian.little) / 32768,
    (false, 24) =>
      (((d.getUint8(at + 2) << 24) |
                      (d.getUint8(at + 1) << 16) |
                      (d.getUint8(at) << 8))
                  .toSigned(32) >>
              8) /
          8388608,
    _ => d.getInt32(at, Endian.little) / 2147483648,
  };
  // Only what can still reach the pedal's 2048 samples is read.
  final int need = math.min(
    frames,
    (irSampleCount * r / _pedalRate).ceil() + 64,
  );
  final List<double> mono = List<double>.filled(need, 0);
  for (int f = 0; f < need; f++) {
    double sum = 0;
    for (int c = 0; c < ch; c++) {
      final double v = sample(dataStart + f * frame + c * bytesPer);
      sum += v.isFinite ? v : 0;
    }
    mono[f] = sum / ch;
  }
  return _Audio(r, mono);
}

/// Band-limited resampling: a Hann-windowed sinc, 32 zero crossings each
/// side, with its cutoff lowered when going down so nothing aliases.
List<double> _resample(List<double> x, int from, int to) {
  const int zeros = 32;
  final double ratio = to / from;
  final double cutoff = math.min(1.0, ratio) * 0.97;
  final double reach = zeros / cutoff; // input samples on each side
  final int n = (x.length * ratio).ceil();
  final List<double> y = List<double>.filled(n, 0);
  for (int i = 0; i < n; i++) {
    final double t = i / ratio; // position in input samples
    final int lo = (t - reach).ceil(), hi = (t + reach).floor();
    double acc = 0;
    for (int k = math.max(0, lo); k <= hi && k < x.length; k++) {
      final double u = (t - k) * cutoff;
      final double sinc = u == 0 ? 1 : math.sin(math.pi * u) / (math.pi * u);
      final double w = 0.5 + 0.5 * math.cos(math.pi * (t - k) / reach);
      acc += x[k] * sinc * w;
    }
    y[i] = acc * cutoff;
  }
  return y;
}

Uint8List _write24(List<double> s, double gain) {
  const int header = 44;
  final ByteData d = ByteData(header + irPcmLength);
  void ascii(int at, String text) {
    for (int i = 0; i < text.length; i++) {
      d.setUint8(at + i, text.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  d.setUint32(4, header - 8 + irPcmLength, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  d.setUint32(16, 16, Endian.little);
  d.setUint16(20, 1, Endian.little); // integer PCM
  d.setUint16(22, 1, Endian.little); // mono
  d.setUint32(24, _pedalRate, Endian.little);
  d.setUint32(28, _pedalRate * 3, Endian.little);
  d.setUint16(32, 3, Endian.little);
  d.setUint16(34, 24, Endian.little);
  ascii(36, 'data');
  d.setUint32(40, irPcmLength, Endian.little);
  for (int i = 0; i < s.length; i++) {
    final int v = (s[i] * gain * 8388607).round().clamp(-8388608, 8388607);
    final int at = header + i * 3;
    d.setUint8(at, v & 0xFF);
    d.setUint8(at + 1, (v >> 8) & 0xFF);
    d.setUint8(at + 2, (v >> 16) & 0xFF);
  }
  return d.buffer.asUint8List();
}
