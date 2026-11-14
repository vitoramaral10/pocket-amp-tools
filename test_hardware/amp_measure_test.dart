// ignore_for_file: avoid_print
// LIVE RAM ONLY. Loads a preset, turns every block off and runs the audio
// measurement, then turns on only the AMP block with one model and measures
// again; at the end the preset is loaded again from flash. Nothing is saved.
//   CONFIRM_LIVE=yes AMP_SLOT=20 MEASURE_CMD='python mede_pw.py' \
//     MEASURE_OUT=/path.json flutter test test_hardware/amp_measure_test.dart
// MEASURE_CMD gets the case key and MEASURE_OUT appended.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_tools/src/midi/alsa_backend.dart';
import 'package:pocket_amp_tools/src/pedal_updater.dart';
import 'package:pocket_amp_tools/src/presets/live_link.dart';
import 'package:pocket_amp_tools/src/presets/preset_backup.dart';
import 'package:pocket_amp_tools/src/presets/preset_session.dart';

void main() {
  final Map<String, String> env = Platform.environment;
  test(
    'measure the AMP slot against everything off',
    () async {
      expect(env['CONFIRM_LIVE'], 'yes', reason: 'this edits live RAM');
      final int model = int.parse(env['AMP_SLOT']!) - 1;
      final List<String> cmd = env['MEASURE_CMD']!.split(' ');
      final AlsaBackend backend = AlsaBackend();
      final DetectedPedal pedal = (await PedalUpdater(backend).detect())!;
      final PresetSession s = PresetSession(await backend.open(pedal.port));
      final List<Object> errors = <Object>[];
      final LiveLink link = LiveLink(s, onError: errors.add);
      const int id = 79; // P80
      const int amp = 1; // FX, AMP, MOD, DLY, REV, CAB

      Future<void> measure(String key) async {
        await link.flush();
        expect(errors, isEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 1600));
        final ProcessResult r = await Process.run(cmd.first, <String>[
          ...cmd.skip(1),
          key,
          env['MEASURE_OUT']!,
        ]);
        print(r.stdout);
        if (r.exitCode != 0) {
          fail('measurement $key failed: ${r.stderr}');
        }
      }

      final PresetBackup bank = await readPresetBank(s, pedal.identity);
      final Uint8List stored = Uint8List.fromList(bank.preset(id));
      try {
        await link.show(id, stored);
        for (int b = 0; b < 6; b++) {
          link.toggle(b, false);
        }
        await measure('base');
        await link.model(amp, model);
        link.toggle(amp, true);
        await measure('amp:${model + 1}');
      } finally {
        await link.show(id, stored); // back to what is stored
        await link.flush();
        await link.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
