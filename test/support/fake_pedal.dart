import 'dart:async';
import 'dart:typed_data';

import 'package:pocket_amp_tools/src/firmware_package.dart';
import 'package:pocket_amp_tools/src/midi/midi_backend.dart';
import 'package:pocket_amp_tools/src/ota_protocol.dart';
import 'package:pocket_amp_tools/src/presets/block_models.dart';
import 'package:pocket_amp_tools/src/presets/mefcs.dart';

/// Builds a valid `.fwsc` with a flash image and a loader whose bytes are
/// [loader]. [product] is interleaved the way M-VAVE packages carry it.
Uint8List buildFwsc({
  String product = 'Pocket AMP_105',
  int nameSlots = 20,
  required Uint8List loader,
  int flashSize = 16384,
}) {
  const int count = 2;
  final int dataStart = 64 + count * 80;
  final Uint8List flash = Uint8List(flashSize);
  for (int i = 0; i < flash.length; i++) {
    flash[i] = (i * 7 + 3) & 0xFF;
  }
  final int loaderOffset = dataStart + flash.length;
  final int total = loaderOffset + loader.length;
  final Uint8List image = Uint8List(total);
  image.setAll(dataStart, flash);
  image.setAll(loaderOffset, loader);

  Uint8List entry(int type, String name, int offset, Uint8List data) {
    final ByteData e = ByteData(80);
    e.setUint16(0, type, Endian.little);
    e.setUint16(4, crc16(data), Endian.little);
    e.setUint32(8, offset, Endian.little);
    e.setUint32(12, data.length, Endian.little);
    e.setUint32(16, data.length, Endian.little);
    final Uint8List b = e.buffer.asUint8List();
    b.setAll(64, name.codeUnits);
    return ufwDecode(b); // the cipher is its own inverse
  }

  final Uint8List table = Uint8List(count * 80)
    ..setAll(0, entry(0, 'flash.bin', dataStart, flash))
    ..setAll(80, entry(100, 'ota.bin', loaderOffset, loader));
  image.setAll(64, table);

  final ByteData head = ByteData(64);
  head.setUint16(2, crc16(table), Endian.little);
  head.setUint32(4, total, Endian.little);
  head.setUint16(8, count, Endian.little);
  final Uint8List hb = head.buffer.asUint8List();
  hb.setAll(16, 'AC791N'.codeUnits);
  head.setUint16(0, crc16(hb.sublist(2)), Endian.little);
  image.setAll(0, ufwDecode(hb));

  final BytesBuilder raw = BytesBuilder();
  // M-VAVE packages have 20 name slots; a Donner one has 36.
  assert(product.length <= nameSlots, 'product name longer than its slots');
  for (int i = 0; i < nameSlots; i++) {
    raw.add(image.sublist(i * 47, i * 47 + 47));
    raw.addByte(
      i < product.length ? (product.codeUnitAt(i) + i + 1) & 0xFF : 125,
    );
  }
  raw.add(image.sublist(nameSlots * 47));
  return raw.toBytes();
}

/// A simulated pedal on a simulated MIDI bus. It reboots between phases: the
/// port disappears and comes back with a new identity, like the real one.
class FakePedal implements MidiBackend {
  FakePedal({
    required this.image,
    this.identity = 'Pocket AMP_103',
    this.newIdentity = 'Pocket AMP_105',
    this.chunk = 512,
    this.stallInFlash = false,
    this.stallInLoader = false,
    this.rebootDelay = const Duration(milliseconds: 30),
    this.bank,
    this.portName,
  });

  /// The port's name in every mode, like the "USB-MIDI" a Donner unit shows
  /// on Windows. Null: "Pocket AMP", or "USB Composite Device" in the loader.
  final String? portName;

  /// Preset area (presets + EQ table) answered to M-EFCS reads; saves and
  /// commits change it. Null: the pedal ignores preset traffic.
  final Uint8List? bank;

  /// The active preset and its live RAM, changed by live edits.
  int active = 0;
  late Uint8List live = bank == null
      ? Uint8List(presetSize)
      : Uint8List.fromList(bank!.sublist(0, presetSize));

  /// Names in flash, as stored (index prefix included).
  List<String> ampNames = <String>[
    for (final (String n, _) in blockModels['AMP']!) n,
  ];
  List<String> cabNames = <String>[
    for (final (String n, _) in blockModels['CAB']!) n,
  ];

  /// The IR buffer, and what was copied to each CAB slot.
  final Uint8List irBuffer = Uint8List(6164);
  final Map<int, Uint8List> irSlots = <int, Uint8List>{};
  final Uint8List ampBuffer = Uint8List(7836);
  final Map<int, Uint8List> ampSlots = <int, Uint8List>{};

  /// Which buffer the chunks go to, picked by the magic of chunk 0, as the
  /// firmware does ("CAB\0" for the IR one).
  bool chunksToAmp = false;

  /// Live writes received, as short labels.
  final List<String> liveWrites = <String>[];

  /// Opens of the pedal's port so far, and how many are open now and at
  /// most at once (the app must never hold two).
  int opens = 0;
  int openNow = 0;
  int maxOpen = 0;

  /// While set, every send waits for it (a slow pedal).
  Completer<void>? holdSend;

  /// The open number [holdAt] waits for [hold] before it completes.
  int? holdAt;
  Completer<void>? hold;

  final Uint8List image;
  String identity;
  final String newIdentity;
  final int chunk;
  final bool stallInFlash;

  /// Reads the first blocks and goes quiet, like a Pocket AMP offered the
  /// version it already runs.
  final bool stallInLoader;
  final Duration rebootDelay;

  /// Other devices on the bus, which never answer.
  final List<MidiPortRef> bystanders = <MidiPortRef>[
    const MidiPortRef(id: 'synth', name: 'Some Synth'),
  ];

  bool present = true;
  final List<String> sentToBystanders = <String>[];
  Uint8List? loaderReceived;
  Uint8List? flashReceived;
  int arms = 0;
  _FakeConnection? _open;

  MidiPortRef get port => MidiPortRef(
    id: 'pedal',
    name:
        portName ??
        (identity.startsWith('ota-') ? 'USB Composite Device' : 'Pocket AMP'),
  );

  @override
  Future<List<MidiPortRef>> listPorts() async => <MidiPortRef>[
    ...bystanders,
    if (present) port,
  ];

  @override
  Future<MidiConnection> open(MidiPortRef p) async {
    if (p.id != 'pedal') {
      return _SilentConnection(this, p.id);
    }
    if (!present) {
      throw const MidiPortGone();
    }
    if (++opens == holdAt) {
      await hold!.future;
    }
    openNow++;
    if (openNow > maxOpen) {
      maxOpen = openNow;
    }
    return _open = _FakeConnection(this);
  }

  void _reboot(String next) {
    present = false;
    _open?._gone();
    Timer(rebootDelay, () {
      identity = next;
      present = true;
    });
  }

  Future<void> _transfer(_FakeConnection c) async {
    final bool loaderPhase = !identity.startsWith('ota-');
    final Uint8List got = Uint8List(image.length);
    int seq = 0;
    for (int at = 0; at < image.length; at += chunk) {
      if (stallInLoader && loaderPhase && at >= 3 * chunk) {
        return;
      }
      if (stallInFlash && !loaderPhase && at >= image.length ~/ 2) {
        return; // stop asking: the host must time out
      }
      final int size = at + chunk > image.length ? image.length - at : chunk;
      final Uint8List reply = await c.ask(seq++, at, size);
      got.setAll(at, reply.sublist(8));
    }
    final int finish = loaderPhase ? finishLoader : finishFlash;
    final Uint8List done = await c.ask(seq, finish, 8);
    if (String.fromCharCodes(done.sublist(8)) != 'success\u0000') {
      throw StateError('no success');
    }
    if (loaderPhase) {
      loaderReceived = got;
      _reboot('ota-$identity');
    } else {
      flashReceived = got;
      _reboot(newIdentity);
    }
  }
}

class _SilentConnection implements MidiConnection {
  _SilentConnection(this.bus, this.id);
  final FakePedal bus;
  final String id;
  final StreamController<Uint8List> _c = StreamController<Uint8List>();
  @override
  Stream<Uint8List> get messages => _c.stream;
  @override
  Future<void> send(Uint8List sysex) async => bus.sentToBystanders.add(id);
  @override
  Future<void> close() => _c.close();
}

class _FakeConnection implements MidiConnection {
  _FakeConnection(this.pedal);
  final FakePedal pedal;
  final StreamController<Uint8List> _out = StreamController<Uint8List>();
  Completer<Uint8List>? _pending;
  bool _closed = false;

  @override
  Stream<Uint8List> get messages => _out.stream;

  void _gone() {
    if (!_closed) {
      _closed = true;
      pedal.openNow--;
      _out.addError(const MidiPortGone());
      _out.close();
    }
  }

  Future<Uint8List> ask(int seq, int address, int size) {
    final ByteData r = ByteData(8)
      ..setUint8(0, seq & 0xFF)
      ..setUint32(1, address, Endian.little);
    r.setUint8(5, size & 0xFF);
    r.setUint8(6, (size >> 8) & 0xFF);
    r.setUint8(7, (size >> 16) & 0xFF);
    _pending = Completer<Uint8List>();
    _out.add(buildFrame(cmdData, r.buffer.asUint8List()));
    return _pending!.future;
  }

  @override
  Future<void> send(Uint8List sysex) async {
    if (_closed) {
      throw const MidiPortGone();
    }
    final Completer<void>? h = pedal.holdSend;
    if (h != null) {
      await h.future;
    }
    final Uint8List? bank = pedal.bank;
    final Uint8List? p = bank == null ? null : mefcsUnwrap(sysex);
    // Only flash reads, saves and commits are modelled; other M-EFCS
    // packets (the detection query, for one) fall through.
    if (p != null && p.length >= 15 && (p[2] == 0x22 || p[2] == 0x23)) {
      scheduleMicrotask(() => _out.add(mefcsWrap(bankReply(pedal, p))));
      return;
    }
    if (_listEq(sysex, armMessage)) {
      pedal.arms++;
      scheduleMicrotask(() => pedal._transfer(this));
      return;
    }
    final OtaMessage? m = parseFrame(sysex);
    if (m == null) {
      return;
    }
    if (m.command == cmdIdentity) {
      final Uint8List id = Uint8List(27)..setAll(0, pedal.identity.codeUnits);
      scheduleMicrotask(() => _out.add(buildFrame(cmdIdentity, id)));
    } else if (m.command == cmdData) {
      final Completer<Uint8List>? p = _pending;
      _pending = null;
      p?.complete(m.payload);
    }
  }

  @override
  Future<void> close() async {
    if (!_closed) {
      _closed = true;
      pedal.openNow--;
      await _out.close();
    }
  }
}

bool _listEq(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

/// What a Pocket AMP answers to an M-EFCS [packet]: preset area, live RAM
/// and name reads; saves, commits and live edits get an ack. Saves go
/// straight to the bank; the RAM mirror of the bank is not modelled.
List<int> bankReply(FakePedal pedal, Uint8List packet) {
  final Uint8List bank = pedal.bank!;
  final int addr = packet[7] | (packet[8] << 8) | (packet[9] << 16);
  final int len = packet[11] | (packet[12] << 8) | (packet[13] << 16);
  List<int> answer(List<int> body) {
    final List<int> r = <int>[
      0x00, 0x59, 0x23, (body.length + 8) & 0xFF, (body.length + 8) >> 8, 0, //
      packet[6], ...packet.sublist(7, 14), ...body, 0,
    ];
    r[r.length - 1] = mefcsChecksum(r);
    return r;
  }

  const List<int> ack = <int>[0, 0x59, 0, 1, 0, 0, 0, 0xFF];
  if (packet[2] == 0x23) {
    if (packet[6] == 0x05) {
      final List<int> names = <int>[
        for (final String n
            in packet[10] == 0x90 ? pedal.ampNames : pedal.cabNames)
          ...List<int>.generate(
            14,
            (int i) => i < n.length ? n.codeUnitAt(i) : 0,
          ),
      ];
      names[0] = packet.last; // the pedal stamps the request's checksum here
      return answer(names);
    }
    return answer(
      packet[10] == 0x10 ? pedal.live : bank.sublist(addr, addr + len),
    );
  }
  if (packet[6] == 0x05) {
    if (packet.length == 16 && packet[10] == 0xF0) {
      final int slot = packet[7];
      final bool amp = packet[8] == 0;
      final Uint8List buffer = amp ? pedal.ampBuffer : pedal.irBuffer;
      (amp ? pedal.ampSlots : pedal.irSlots)[slot] = Uint8List.fromList(buffer);
      final List<int> name = buffer.sublist(4, 18);
      (amp ? pedal.ampNames : pedal.cabNames)[slot] = String.fromCharCodes(
        name.takeWhile((int c) => c != 0),
      );
    } else if (packet.length != 16) {
      final int at = packet[7] | (packet[8] << 8);
      final int n = packet[11] | (packet[12] << 8);
      if (at == 0) {
        pedal.chunksToAmp = packet[14] != 0x43; // not "CAB\0"
      }
      (pedal.chunksToAmp ? pedal.ampBuffer : pedal.irBuffer).setAll(
        at,
        packet.sublist(14, 14 + n),
      );
    }
    pedal.liveWrites.add('ir ${packet.length}');
    return ack;
  }
  final int sub = packet[10];
  if (sub == 0xF0) {
    return ack; // commit
  }
  if (sub == 0xE0) {
    pedal.active = packet[7];
    pedal.live = Uint8List.fromList(
      bank.sublist(packet[7] * presetSize, (packet[7] + 1) * presetSize),
    );
    pedal.liveWrites.add('load ${packet[7]}');
    return ack;
  }
  if (sub == 0x10) {
    final int at = packet[7];
    final List<int> value = packet.sublist(14, packet.length - 1);
    pedal.live.setAll(at, value);
    if (at >= 14 && at <= 19) {
      // A new model resets that block's knobs to its defaults.
      final int block = at - 14;
      for (int k = 0; k < 6; k++) {
        pedal.live[20 + block * 12 + k * 2] = 50;
        pedal.live[21 + block * 12 + k * 2] = 0;
      }
    }
    pedal.liveWrites.add('$at=${value.join(',')}');
    return ack;
  }
  bank.setAll(addr, packet.sublist(14, 14 + len));
  return ack;
}

/// A preset area that looks like a used pedal: varied models, knobs in
/// 0..100, chains in the usual order and some EQ.
Uint8List demoBank() {
  final Uint8List a = Uint8List(eqTableAddress + eqTableLength)
    ..setAll(eqTableAddress, eqHeader);
  const List<int> models = <int>[10, 7, 7, 5, 6, 20];
  for (int id = 0; id < presetCount; id++) {
    final int p = id * presetSize;
    a[p] = 60 + (id * 7) % 30;
    a.setAll(
      p + 2,
      id % 9 == 4 ? <int>[1, 0, 2, 3, 4, 5] : <int>[0, 1, 2, 3, 4, 5],
    );
    for (int b = 0; b < 6; b++) {
      a[p + 8 + b] = (b == 1 || b == 5 || (id + b) % 3 == 0) ? 1 : 0;
      a[p + 14 + b] = (id * (b + 3) + b) % models[b];
      for (int k = 0; k < 6; k++) {
        a[p + 20 + b * 12 + k * 2] = (id * 13 + b * 29 + k * 17) % 101;
      }
    }
    final int e = eqTableAddress + eqHeaderLength + id * eqRecordLength;
    a.setAll(e, <int>[
      id % 4 == 0 ? 1 : 0,
      id % 8 == 0 ? 1 : 0,
      for (int band = 0; band < 5; band++) (((id + band * 3) % 13) - 6) & 0xFF,
    ]);
  }
  return a;
}
