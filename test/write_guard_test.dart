import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_tools/src/presets/mefcs.dart';
import 'package:pocket_amp_tools/src/presets/write_guard.dart';

List<int> bytes(String hex) => <int>[
  for (final String b in hex.split(' ')) int.parse(b, radix: 16),
];

String hex(List<int> b) => b
    .map((int x) => x.toRadixString(16).padLeft(2, '0').toUpperCase())
    .join(' ');

void main() {
  // Packets measured on a Pocket AMP.
  test('live packets match the bytes measured on the pedal', () {
    expect(
      hex(loadPresetPacket(79)),
      '00 59 22 09 00 00 04 4F 00 00 E0 01 00 00 01 CA',
    );
    expect(
      hex(changeKnobPacket(0, 0, 67)),
      '00 59 22 0A 00 00 04 14 00 00 10 02 00 00 43 00 92',
    );
    expect(
      hex(changeKnobPacket(1, 0, 67)),
      '00 59 22 0A 00 00 04 20 00 00 10 02 00 00 43 00 86',
    );
    expect(
      hex(toggleBlockPacket(0, true)),
      '00 59 22 09 00 00 04 08 00 00 10 01 00 00 01 E1',
    );
    expect(
      hex(toggleBlockPacket(0, false)),
      '00 59 22 09 00 00 04 08 00 00 10 01 00 00 00 E2',
    );
    expect(
      hex(changeModelPacket(2, 1, 7)),
      '00 59 22 09 00 00 04 10 00 00 10 01 00 00 01 D9',
    );
    expect(
      hex(changeRoutingPacket(<int>[0, 1, 2, 3, 5, 4])),
      '00 59 22 0E 00 00 04 02 00 00 10 06 00 00 00 01 02 03 05 04 D4',
    );
    expect(hex(commitPacket()), '00 59 22 08 00 00 04 00 00 00 F0 00 00 00 0B');
    expect(
      hex(readLivePacket()).substring(0, 41),
      '00 59 23 08 00 00 04 00 00 00 10 5C 00 00',
    );
    expect(
      hex(readNamesPacket(amp: true)).substring(0, 41),
      '00 59 23 08 00 00 05 00 00 00 90 18 01 00',
    );
  });

  test('every packet the app builds passes the guard', () {
    final List<Uint8List> ok = <Uint8List>[
      readFlashPacket(0, 128),
      readFlashPacket(eqTableAddress, 128),
      readLivePacket(),
      readNamesPacket(amp: true),
      readNamesPacket(amp: false),
      loadPresetPacket(0),
      for (int b = 0; b < 6; b++) ...<Uint8List>[
        toggleBlockPacket(b, true),
        changeKnobPacket(b, 5, 100),
        changeModelPacket(b, 0, 1),
      ],
      changeRoutingPacket(<int>[1, 0, 5, 4, 3, 2]),
      savePresetPacket(79, Uint8List(presetSize)),
      saveEqPacket(79, <int>[1, 1, 6, 0xFA, 0, 0, 0]),
      commitPacket(),
    ];
    for (final Uint8List p in ok) {
      expect(() => checkOutgoing(p), returnsNormally, reason: hex(p));
    }
  });

  test('the guard refuses anything else', () {
    Uint8List sealed(List<int> p) =>
        Uint8List.fromList(p)..[p.length - 1] = mefcsChecksum(p);
    final Map<String, List<int>> bad = <String, List<int>>{
      // A Save Preset one byte off the preset grid.
      'save off grid': (savePresetPacket(0, Uint8List(presetSize)).toList()
        ..[7] = 1),
      // Reading past the EQ table.
      'read past the area': readFlashPacket(eqTableAddress + eqTableLength, 4),
      // A knob value the firmware does not use.
      'knob 101': bytes('00 59 22 0A 00 00 04 14 00 00 10 02 00 00 65 00 00'),
      // A knob write onto the volume bytes.
      'knob on volume': bytes(
        '00 59 22 0A 00 00 04 00 00 00 10 02 00 00 10 00 00',
      ),
      // FX has 10 models.
      'model 10 on FX': bytes(
        '00 59 22 09 00 00 04 0E 00 00 10 01 00 00 0A 00',
      ),
      // Acknowledged but ignored by a V1.05 pedal: AMP not in front.
      'chain the pedal ignores': bytes(
        '00 59 22 0E 00 00 04 02 00 00 10 06 00 00 05 04 03 02 01 00 00',
      ),
      'block repeated in chain': bytes(
        '00 59 22 0E 00 00 04 02 00 00 10 06 00 00 00 00 02 03 04 05 00',
      ),
      'route 05 write (names, IR)': bytes(
        '00 59 22 09 00 00 05 00 02 00 F0 01 00 00 00 00',
      ),
      'unknown read on route 05': bytes(
        '00 59 23 08 00 00 05 00 00 00 70 18 01 00 00',
      ),
    };
    for (final MapEntry<String, List<int>> e in bad.entries) {
      expect(
        () => checkOutgoing(sealed(e.value)),
        throwsA(isA<BlockedPacket>()),
        reason: e.key,
      );
    }
    final List<int> wrongSum = commitPacket().toList()..[14] ^= 1;
    expect(() => checkOutgoing(wrongSum), throwsA(isA<BlockedPacket>()));
  });
}
