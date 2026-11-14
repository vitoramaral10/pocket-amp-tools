// ignore_for_file: avoid_print
// WRITES ONE AMP SLOT. Sends a "NAM\0" network image to an AMP slot of a real
// pedal and checks the name read back.
//   CONFIRM_WRITE=yes AMP_IMAGE=/path.bin AMP_SLOT=20 \
//     flutter test test_hardware/amp_upload_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_tools/src/midi/alsa_backend.dart';
import 'package:pocket_amp_tools/src/pedal_updater.dart';
import 'package:pocket_amp_tools/src/presets/amp_upload.dart';
import 'package:pocket_amp_tools/src/presets/preset_service.dart';

void main() {
  final Map<String, String> env = Platform.environment;
  test('upload a network to an AMP slot', () async {
    expect(env['CONFIRM_WRITE'], 'yes', reason: 'this writes to the pedal');
    final Uint8List image = File(env['AMP_IMAGE']!).readAsBytesSync();
    final int slot = int.parse(env['AMP_SLOT']!) - 1;
    checkNamImage(image);

    final AlsaBackend backend = AlsaBackend();
    final PresetService presets = PresetService(backend);
    final DetectedPedal pedal = (await PedalUpdater(backend).detect())!;
    final (List<String> before, _) = await presets.readNames(pedal);
    print('slot ${slot + 1} before: "${before[slot]}"');

    final List<String> after = await presets.uploadAmp(pedal, slot, image);
    print('slot ${slot + 1} after: "${after[slot]}"');
    for (int i = 0; i < after.length; i++) {
      if (i != slot) {
        expect(after[i], before[i], reason: 'slot ${i + 1} must not change');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
