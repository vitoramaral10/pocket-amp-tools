// SPDX-License-Identifier: GPL-3.0-only
//
// A2 ".nam" captures (TONE3000, 2026) are a container with one WaveNet per
// size. The smallest, the Lite, is the very network the pedal runs: 3
// channels, 23 layers with the taps and dilations below, leaky ReLU 0.01 and
// a 16-tap head, 1871 weights. Its weights are copied as they are into the
// pedal's "NAM\0" image; no training. A1 captures (16 or 8 channels) do not
// fit and are refused.

import 'dart:convert';
import 'dart:typed_data';

import 'amp_upload.dart';
import 'ir_upload.dart';

const List<int> pedalTaps = <int>[
  6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 15, 15, 6, 6, 6, 6, 6, 6, 6, //
];
const List<int> pedalDilations = <int>[
  1, 3, 7, 17, 41, 101, 239, 1, 3, 7, 17, 41, 101, 239, 1, 13, //
  1, 3, 7, 17, 41, 101, 239,
];
const int _channels = 3;
const int _headTaps = 16;

/// rechannel + 23 x (conv, bias, input mixer, 1x1, 1x1 bias) + head + scale.
final int pedalWeightCount =
    _channels +
    pedalTaps.fold<int>(0, (int s, int t) => s + 9 * t + 18) +
    _channels * _headTaps +
    2;

class InvalidNamFile implements Exception {
  const InvalidNamFile(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The pedal image (7548 bytes) for the Lite model of an A2 [json] file,
/// named [name] (at most 13 printable ASCII characters).
Uint8List namFileToImage(String json, String name) {
  final Object? root;
  try {
    root = jsonDecode(json);
  } on FormatException {
    throw const InvalidNamFile('Not a .nam file (it is not JSON).');
  }
  final List<double> w = _liteWeights(root);
  final String n = sanitizeIrName(name);
  if (n.trim().isEmpty) {
    throw const InvalidNamFile('The name is empty.');
  }

  final ByteData b = ByteData(namImageLength);
  final Uint8List bytes = b.buffer.asUint8List();
  bytes.setAll(0, namHeaderMagic);
  bytes.setAll(4, n.codeUnits);
  bytes.setAll(18, const <int>[100, 100, 60, 60]); // forced 100, level, gain
  int out = 60;
  void put(double v) {
    b.setFloat32(out, v, Endian.little);
    out += 4;
  }

  // The .nam stores each tensor row-major: conv weight (out, in, tap),
  // 1x1 weight (out, in), head weight (1, channel, tap).
  int i = 0;
  List<double> take(int n) => w.sublist(i, i += n);
  take(_channels).forEach(put); // rechannel 1 -> 3: the pedal's knobs
  for (int layer = 0; layer < pedalTaps.length; layer++) {
    final int t = pedalTaps[layer];
    final List<double> conv = take(9 * t);
    final List<double> bias = take(3), mixer = take(3);
    final List<double> c = take(9), d = take(3);
    for (int tap = 0; tap < t; tap++) {
      for (int inp = 0; inp < 3; inp++) {
        for (int o = 0; o < 3; o++) {
          put(conv[(o * 3 + inp) * t + tap]); // file: [out + 3*in] per tap
        }
      }
    }
    bias.forEach(put); // a
    mixer.forEach(put); // b: the dry input mixed into every layer
    // The last layer's 1x1 feeds nothing; the pedal keeps it at zero.
    final bool last = layer == pedalTaps.length - 1;
    for (int inp = 0; inp < 3; inp++) {
      for (int o = 0; o < 3; o++) {
        put(last ? 0 : c[o * 3 + inp]);
      }
    }
    for (final double v in d) {
      put(last ? 0 : v);
    }
  }
  final List<double> head = take(_channels * _headTaps);
  for (int tap = 0; tap < _headTaps; tap++) {
    for (int ch = 0; ch < _channels; ch++) {
      put(head[ch * _headTaps + tap]);
    }
  }
  put(take(1).single); // g_a: head bias
  put(take(1).single); // g_b: head scale
  assert(out == 7544 && i == w.length);
  checkNamImage(bytes);
  return bytes;
}

List<double> _liteWeights(Object? root) {
  if (root is! Map<String, dynamic>) {
    throw const InvalidNamFile('Not a .nam file.');
  }
  if (root['architecture'] != 'SlimmableContainer') {
    throw const InvalidNamFile(
      'This file holds a single model (an A1 capture, or one A2 size '
      'saved on its own), not a whole A2 capture: only an A2 capture carries '
      'the small model the pedal runs. Download the A2 version from TONE3000.',
    );
  }
  final Object? subs = (root['config'] as Map<String, dynamic>?)?['submodels'];
  if (subs is! List || subs.isEmpty) {
    throw const InvalidNamFile('The A2 file has no models.');
  }
  final Map<String, dynamic> lite =
      (subs.cast<Map<String, dynamic>>().reduce(
            (Map<String, dynamic> a, Map<String, dynamic> b) =>
                (b['max_value'] as num) < (a['max_value'] as num) ? b : a,
          )['model']
          as Map<String, dynamic>);
  final Object? rate = lite['sample_rate'] ?? root['sample_rate'];
  final Map<String, dynamic>? cfg = lite['config'] as Map<String, dynamic>?;
  final List<dynamic>? layers = cfg?['layers'] as List<dynamic>?;
  final Map<String, dynamic>? l = layers?.length == 1
      ? layers!.single as Map<String, dynamic>
      : null;
  final List<dynamic> weights =
      lite['weights'] as List<dynamic>? ?? <dynamic>[];
  final bool fits =
      lite['architecture'] == 'WaveNet' &&
      rate == 48000 &&
      cfg?['head'] == null &&
      l != null &&
      l['channels'] == _channels &&
      l['bottleneck'] == _channels &&
      _sameInts(l['kernel_sizes'], pedalTaps) &&
      _sameInts(l['dilations'], pedalDilations) &&
      _allLeaky(l['activation']) &&
      (l['gating_mode'] == null ||
          (l['gating_mode'] as List<dynamic>).every(
            (Object? g) => g == 'none',
          )) &&
      (l['head1x1'] as Map<String, dynamic>?)?['active'] != true &&
      (l['head'] as Map<String, dynamic>?)?['kernel_size'] == _headTaps &&
      weights.length == pedalWeightCount;
  if (!fits) {
    throw const InvalidNamFile(
      "The smallest model in this file is not the pedal's network "
      '(3 channels, 23 layers).',
    );
  }
  return <double>[for (final Object? v in weights) (v! as num).toDouble()];
}

bool _sameInts(Object? a, List<int> b) =>
    a is List &&
    a.length == b.length &&
    <int>[for (int i = 0; i < b.length; i++) i].every((int i) => a[i] == b[i]);

bool _allLeaky(Object? a) {
  bool leaky(Object? x) =>
      x is Map &&
      x['type'] == 'LeakyReLU' &&
      (x['negative_slope'] as num?)?.toDouble() == 0.01;
  return a is List ? a.length == pedalTaps.length && a.every(leaky) : leaky(a);
}
