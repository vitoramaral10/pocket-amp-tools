// ignore_for_file: avoid_print
// Sends an IR to one CAB slot of a real pedal on Linux and checks the name the
// pedal reads back. This OVERWRITES the slot, and the pedal cannot give the
// old IR back, so it only runs when both are set:
//   IR_SLOT=2 IR_WAV=/path/ir.wav flutter test test_hardware/ir_upload_test.dart
// IR_SLOT counts from 1, like the app. IR_NAME sets the name (default: the
// file name).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_tools/src/midi/alsa_backend.dart';
import 'package:pocket_amp_tools/src/pedal_updater.dart';
import 'package:pocket_amp_tools/src/presets/ir_upload.dart';
import 'package:pocket_amp_tools/src/presets/preset_service.dart';

void main() {
  final String? slot = Platform.environment['IR_SLOT'];
  final String? wav = Platform.environment['IR_WAV'];

  test('an IR sent to a slot reads back under its name', () async {
    final int s = int.parse(slot!) - 1;
    final File f = File(wav!);
    final String name = sanitizeIrName(
      Platform.environment['IR_NAME'] ??
          f.uri.pathSegments.last.replaceAll(
            RegExp(r'\.wav$', caseSensitive: false),
            '',
          ),
    );
    final AlsaBackend backend = AlsaBackend();
    final DetectedPedal pedal = (await PedalUpdater(backend).detect())!;
    print('pedal: ${pedal.identity}');
    final PresetService presets = PresetService(backend);
    final (_, List<String> before) = await presets.readNames(pedal);
    print('slot ${s + 1} before: ${before[s]}');

    final List<String> after = await presets.uploadIr(
      pedal,
      s,
      name,
      parseIrWav(f.readAsBytesSync()),
      onProgress: (double p) => print('sent ${(p * 100).round()}%'),
    );
    print('slot ${s + 1} after: ${after[s]}');
    // uploadIr already refuses a name that does not read back; the other
    // slots must be untouched.
    for (int i = 0; i < after.length; i++) {
      if (i != s) {
        expect(after[i], before[i], reason: 'slot ${i + 1} changed');
      }
    }
  }, skip: slot == null || wav == null ? 'set IR_SLOT and IR_WAV' : false);
}
