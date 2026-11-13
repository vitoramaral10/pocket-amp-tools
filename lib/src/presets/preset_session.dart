// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../midi/midi_backend.dart';
import 'mefcs.dart';
import 'raw_flash.dart';
import 'write_guard.dart';

class PresetIoException implements Exception {
  const PresetIoException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Request/response over one open port, in M-EFCS packets.
class PresetSession {
  PresetSession(this._conn) {
    _sub = _conn.messages.listen(
      (Uint8List m) {
        final Uint8List? p = mefcsUnwrap(m);
        if (p != null) {
          _queue.add(p);
          _wake();
        }
      },
      onError: (Object e) {
        _gone = true;
        _wake();
      },
      onDone: () {
        _gone = true;
        _wake();
      },
    );
  }

  final MidiConnection _conn;
  late final StreamSubscription<Uint8List> _sub;
  final Queue<Uint8List> _queue = Queue<Uint8List>();
  bool _gone = false;
  Completer<void>? _waiter;

  static const Duration timeout = Duration(seconds: 2);
  static const int attempts = 3;

  void _wake() {
    final Completer<void>? w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) {
      w.complete();
    }
  }

  Future<Uint8List?> _next(Duration left) async {
    while (_queue.isEmpty) {
      if (_gone) {
        throw const PresetIoException('The pedal was disconnected.');
      }
      if (left <= Duration.zero) {
        return null;
      }
      final Stopwatch clock = Stopwatch()..start();
      final Completer<void> w = Completer<void>();
      _waiter = w;
      await w.future.timeout(left, onTimeout: () {});
      left -= clock.elapsed;
    }
    return _queue.removeFirst();
  }

  /// Sends [packet] and returns the first reply accepted by [want].
  /// The last reply that was not the one waited for, shown when a write is
  /// not confirmed.
  Uint8List? _other;

  Future<Uint8List?> _exchange(
    Uint8List packet,
    bool Function(Uint8List reply) want, {
    Duration wait = timeout,
  }) async {
    checkOutgoing(packet);
    _queue.clear();
    _other = null;
    await _conn.send(mefcsWrap(packet));
    final Stopwatch clock = Stopwatch()..start();
    while (clock.elapsed < wait) {
      final Uint8List? r = await _next(wait - clock.elapsed);
      if (r != null && want(r)) {
        return r;
      }
      if (r != null) {
        _other = r;
      }
    }
    return null;
  }

  /// Reads [length] (at most 128) bytes of the preset/EQ area. On route 04
  /// the payload comes back intact, byte 0 included (checked on hardware by
  /// reading the same bytes with and without one byte in front).
  Future<Uint8List> readRaw(int address, int length) async {
    final Uint8List request = readFlashPacket(address, length);
    for (int i = 0; i < attempts; i++) {
      final Uint8List? r = await _exchange(
        request,
        (Uint8List p) => _answers(p, request, length),
      );
      if (r != null) {
        return Uint8List.sublistView(r, 14, r.length - 1);
      }
    }
    throw PresetIoException('No answer reading $length bytes at $address.');
  }

  /// Reads [length] (at most 1024) bytes of raw flash at user-area [offset]
  /// (see raw_flash.dart).
  Future<Uint8List> readFlashRaw(int offset, int length) async {
    final Uint8List request = rawReadPacket(offset, length);
    for (int i = 0; i < attempts; i++) {
      final Uint8List? r = await _exchange(
        request,
        (Uint8List p) => _answers(p, request, length),
      );
      if (r != null) {
        return Uint8List.sublistView(r, 14, r.length - 1);
      }
    }
    throw PresetIoException('No answer reading flash at $offset.');
  }

  /// The live RAM of the active preset, 92 bytes in the preset layout.
  Future<Uint8List> readLive() async {
    for (int i = 0; i < attempts; i++) {
      final Uint8List? r = await _exchange(
        readLivePacket(),
        (Uint8List p) => _answers(p, readLivePacket(), presetSize),
      );
      if (r != null) {
        return Uint8List.sublistView(r, 14, r.length - 1);
      }
    }
    throw const PresetIoException('No answer reading the active preset.');
  }

  /// The 20 model names stored in flash for AMP ([amp]) or CAB, as stored,
  /// index prefix included. The first character of the first name is not
  /// what is stored: the pedal overwrites it with the request's checksum.
  Future<List<String>> readNames({required bool amp}) async {
    for (int i = 0; i < attempts; i++) {
      final Uint8List? r = await _exchange(
        readNamesPacket(amp: amp),
        (Uint8List p) => _answers(p, readNamesPacket(amp: amp), 20 * 14),
      );
      if (r != null) {
        return <String>[
          for (int n = 0; n < 20; n++)
            String.fromCharCodes(
              r
                  .sublist(14 + n * 14, 28 + n * 14)
                  .takeWhile((int c) => c != 0)
                  .where((int c) => c >= 32 && c <= 126),
            ),
        ];
      }
    }
    throw const PresetIoException('No answer reading the model names.');
  }

  /// Sends a write and waits for the device ACK. With [once], a write to
  /// flash whose time is not measured, it is sent a single time with a long
  /// wait: sending it again while the first may still be running is worse
  /// than reporting no answer.
  Future<void> write(Uint8List packet, String what, {bool once = false}) async {
    for (int i = 0; i < (once ? 1 : attempts); i++) {
      final Uint8List? r = await _exchange(
        packet,
        isAck,
        wait: once ? const Duration(seconds: 10) : timeout,
      );
      if (r != null) {
        if (i > 0) {
          // An answer to an earlier attempt may still come; acknowledgements
          // carry nothing to tell them apart, so let it arrive and drop it
          // before the next request could take it for its own.
          await Future<void>.delayed(timeout);
          _queue.clear();
        }
        return;
      }
    }
    final Uint8List? got = _other;
    throw PresetIoException(
      'The pedal did not confirm: $what.'
      '${got == null ? '' : ' It answered ${_hex(got.take(24))}${got.length > 24 ? '…' : ''}.'}',
    );
  }

  Future<void> close() async {
    await _sub.cancel();
    try {
      await _conn.close();
    } catch (_) {
      // The pedal may already be gone.
    }
  }
}

/// Whether [reply] answers the read [request]: same command and route, the
/// address and length echoed back, and [length] bytes of data. A late answer
/// to an earlier read of the same size is not taken for this one.
bool _answers(Uint8List reply, Uint8List request, int length) {
  if (reply.length != 14 + length + 1 || reply[2] != request[2]) {
    return false;
  }
  for (int i = 6; i < 14; i++) {
    if (reply[i] != request[i]) {
      return false;
    }
  }
  return true;
}

String _hex(Iterable<int> bytes) =>
    bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
