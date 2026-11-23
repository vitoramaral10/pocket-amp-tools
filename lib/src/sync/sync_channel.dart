// SPDX-License-Identifier: GPL-3.0-only
//
// An encrypted link between two devices on the same network.
//
// Pairing, once per pair of devices: both make a fresh X25519 key; the one
// that connects first sends only a hash of its key and nonce (a commitment),
// so a device in the middle cannot try keys until both screens show the same
// code. Both screens show six digits made from the two keys and nonces; the
// people holding them check they match. The shared secret then becomes the
// pair's key, kept by both.
//
// Every later link mixes a fresh X25519 secret with the pair's key: only the
// two paired devices can read it, and a key stolen later does not open old
// traffic. Frames are ChaCha20-Poly1305 with a counter nonce per direction.
//
//   frame   u32 big-endian length, then that many bytes (plain or sealed)
//   sealed  [type: 0 JSON, 1 bytes] + body, encrypted with a 16-byte tag

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'sync_index.dart';

const String syncApp = 'pocket-amp-tools-sync';
const int syncVersion = 1;

class SyncException implements Exception {
  const SyncException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Reads length-prefixed frames off a socket.
class _Frames {
  _Frames(this.socket) {
    _sub = socket.listen(
      (Uint8List data) {
        _buf.add(data);
        _pump();
      },
      onError: (Object e) => _fail(SyncException('Connection failed: $e')),
      onDone: () => _fail(const SyncException('The other device hung up.')),
      cancelOnError: true,
    );
  }

  static const int maxFrame = 24 << 20;

  final Socket socket;
  late final StreamSubscription<Uint8List> _sub;
  final BytesBuilder _buf = BytesBuilder();
  final List<Completer<Uint8List>> _waiting = <Completer<Uint8List>>[];
  final List<Uint8List> _ready = <Uint8List>[];
  Object? _error;

  void _pump() {
    while (true) {
      final Uint8List b = _buf.toBytes();
      if (b.length < 4) {
        return;
      }
      final int n = ByteData.sublistView(b).getUint32(0);
      if (n > maxFrame) {
        _fail(const SyncException('The other device sent too much at once.'));
        return;
      }
      if (b.length < 4 + n) {
        return;
      }
      _buf
        ..clear()
        ..add(Uint8List.sublistView(b, 4 + n));
      final Uint8List frame = Uint8List.fromList(
        Uint8List.sublistView(b, 4, 4 + n),
      );
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete(frame);
      } else {
        _ready.add(frame);
      }
    }
  }

  void _fail(Object e) {
    _error ??= e;
    for (final Completer<Uint8List> c in _waiting) {
      c.completeError(e);
    }
    _waiting.clear();
  }

  Future<Uint8List> next(Duration timeout) {
    if (_ready.isNotEmpty) {
      return Future<Uint8List>.value(_ready.removeAt(0));
    }
    if (_error != null) {
      return Future<Uint8List>.error(_error!);
    }
    final Completer<Uint8List> c = Completer<Uint8List>();
    _waiting.add(c);
    return c.future.timeout(
      timeout,
      onTimeout: () {
        _waiting.remove(c);
        throw const SyncException('The other device stopped answering.');
      },
    );
  }

  void send(List<int> frame) {
    final ByteData len = ByteData(4)..setUint32(0, frame.length);
    socket
      ..add(len.buffer.asUint8List())
      ..add(frame);
  }

  Future<void> close() async {
    await _sub.cancel();
    try {
      await socket.flush();
    } catch (_) {}
    socket.destroy();
  }
}

/// Who is at the other end, as it said in its hello.
class SyncHello {
  const SyncHello(this.id, this.name);
  final String id;
  final String name;
}

/// What a device needs to open links: who it is and the keys of the devices
/// it is paired with.
abstract class SyncIdentity {
  String get id;
  String get name;

  /// The pair key shared with [peerId]; null when not paired.
  List<int>? pairKey(String peerId);
}

/// An open, encrypted link.
class SyncLink {
  SyncLink._(this._frames, this.peer, this._send, this._receive);

  final _Frames _frames;
  final SyncHello peer;
  final SecretKey _send;
  final SecretKey _receive;
  int _sent = 0;
  int _got = 0;

  static final Chacha20 _aead = Chacha20.poly1305Aead();
  static const Duration _step = Duration(seconds: 30);

  static List<int> _nonce(int n) {
    final ByteData d = ByteData(12)..setUint64(4, n);
    return d.buffer.asUint8List();
  }

  Future<void> _seal(int type, List<int> body) async {
    final SecretBox box = await _aead.encrypt(
      <int>[type, ...body],
      secretKey: _send,
      nonce: _nonce(_sent++),
    );
    _frames.send(<int>[...box.cipherText, ...box.mac.bytes]);
  }

  Future<(int, Uint8List)> _open([Duration timeout = _step]) async {
    final Uint8List f = await _frames.next(timeout);
    if (f.length < 17) {
      throw const SyncException('The other device sent a broken message.');
    }
    final List<int> clear;
    try {
      clear = await _aead.decrypt(
        SecretBox(
          Uint8List.sublistView(f, 0, f.length - 16),
          nonce: _nonce(_got++),
          mac: Mac(Uint8List.sublistView(f, f.length - 16)),
        ),
        secretKey: _receive,
      );
    } on SecretBoxAuthenticationError {
      throw const SyncException(
        'The other device answered with another key: pair the two again.',
      );
    }
    return (clear[0], Uint8List.fromList(clear.sublist(1)));
  }

  Future<void> sendJson(Map<String, Object?> m) =>
      _seal(0, utf8.encode(jsonEncode(m)));

  Future<void> sendBytes(List<int> b) => _seal(1, b);

  Future<Map<String, Object?>> receiveJson([Duration timeout = _step]) async {
    final (int t, Uint8List b) = await _open(timeout);
    final Object? j = t == 0 ? jsonDecode(utf8.decode(b)) : null;
    if (j is! Map<String, Object?>) {
      throw const SyncException('The other device sent something unexpected.');
    }
    return j;
  }

  Future<Uint8List> receiveBytes() async {
    final (int t, Uint8List b) = await _open();
    if (t != 1) {
      throw const SyncException('The other device sent something unexpected.');
    }
    return b;
  }

  Future<void> close() => _frames.close();
}

/// A pairing in progress: [code] is shown on both screens; [confirm] sends
/// this side's answer and completes with the pair key when both said yes.
class SyncPairing {
  SyncPairing._(this.link, this.code, this._key);

  final SyncLink link;
  final String code;
  final List<int> _key;

  SyncHello get peer => link.peer;

  /// Sends [ok] and waits for the other side's answer; the pair key when
  /// both agree. Always closes the link.
  Future<List<int>?> confirm(bool ok) async {
    try {
      await link.sendJson(<String, Object?>{'t': 'confirm', 'ok': ok});
      if (!ok) {
        return null;
      }
      final Map<String, Object?> m = await link.receiveJson(
        const Duration(minutes: 3),
      );
      return m['t'] == 'confirm' && m['ok'] == true ? _key : null;
    } finally {
      await link.close();
    }
  }
}

final X25519 _x25519 = X25519();
final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
final Random _random = Random.secure();

List<int> _randomBytes(int n) =>
    List<int>.generate(n, (_) => _random.nextInt(256));

String _b64(List<int> b) => base64.encode(b);

List<int> _unb64(Object? v, int length) {
  try {
    final List<int> b = v is String ? base64.decode(v) : <int>[];
    if (b.length == length) {
      return b;
    }
  } on FormatException {
    // falls through
  }
  throw const SyncException('The other device sent a broken hello.');
}

Map<String, Object?> _json(Uint8List f) {
  try {
    final Object? j = jsonDecode(utf8.decode(f));
    if (j is Map<String, Object?>) {
      return j;
    }
  } on FormatException {
    // falls through
  }
  throw const SyncException('Not a Pocket AMP Tools device.');
}

const Duration _hello = Duration(seconds: 10);

class _Keys {
  _Keys(this.toResponder, this.toInitiator, this.code, this.pairKey);
  final SecretKey toResponder;
  final SecretKey toInitiator;
  final String code;
  final List<int> pairKey;
}

Future<_Keys> _derive({
  required SimpleKeyPair mine,
  required List<int> theirPublic,
  required List<int> initiatorPublic,
  required List<int> responderPublic,
  required List<int> initiatorNonce,
  required List<int> responderNonce,
  List<int>? pairKey,
}) async {
  final List<int> dh = await (await _x25519.sharedSecretKey(
    keyPair: mine,
    remotePublicKey: SimplePublicKey(theirPublic, type: KeyPairType.x25519),
  )).extractBytes();
  final List<int> salt = <int>[
    ...initiatorPublic,
    ...responderPublic,
    ...initiatorNonce,
    ...responderNonce,
  ];
  Future<SecretKey> k(String info) => _hkdf.deriveKey(
    secretKey: SecretKey(<int>[...dh, ...?pairKey]),
    nonce: salt,
    info: utf8.encode(info),
  );
  final List<int> h = sha256Bytes(<int>[
    ...utf8.encode('$syncApp code'),
    ...salt,
  ]);
  final int n =
      ByteData.sublistView(Uint8List.fromList(h)).getUint32(0) % 1000000;
  return _Keys(
    await k('$syncApp ${pairKey == null ? 'pair' : 'sync'} i>r'),
    await k('$syncApp ${pairKey == null ? 'pair' : 'sync'} i<r'),
    n.toString().padLeft(6, '0'),
    await (await k('$syncApp pair key')).extractBytes(),
  );
}

/// Opens a link to [host]:[port]. With [pair], starts a pairing; otherwise
/// [expectId] must be a paired device.
Future<Object> _connect(
  SyncIdentity me,
  InternetAddress host,
  int port, {
  required bool pair,
  String? expectId,
}) async {
  final Socket s = await Socket.connect(host, port, timeout: _hello);
  final _Frames f = _Frames(s);
  try {
    final SimpleKeyPair eph = await _x25519.newKeyPair();
    final List<int> pub = (await eph.extractPublicKey()).bytes;
    final List<int> nonce = _randomBytes(16);
    f.send(
      utf8.encode(
        jsonEncode(<String, Object?>{
          'app': syncApp,
          'v': syncVersion,
          'mode': pair ? 'pair' : 'sync',
          'id': me.id,
          'name': me.name,
          if (pair) 'commit': _b64(sha256Bytes(<int>[...pub, ...nonce])),
          if (!pair) 'pub': _b64(pub),
          if (!pair) 'nonce': _b64(nonce),
        }),
      ),
    );
    final Map<String, Object?> r = _json(await f.next(_hello));
    if (r['error'] is String) {
      throw SyncException(r['error']! as String);
    }
    final Object? id = r['id'];
    final Object? name = r['name'];
    if (r['app'] != syncApp || id is! String || name is! String) {
      throw const SyncException('Not a Pocket AMP Tools device.');
    }
    if (expectId != null && id != expectId) {
      throw const SyncException('Another device answered at that address.');
    }
    final List<int>? key = pair ? null : me.pairKey(id);
    if (!pair && key == null) {
      throw const SyncException('That device is not paired with this one.');
    }
    final List<int> theirPub = _unb64(r['pub'], 32);
    final List<int> theirNonce = _unb64(r['nonce'], 16);
    if (pair) {
      f.send(
        utf8.encode(
          jsonEncode(<String, Object?>{'pub': _b64(pub), 'nonce': _b64(nonce)}),
        ),
      );
    }
    final _Keys k = await _derive(
      mine: eph,
      theirPublic: theirPub,
      initiatorPublic: pub,
      responderPublic: theirPub,
      initiatorNonce: nonce,
      responderNonce: theirNonce,
      pairKey: key,
    );
    final SyncLink link = SyncLink._(
      f,
      SyncHello(id, name),
      k.toResponder,
      k.toInitiator,
    );
    return pair ? SyncPairing._(link, k.code, k.pairKey) : link;
  } catch (_) {
    await f.close();
    rethrow;
  }
}

/// Starts pairing with the device at [host]:[port].
Future<SyncPairing> connectToPair(
  SyncIdentity me,
  InternetAddress host,
  int port,
) async => await _connect(me, host, port, pair: true) as SyncPairing;

/// Opens a sync link to the paired device [peerId] at [host]:[port].
Future<SyncLink> connectToSync(
  SyncIdentity me,
  InternetAddress host,
  int port,
  String peerId,
) async =>
    await _connect(me, host, port, pair: false, expectId: peerId) as SyncLink;

/// Answers a device that connected to this one: a [SyncPairing] or a
/// [SyncLink]. [allowPairing] false refuses new pairings.
Future<Object> acceptLink(
  SyncIdentity me,
  Socket s, {
  bool allowPairing = true,
}) async {
  final _Frames f = _Frames(s);
  void refuse(String why) => f.send(
    utf8.encode(jsonEncode(<String, Object?>{'app': syncApp, 'error': why})),
  );
  try {
    final Map<String, Object?> h = _json(await f.next(_hello));
    final Object? id = h['id'];
    final Object? name = h['name'];
    if (h['app'] != syncApp || id is! String || name is! String) {
      throw const SyncException('Not a Pocket AMP Tools device.');
    }
    if (h['v'] != syncVersion) {
      refuse('Update Pocket AMP Tools on both devices to the same version.');
      throw const SyncException('A device with another app version called.');
    }
    final bool pair = h['mode'] == 'pair';
    final List<int>? key = pair ? null : me.pairKey(id);
    if (pair && !allowPairing) {
      refuse('Open the Sync page on ${me.name} to pair.');
      throw SyncException('$name asked to pair while pairing was off.');
    }
    if (!pair && key == null) {
      refuse('${me.name} is not paired with this device: pair them again.');
      throw SyncException('$name is not paired with this device.');
    }
    final SimpleKeyPair eph = await _x25519.newKeyPair();
    final List<int> pub = (await eph.extractPublicKey()).bytes;
    final List<int> nonce = _randomBytes(16);
    final List<int>? commit = pair ? _unb64(h['commit'], 32) : null;
    f.send(
      utf8.encode(
        jsonEncode(<String, Object?>{
          'app': syncApp,
          'v': syncVersion,
          'id': me.id,
          'name': me.name,
          'pub': _b64(pub),
          'nonce': _b64(nonce),
        }),
      ),
    );
    final List<int> theirPub;
    final List<int> theirNonce;
    if (pair) {
      final Map<String, Object?> o = _json(await f.next(_hello));
      theirPub = _unb64(o['pub'], 32);
      theirNonce = _unb64(o['nonce'], 16);
      if (!_same(sha256Bytes(<int>[...theirPub, ...theirNonce]), commit!)) {
        throw const SyncException('The other device broke the pairing rules.');
      }
    } else {
      theirPub = _unb64(h['pub'], 32);
      theirNonce = _unb64(h['nonce'], 16);
    }
    final _Keys k = await _derive(
      mine: eph,
      theirPublic: theirPub,
      initiatorPublic: theirPub,
      responderPublic: pub,
      initiatorNonce: theirNonce,
      responderNonce: nonce,
      pairKey: key,
    );
    final SyncLink link = SyncLink._(
      f,
      SyncHello(id, name),
      k.toInitiator,
      k.toResponder,
    );
    return pair ? SyncPairing._(link, k.code, k.pairKey) : link;
  } catch (_) {
    await f.close();
    rethrow;
  }
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  int d = 0;
  for (int i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}
