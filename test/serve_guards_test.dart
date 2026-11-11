import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_tools/src/firmware_package.dart';
import 'package:pocket_amp_tools/src/midi/midi_backend.dart';
import 'package:pocket_amp_tools/src/ota_protocol.dart';
import 'package:pocket_amp_tools/src/pedal_updater.dart';

import 'support/fake_pedal.dart';

const UpdateTimings _fast = UpdateTimings(
  identityTimeout: Duration(milliseconds: 100),
  flashIdle: Duration(milliseconds: 300),
  minPhaseTotal: Duration(seconds: 5),
  rescanEvery: Duration(milliseconds: 20),
);

/// Same as [_fast], but the whole phase may only last 900 ms (3 x idle).
const UpdateTimings _shortTotal = UpdateTimings(
  identityTimeout: Duration(milliseconds: 100),
  flashIdle: Duration(milliseconds: 300),
  minPhaseTotal: Duration(milliseconds: 100),
  rescanEvery: Duration(milliseconds: 20),
);

void main() {
  group('_serve refuses a pedal that misbehaves', () {
    final FirmwarePackage pkg = FirmwarePackage.parse(
      buildFwsc(loader: Uint8List.fromList(List<int>.filled(4000, 7))),
    );
    final Set<String> trusted = <String>{pkg.loaderSha256};

    /// Starts an update of a pedal in update mode (so only the flash phase
    /// runs), lets [script] play the pedal once it is armed, and expects the
    /// update to fail with a message matching [message].
    Future<_Scripted> failWith(
      _Script script,
      Matcher message, {
      UpdateTimings timings = _fast,
    }) async {
      final FakePedal pedal = FakePedal(
        image: pkg.image,
        identity: 'ota-Pocket AMP_103',
      );
      final _Scripted bus = _Scripted(pedal, script);
      final PedalUpdater up = PedalUpdater(
        bus,
        timings: timings,
        trustedLoaders: trusted,
      );
      final DetectedPedal found = (await up.detect())!;
      await expectLater(
        up.update(pkg, found, (_) {}),
        throwsA(
          isA<UpdateException>().having(
            (UpdateException e) => e.message,
            'message',
            message,
          ),
        ),
      );
      expect(bus.arms, 1);
      expect(pedal.openNow, 0, reason: 'the port is closed after the failure');
      return bus;
    }

    for (final int size in <int>[0, 513, 0xFFFFFF]) {
      test('a request of $size bytes is refused', () async {
        final _Scripted bus = await failWith(
          (_ScriptedConnection c) => c.emit(_request(0, size)),
          contains('invalid request size ($size)'),
        );
        expect(bus.sent, isEmpty, reason: 'no data goes out');
      });
    }

    for (final (String, int, int) end in <(String, int, int)>[
      ('the loader end during the flash phase', finishLoader, 8),
      ('the flash end with the wrong size', finishFlash, 16),
    ]) {
      test('${end.$1} is refused and not answered with success', () async {
        final _Scripted bus = await failWith(
          (_ScriptedConnection c) => c.emit(_request(end.$2, end.$3)),
          contains('unexpected end of phase'),
        );
        expect(bus.sent, isEmpty, reason: 'no "success" goes out');
      });
    }

    for (final (String, int, int) outside in <(String, int, int)>[
      ('starts at the end of the image', pkg.image.length, 8),
      ('starts inside and runs past the end', pkg.image.length - 4, 8),
      ('starts far away', 0x7FFFFFFF, 8),
    ]) {
      test('a request that ${outside.$1} is refused', () async {
        final _Scripted bus = await failWith(
          (_ScriptedConnection c) => c.emit(_request(outside.$2, outside.$3)),
          contains('outside the package'),
        );
        expect(bus.sent, isEmpty, reason: 'nothing is read past the image');
      });
    }

    test('a pedal that goes quiet is given up on (idle)', () async {
      final _Scripted bus = await failWith(
        (_ScriptedConnection c) => c.emit(_request(0, 8)),
        contains('the pedal stopped asking for data'),
      );
      expect(bus.sent, hasLength(1), reason: 'only the one request was served');
    });

    test('a pedal that never finishes is given up on (maxTotal)', () async {
      final _Scripted bus = await failWith(
        (_ScriptedConnection c) async {
          // Keeps asking, so the idle limit never trips.
          while (!c.closed) {
            c.emit(_request(0, 8));
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        },
        contains('took too long'),
        timings: _shortTotal,
      );
      expect(bus.sent, isNotEmpty);
      final OtaMessage first = parseFrame(bus.sent.first)!;
      expect(first.command, cmdData);
      expect(
        first.payload.sublist(8),
        pkg.image.sublist(0, 8),
        reason: 'the requests were valid, the pedal just never ended',
      );
    });
  });
}

/// A request the pedal sends: sequence 0, [address] and [size] as the
/// protocol packs them (u32 and u24, little endian).
Uint8List _request(int address, int size) {
  final ByteData r = ByteData(8)..setUint32(1, address, Endian.little);
  r.setUint8(5, size & 0xFF);
  r.setUint8(6, (size >> 8) & 0xFF);
  r.setUint8(7, (size >> 16) & 0xFF);
  return buildFrame(cmdData, r.buffer.asUint8List());
}

typedef _Script = FutureOr<void> Function(_ScriptedConnection c);

/// Wraps a [FakePedal] and takes over its port once armed: the identity
/// query still goes to the fake, but the data phase is played by [script]
/// instead of the fake's own transfer. What the host sends back is kept in
/// [sent].
class _Scripted implements MidiBackend {
  _Scripted(this.inner, this.script);
  final FakePedal inner;
  final _Script script;
  final List<Uint8List> sent = <Uint8List>[];
  int arms = 0;

  @override
  Future<List<MidiPortRef>> listPorts() => inner.listPorts();

  @override
  Future<MidiConnection> open(MidiPortRef p) async {
    final MidiConnection c = await inner.open(p);
    return p.id == 'pedal' ? _ScriptedConnection(this, c) : c;
  }
}

class _ScriptedConnection implements MidiConnection {
  _ScriptedConnection(this.bus, this.inner) {
    _sub = inner.messages.listen(
      _out.add,
      onError: _out.addError,
      onDone: () => _out.close(),
    );
  }
  final _Scripted bus;
  final MidiConnection inner;
  final StreamController<Uint8List> _out = StreamController<Uint8List>();
  late final StreamSubscription<Uint8List> _sub;
  bool closed = false;

  /// Puts a frame on the stream the host reads, as the pedal would.
  void emit(Uint8List frame) {
    if (!_out.isClosed) {
      _out.add(frame);
    }
  }

  @override
  Stream<Uint8List> get messages => _out.stream;

  @override
  Future<void> send(Uint8List sysex) async {
    if (closed) {
      throw const MidiPortGone();
    }
    if (listEquals(sysex, armMessage)) {
      bus.arms++;
      scheduleMicrotask(() => unawaited(Future<void>.sync(() => bus.script(this))));
    } else if (parseFrame(sysex)?.command == cmdIdentity) {
      await inner.send(sysex);
    } else {
      bus.sent.add(sysex);
    }
  }

  @override
  Future<void> close() async {
    closed = true;
    await _sub.cancel();
    await _out.close();
    await inner.close();
  }
}
