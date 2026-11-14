// SPDX-License-Identifier: GPL-3.0-only

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_tools/src/midi/coremidi_backend.dart';

void main() {
  test('Android sends are cut at 1016 bytes and rejoin to the original', () {
    final Uint8List sysex = Uint8List.fromList(
      List<int>.generate(2100, (int i) => i & 0x7F),
    );
    final List<Uint8List> parts = androidSendSlices(sysex).toList();
    expect(parts.map((Uint8List p) => p.length), <int>[1016, 1016, 68]);
    expect(<int>[for (final Uint8List p in parts) ...p], sysex);
    expect(androidSendSlices(Uint8List(10)).single.length, 10);
  });
}
