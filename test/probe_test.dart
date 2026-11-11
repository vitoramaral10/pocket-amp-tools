import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_tools/src/firmware_package.dart';
import 'package:pocket_amp_tools/src/midi/midi_backend.dart';
import 'package:pocket_amp_tools/src/pedal_updater.dart';

import 'support/fake_pedal.dart';

const UpdateTimings _fast = UpdateTimings(
  identityTimeout: Duration(milliseconds: 100),
  rescanEvery: Duration(milliseconds: 20),
);

void main() {
  group('probing a port that fails', () {
    final FirmwarePackage pkg = FirmwarePackage.parse(
      buildFwsc(loader: Uint8List.fromList(List<int>.filled(4000, 7))),
    );

    test('an I/O error closes the port and detect() goes on', () async {
      final FakePedal pedal = FakePedal(image: pkg.image);
      final _Flaky bus = _Flaky(pedal, failures: 1000);
      final List<String> log = <String>[];
      final PedalUpdater up = PedalUpdater(
        bus,
        timings: _fast,
        trustedLoaders: <String>{pkg.loaderSha256},
        log: log.add,
      );

      expect(await up.detect(), isNull);
      expect(bus.sends, greaterThan(0));
      expect(
        pedal.openNow,
        0,
        reason: 'the failed probe must not leave the port open',
      );
      expect(log, contains(contains('I/O error')));
    });

    test('the next detect() finds the pedal once the error is gone', () async {
      final FakePedal pedal = FakePedal(image: pkg.image);
      final PedalUpdater up = PedalUpdater(
        _Flaky(pedal, failures: 1),
        timings: _fast,
        trustedLoaders: <String>{pkg.loaderSha256},
      );

      expect(await up.detect(), isNull);
      expect(pedal.openNow, 0);
      final DetectedPedal? found = await up.detect();
      expect(found?.identity, 'Pocket AMP_103');
      expect(pedal.openNow, 0);
      expect(pedal.maxOpen, 1, reason: 'never two connections at once');
    });
  });
}

/// Wraps a [FakePedal] so that the first [failures] sends on the pedal's own
/// port throw a [MidiIoException].
class _Flaky implements MidiBackend {
  _Flaky(this.inner, {required this.failures});
  final FakePedal inner;
  int failures;
  int sends = 0;

  @override
  Future<List<MidiPortRef>> listPorts() => inner.listPorts();

  @override
  Future<MidiConnection> open(MidiPortRef p) async {
    final MidiConnection c = await inner.open(p);
    return p.id == 'pedal' ? _FlakyConnection(this, c) : c;
  }
}

class _FlakyConnection implements MidiConnection {
  _FlakyConnection(this.bus, this.inner);
  final _Flaky bus;
  final MidiConnection inner;

  @override
  Stream<Uint8List> get messages => inner.messages;

  @override
  Future<void> send(Uint8List sysex) {
    bus.sends++;
    if (bus.failures > 0) {
      bus.failures--;
      throw const MidiIoException('write failed');
    }
    return inner.send(sysex);
  }

  @override
  Future<void> close() => inner.close();
}
