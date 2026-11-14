import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_tools/src/presets/nam_file.dart';

void main() {
  final String a2 = File('test/fixtures/a2_lite_synthetic.nam')
      .readAsStringSync();

  test('the Lite of an A2 file becomes the image the converter makes', () {
    // Reference: lite_direto.py of the firmware repo, which checks its copy
    // against the nam library's own output.
    final Uint8List want = File('test/fixtures/a2_lite_synthetic.bin')
        .readAsBytesSync();
    expect(pedalWeightCount, 1871);
    expect(namFileToImage(a2, 'Synthetic A2'), want);
  });

  test('A1 files and other shapes are refused with a reason', () {
    final Map<String, dynamic> root = jsonDecode(a2) as Map<String, dynamic>;
    expect(
      () => namFileToImage(
        jsonEncode(<String, dynamic>{'architecture': 'WaveNet'}),
        'x',
      ),
      throwsA(
        isA<InvalidNamFile>().having(
          (InvalidNamFile e) => e.message,
          'm',
          contains('A1'),
        ),
      ),
    );
    final Map<String, dynamic> lite =
        ((root['config'] as Map<String, dynamic>)['submodels'] as List<dynamic>)
                .last['model']
            as Map<String, dynamic>;
    ((lite['config'] as Map<String, dynamic>)['layers'] as List<dynamic>)
            .single['channels'] =
        4;
    expect(
      () => namFileToImage(jsonEncode(root), 'x'),
      throwsA(isA<InvalidNamFile>()),
    );
    expect(
      () => namFileToImage('not json', 'x'),
      throwsA(isA<InvalidNamFile>()),
    );
    expect(() => namFileToImage(a2, '  '), throwsA(isA<InvalidNamFile>()));
  });
}
