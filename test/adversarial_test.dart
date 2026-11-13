// Proofs from the adversarial review: each case failed before its fix.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_tools/src/assistant/assistant.dart';
import 'package:pocket_amp_tools/src/midi/midi_backend.dart';
import 'package:pocket_amp_tools/src/presets/block_models.dart';
import 'package:pocket_amp_tools/src/presets/ir_upload.dart';
import 'package:pocket_amp_tools/src/presets/live_link.dart';
import 'package:pocket_amp_tools/src/presets/mefcs.dart';
import 'package:pocket_amp_tools/src/presets/preset_backup.dart';
import 'package:pocket_amp_tools/src/pedal_updater.dart';
import 'package:pocket_amp_tools/src/presets/preset_service.dart';
import 'package:pocket_amp_tools/src/presets/preset_session.dart';
import 'package:pocket_amp_tools/src/presets/write_guard.dart';
import 'package:pocket_amp_tools/src/ui/presets_page.dart';

import 'support/fake_pedal.dart';

PresetBackup _of(Uint8List area) => PresetBackup(
  identity: 'Pocket AMP_105',
  created: DateTime.utc(2026),
  presets: Uint8List.sublistView(area, 0, eqTableAddress),
  eq: Uint8List.sublistView(area, eqTableAddress),
);

/// Acks a store-to-slot only after 2.5 s, everything else at once.
class _SlowSlotAck implements MidiConnection {
  final StreamController<Uint8List> _out = StreamController<Uint8List>();
  int slotWrites = 0;
  @override
  Stream<Uint8List> get messages => _out.stream;
  @override
  Future<void> send(Uint8List sysex) async {
    final Uint8List p = mefcsUnwrap(sysex)!;
    final bool slot = p[6] == 0x05 && p.length == 16 && p[10] == 0xF0;
    if (slot) {
      slotWrites++;
    }
    void reply() {
      if (!_out.isClosed) {
        _out.add(mefcsWrap(const <int>[0, 0x59, 0, 1, 0, 0, 0, 0xFF]));
      }
    }

    slot
        ? Timer(const Duration(milliseconds: 2500), reply)
        : scheduleMicrotask(reply);
  }

  @override
  Future<void> close() => _out.close();
}

void main() {
  lateAck();
  test('the guard refuses a Save Preset body outside the firmware ranges', () {
    final Uint8List ok = Uint8List(presetSize)
      ..setAll(2, <int>[0, 1, 2, 3, 4, 5]);
    expect(() => checkOutgoing(savePresetPacket(0, ok)), returnsNormally);
    for (final (int at, int v) in <(int, int)>[
      (0, 101), // volume
      (1, 1), // volume high byte
      (2, 6), // chain
      (8, 2), // on/off
      (20, 101), // knob
      (91, 1), // last knob, high byte
    ]) {
      final Uint8List bad = Uint8List.fromList(ok)..[at] = v;
      expect(
        () => checkOutgoing(savePresetPacket(0, bad)),
        throwsA(isA<BlockedPacket>()),
        reason: 'body[$at] = $v',
      );
    }
  });

  test('an out-of-range suggestion is refused before it reaches the draft', () {
    final PresetBackup b = _of(demoBank());
    final Uint8List before = Uint8List.fromList(b.preset(0));
    for (final Map<String, Object?> answer in <Map<String, Object?>>[
      <String, Object?>{'volume': 65535},
      <String, Object?>{
        'chain': <String>['AMP', 'AMP', 'AMP', 'AMP', 'AMP', 'AMP'],
      },
      <String, Object?>{
        'blocks': <String, Object?>{
          'AMP': <String, Object?>{'model': 200},
        },
      },
      <String, Object?>{
        'blocks': <String, Object?>{
          'AMP': <String, Object?>{'on': 2},
        },
      },
      <String, Object?>{
        'eq': <String, Object?>{
          'on': true,
          'position': 'head',
          'bands': <int>[12, 0, 0, 0, 0],
        },
      },
    ]) {
      expect(
        () => b.setPresetFields(0, mergeSuggestion(b.presetFields(0), answer)),
        throwsA(isA<FormatException>()),
        reason: '$answer',
      );
    }
    expect(b.preset(0), before);
  });

  test('writing stops when the pedal changed an edited slot', () async {
    final FakePedal pedal = FakePedal(image: Uint8List(1024), bank: demoBank());
    final PresetBackup read = _of(demoBank());
    final PresetBackup draft = read.copy()..setOn(2, 3, !read.isOn(2, 3));
    pedal.bank![2 * presetSize] ^= 1; // P03 changed on the pedal itself
    final Uint8List onPedal = Uint8List.fromList(pedal.bank!);
    final PresetSession s = PresetSession(await pedal.open(pedal.port));
    await expectLater(
      restorePresetBank(s, draft, expected: read),
      throwsA(isA<PresetIoException>()),
    );
    await s.close();
    expect(pedal.bank, onPedal, reason: 'nothing written');
  });

  test('an edit reads and writes only its slot, leaving the others', () async {
    final FakePedal pedal = FakePedal(image: Uint8List(1024), bank: demoBank());
    final PresetBackup read = _of(demoBank());
    final PresetBackup draft = read.copy()..setOn(2, 3, !read.isOn(2, 3));
    pedal.bank![9 * presetSize] ^= 1; // P10 changed on the pedal itself
    final List<int> p10 = pedal.bank!.sublist(9 * presetSize, 10 * presetSize);
    final List<String> steps = <String>[];
    final PresetSession s = PresetSession(await pedal.open(pedal.port));
    final PresetDiff d = await restorePresetBank(
      s,
      draft,
      expected: read,
      onProgress: (String step, _) => steps.add(step),
    );
    await s.close();
    expect(d.presets, <int>[2]);
    expect(
      pedal.bank!.sublist(2 * presetSize, 3 * presetSize),
      draft.preset(2),
    );
    expect(
      pedal.bank!.sublist(9 * presetSize, 10 * presetSize),
      p10,
      reason: 'not undone',
    );
    expect(steps.where((String x) => x != 'Writing presets'), <String>[
      'Reading the pedal',
      'Checking',
    ], reason: 'one read before and one after, not the whole bank twice');
  });

  test('a slow ack to a flash write does not send it again', () async {
    final _SlowSlotAck c = _SlowSlotAck();
    final PresetSession s = PresetSession(c);
    await s.write(irSaveToSlotPacket(3), 'store', once: true);
    await s.close();
    expect(c.slotWrites, 1);
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('a model change does not land on a draft replaced meanwhile', () async {
    final FakePedal pedal = FakePedal(image: Uint8List(1024), bank: demoBank());
    final PresetWorkspace w = PresetWorkspace()
      ..load(_of(demoBank()), 'x', fromPedal: true);
    w.live = LiveLink(
      PresetSession(await pedal.open(pedal.port)),
      onError: (Object e) => fail('$e'),
    );
    final Future<void> change = w.changeModel(
      0,
      1,
      (w.draft!.model(0, 1) + 1) % 20,
    );
    w.discard();
    await change;
    await w.live!.close();
    expect(w.changed, isEmpty);
  });

  test('edits saved to a file or written are no longer unsaved', () {
    final PresetWorkspace w = PresetWorkspace()
      ..load(_of(demoBank()), 'x', fromPedal: true);
    expect(w.unsaved, isEmpty);
    w.draft!.presets[0] ^= 1;
    expect(w.unsaved, <int>{0});
    w.saved();
    expect(w.unsaved, isEmpty);
    w.draft!.presets[presetSize] ^= 1;
    w.written(w.draft!);
    expect(w.unsaved, isEmpty);
  });

  test('an error handler that throws does not stop the queue', () async {
    final FakePedal pedal = FakePedal(image: Uint8List(1024), bank: demoBank());
    final LiveLink link = LiveLink(
      PresetSession(await pedal.open(pedal.port)),
      onError: (Object e) => throw StateError('handler'),
    );
    link.chain(<int>[0, 1, 2, 3, 4, 5]);
    await link.model(0, 99); // refused: the handler throws
    await link.close().timeout(const Duration(seconds: 5));
  });

  test('a backup made with another model list is refused', () {
    final Map<String, Object?> file =
        jsonDecode(_of(demoBank()).toJson()) as Map<String, Object?>;
    expect(file['models'], modelListId);
    file['models'] = 'some-other-list';
    expect(
      () => PresetBackup.fromJson(jsonEncode(file)),
      throwsA(isA<FormatException>()),
    );
  });

  test('the API key never goes out unencrypted to another computer', () {
    AssistantSettings at(String url) =>
        AssistantSettings(baseUrl: url, model: 'm', apiKey: 'k');
    expect(at('http://api.example.com/v1').keyWouldLeakInClear, isTrue);
    expect(at('https://api.example.com/v1').keyWouldLeakInClear, isFalse);
    expect(at('http://localhost:11434/v1').keyWouldLeakInClear, isFalse);
    expect(
      const AssistantSettings(
        baseUrl: 'http://lan:1/v1',
        model: 'm',
      ).keyWouldLeakInClear,
      isFalse,
      reason: 'no key, nothing to leak',
    );
    expect(
      at('https://h.example/v1?api-version=2').endpoint.toString(),
      'https://h.example/v1/chat/completions?api-version=2',
    );
    expect(
      at('https://h.example/v1/chat/completions').endpoint.path,
      '/v1/chat/completions',
    );
  });

  test('the guard refuses an IR header the official app never sends', () {
    final List<int> header = irHeader(name: 'My Cab');
    expect(() => checkOutgoing(irBufferPacket(0, header)), returnsNormally);
    for (final List<int> bad in <List<int>>[
      List<int>.of(header)..[18] = 0x07, // not 01
      List<int>.of(header)..[4] = 0xFF, // name not printable
      List<int>.of(header)..[17] = 0x41, // name not ended by NUL
    ]) {
      expect(
        () => checkOutgoing(irBufferPacket(0, bad)),
        throwsA(isA<BlockedPacket>()),
      );
    }
  });

  test(
    'presets are not read from a port that went to another device',
    () async {
      final FakePedal pedal = FakePedal(
        image: Uint8List(1024),
        bank: demoBank(),
      );
      final DetectedPedal detected = DetectedPedal(
        const MidiPortRef(id: 'pedal', name: 'Some Synth'),
        'Pocket AMP_105',
      );
      await expectLater(
        PresetService(pedal).backup(detected),
        throwsA(isA<PresetIoException>()),
      );
      expect(pedal.opens, 0);
    },
  );
}

/// Acks the first request 2.1 s late (after the session gave up on it) and
/// drops [dropped]; acks everything else at once.
class _LateFirst implements MidiConnection {
  _LateFirst(this.dropped);
  final Set<int> dropped;
  int n = 0;
  final StreamController<Uint8List> _o = StreamController<Uint8List>();
  @override
  Stream<Uint8List> get messages => _o.stream;
  @override
  Future<void> send(Uint8List s) async {
    final int i = n++;
    if (dropped.contains(i)) {
      return;
    }
    Timer(i == 0 ? const Duration(milliseconds: 2100) : Duration.zero, () {
      if (!_o.isClosed) {
        _o.add(mefcsWrap(const <int>[0, 0x59, 0, 1, 0, 0, 0, 0xFF]));
      }
    });
  }

  @override
  Future<void> close() => _o.close();
}

void lateAck() {
  test('a late ack after a retry does not confirm the next write', () async {
    // Write A is answered only on its retry, then A's first answer comes
    // late; every attempt of write B is lost.
    final PresetSession s = PresetSession(_LateFirst(<int>{2, 3, 4}));
    await s.write(toggleBlockPacket(0, true), 'A');
    await expectLater(
      s.write(toggleBlockPacket(1, true), 'B'),
      throwsA(isA<PresetIoException>()),
    );
    await s.close();
  }, timeout: const Timeout(Duration(seconds: 30)));
}
