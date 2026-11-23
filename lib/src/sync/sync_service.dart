// SPDX-License-Identifier: GPL-3.0-only
//
// Keeps paired devices on the same network in sync while the app is open on
// them, with no button to press. Once switched on, the app:
//   - listens for links from paired devices (TCP, a port the system picks);
//   - says on the network who it is, its port and a fingerprint of what it
//     holds (UDP broadcast every few seconds);
//   - looks for changes on this device every few seconds;
//   - syncs with a paired device whenever their fingerprints differ.
// Pairing needs both screens: the Sync page must be open on the device that
// is asked. Nothing is sent to a device that was never paired.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../private_file.dart';
import 'sync_channel.dart';
import 'sync_data.dart';
import 'sync_exchange.dart';
import 'sync_index.dart';

/// The port for both the hellos (UDP) and links (TCP): one port to allow in
/// a firewall. Links fall back to any free port when it is taken.
const int syncPort = 47913;

class SyncPeer {
  SyncPeer(this.id, this.name, this.key);
  final String id;
  String name;
  final List<int> key;

  /// When the last sync with it ended well, and what it did.
  DateTime? lastSync;
  String? lastResult;
  String? lastError;
}

/// A device heard on the network.
class NearbyDevice {
  NearbyDevice(this.id, this.name, this.address, this.port, this.revision);
  final String id;
  String name;
  InternetAddress address;
  int port;
  String revision;
  DateTime seen = DateTime.now();
}

/// Answers a pairing request: shows [code] and whether [name] asks, and
/// completes with the person's answer.
typedef PairPrompt = Future<bool> Function(String name, String code);

class SyncService extends ChangeNotifier implements SyncIdentity {
  SyncService({
    required this.data,
    required this.stateFile,
    this.onChanged,
    this.log,
    this.discoveryPort = syncPort,
    this.tick = const Duration(seconds: 3),
  });

  final SyncData data;
  final File stateFile;

  /// Called after a sync changed something on this device.
  final VoidCallback? onChanged;
  final void Function(String line)? log;
  final int discoveryPort;
  final Duration tick;

  @override
  String id = '';
  @override
  String name = '';
  bool enabled = false;

  /// The firewall ('ufw', 'firewalld') this app already let sync through.
  String? firewallOpened;
  final Map<String, SyncPeer> peers = <String, SyncPeer>{};
  final Map<String, NearbyDevice> nearby = <String, NearbyDevice>{};
  SyncIndex _index = <String, SyncEntry>{};
  String _revision = '';

  /// Set while the Sync page is open: pairing requests are asked there.
  PairPrompt? onPairRequest;

  ServerSocket? _server;
  RawDatagramSocket? _udp;
  Timer? _timer;
  bool _loaded = false;
  bool _beating = false;
  Future<void> _saving = Future<void>.value();
  Future<void> _lock = Future<void>.value();
  final Map<String, String> _tried = <String, String>{};
  final Map<String, int> _mismatch = <String, int>{};
  final Map<String, DateTime> _quietUntil = <String, DateTime>{};

  /// The fingerprint this device says it holds.
  @visibleForTesting
  String get revision => _revision;

  /// The port links are taken on; null while off.
  int? get port => _server?.port;

  @override
  List<int>? pairKey(String peerId) => peers[peerId]?.key;

  /// Reads the saved state and starts if it was on.
  Future<void> load() async {
    if (_loaded) {
      return;
    }
    _loaded = true;
    try {
      final Object? j = jsonDecode(await stateFile.readAsString());
      if (j is Map<String, Object?>) {
        id = j['id'] is String ? j['id']! as String : '';
        name = j['name'] is String ? j['name']! as String : '';
        enabled = j['enabled'] == true;
        firewallOpened = j['firewall'] is String
            ? j['firewall']! as String
            : null;
        _index = indexFromJson(j['index']);
        final Object? p = j['peers'];
        if (p is Map<String, Object?>) {
          for (final MapEntry<String, Object?> e in p.entries) {
            final Object? v = e.value;
            if (v is Map<String, Object?> &&
                v['name'] is String &&
                v['key'] is String) {
              peers[e.key] = SyncPeer(
                e.key,
                v['name']! as String,
                base64.decode(v['key']! as String),
              );
            }
          }
        }
      }
    } on FileSystemException {
      // first run
    } on FormatException {
      // a broken file: start over, pairings are lost
    }
    if (id.isEmpty) {
      final Random r = Random.secure();
      id = List<String>.generate(
        16,
        (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
    }
    if (name.isEmpty) {
      name = defaultDeviceName();
    }
    if (enabled) {
      await _start();
    }
    notifyListeners();
  }

  static String defaultDeviceName() {
    final String h = Platform.localHostname;
    if (h.isNotEmpty && h != 'localhost') {
      return h;
    }
    return switch (Platform.operatingSystem) {
      'android' => 'Android',
      'ios' => 'iPhone',
      final String os => os,
    };
  }

  Future<void> setEnabled(bool on) async {
    enabled = on;
    notifyListeners(); // the switch moves at once; starting takes a moment
    if (on) {
      await _start();
    } else {
      await _stop();
    }
    await _save();
    notifyListeners();
  }

  Future<void> rename(String to) async {
    final String n = to.trim();
    if (n.isEmpty || n.length > 40) {
      return;
    }
    name = n;
    await _save();
    _announce();
    notifyListeners();
  }

  Future<void> markFirewallOpened(String firewall) async {
    firewallOpened = firewall;
    notifyListeners();
    await _save();
  }

  Future<void> forget(String peerId) async {
    peers.remove(peerId);
    await _save();
    notifyListeners();
  }

  /// Pairs with [d]; [ask] shows the code and returns the person's answer.
  /// The new peer, or null when either side said no.
  Future<SyncPeer?> pair(NearbyDevice d, PairPrompt ask) async {
    final SyncPairing p = await connectToPair(this, d.address, d.port);
    final List<int>? key = await p.confirm(await ask(p.peer.name, p.code));
    return key == null ? null : _paired(p.peer, key);
  }

  /// Syncs with every paired device in sight now, without waiting for a
  /// change.
  Future<void> syncNow() async {
    for (final NearbyDevice d in nearby.values.toList()) {
      if (peers.containsKey(d.id)) {
        await _syncWith(d);
      }
    }
  }

  Future<SyncPeer> _paired(SyncHello who, List<int> key) async {
    final SyncPeer p = SyncPeer(who.id, who.name, key);
    peers[who.id] = p;
    _tried.remove(who.id);
    notifyListeners();
    await _save();
    return p;
  }

  Future<void> _start() async {
    if (_server != null) {
      return;
    }
    try {
      try {
        _server = await ServerSocket.bind(
          InternetAddress.anyIPv4,
          discoveryPort,
        );
      } on SocketException {
        _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      }
      _server!.listen(_accept);
      _udp = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
      );
      _udp!
        ..broadcastEnabled = true
        ..listen(
          (RawSocketEvent e) {
            if (e == RawSocketEvent.read) {
              final Datagram? d = _udp?.receive();
              if (d != null) {
                _heard(d);
              }
            }
          },
          // A send the network refused (no route, Wi-Fi off) is no reason
          // to stop: the next hello tries again.
          onError: (Object e) => log?.call('Sync: network: $e'),
        );
    } on SocketException catch (e) {
      log?.call('Sync could not start: $e');
      await _stop();
      return;
    }
    await _locked(_refresh);
    _announce();
    _timer = Timer.periodic(tick, (_) => unawaited(_beat()));
  }

  Future<void> _stop() async {
    _timer?.cancel();
    _timer = null;
    await _server?.close();
    _server = null;
    _udp?.close();
    _udp = null;
    nearby.clear();
  }

  @override
  void dispose() {
    unawaited(_stop());
    super.dispose();
  }

  /// One step of the loop: look for changes, say so, sync where needed.
  Future<void> _beat() async {
    if (_beating) {
      return;
    }
    _beating = true;
    try {
      await _beatOnce();
    } finally {
      _beating = false;
    }
  }

  Future<void> _beatOnce() async {
    // Under the lock: a sync running now must not be undone by a scan made
    // before it ended.
    if (await _locked(_refresh)) {
      await _save();
    }
    _announce();
    final DateTime now = DateTime.now();
    nearby.removeWhere(
      (String _, NearbyDevice d) => now.difference(d.seen) > tick * 4,
    );
    for (final NearbyDevice d in nearby.values.toList()) {
      if (!peers.containsKey(d.id) ||
          d.revision == _revision ||
          now.isBefore(_quietUntil[d.id] ?? now)) {
        _mismatch.remove(d.id);
        continue;
      }
      final String key = '$_revision|${d.revision}';
      if (_tried[d.id] == key) {
        continue; // nothing changed since the last try
      }
      // Both would call at once; the smaller id calls first, the other only
      // if it was not called.
      final int n = _mismatch[d.id] = (_mismatch[d.id] ?? 0) + 1;
      if (n >= (id.compareTo(d.id) < 0 ? 1 : 3)) {
        _tried[d.id] = key;
        await _syncWith(d);
      }
    }
    notifyListeners();
  }

  /// Brings the index up to date; true when this device changed.
  Future<bool> _refresh() async {
    final SyncIndex next = refreshIndex(
      _index,
      await data.scan(),
      DateTime.now().millisecondsSinceEpoch,
    );
    final bool changed = !mapEquals(next, _index);
    _index = next;
    _revision = indexRevision(_index);
    return changed;
  }

  void _announce() {
    final int? p = port;
    if (_udp == null || p == null || discoveryPort == 0) {
      return;
    }
    try {
      _udp!.send(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'app': syncApp,
            'v': syncVersion,
            'id': id,
            'name': name,
            'port': p,
            'rev': _revision,
          }),
        ),
        InternetAddress('255.255.255.255'),
        discoveryPort,
      );
    } on SocketException {
      // no network right now
    }
  }

  void _heard(Datagram d) {
    final Object? j;
    try {
      j = jsonDecode(utf8.decode(d.data));
    } on FormatException {
      return;
    }
    if (j is! Map<String, Object?> ||
        j['app'] != syncApp ||
        j['v'] != syncVersion ||
        j['id'] is! String ||
        j['id'] == id ||
        j['name'] is! String ||
        j['port'] is! int ||
        j['rev'] is! String) {
      return;
    }
    final String who = j['id']! as String;
    final String n = j['name']! as String;
    final NearbyDevice? was = nearby[who];
    if (was == null) {
      nearby[who] = NearbyDevice(
        who,
        n,
        d.address,
        j['port']! as int,
        j['rev']! as String,
      );
      notifyListeners();
    } else {
      was
        ..name = n
        ..address = d.address
        ..port = j['port']! as int
        ..revision = j['rev']! as String
        ..seen = DateTime.now();
    }
    if (peers[who] case final SyncPeer p when p.name != n) {
      p.name = n;
      unawaited(_save());
    }
  }

  /// Runs [job] after every sync before it: one at a time.
  Future<T> _locked<T>(Future<T> Function() job) {
    final Future<T> run = _lock.then((_) => job());
    _lock = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<void> _syncWith(NearbyDevice d) => _locked(() async {
    final SyncPeer? peer = peers[d.id];
    if (peer == null) {
      return;
    }
    try {
      await _refresh();
      final SyncLink link = await connectToSync(this, d.address, d.port, d.id);
      try {
        await _run(link, peer);
      } finally {
        await link.close();
      }
    } on Object catch (e) {
      peer.lastError = '$e';
      log?.call('Sync with ${peer.name} failed: $e');
      _quietUntil[d.id] = DateTime.now().add(const Duration(seconds: 30));
    }
    notifyListeners();
  });

  void _accept(Socket s) {
    unawaited(() async {
      final Object link;
      try {
        link = await acceptLink(this, s, allowPairing: onPairRequest != null);
      } on Object catch (e) {
        log?.call('Sync: refused a link: $e');
        return;
      }
      if (link is SyncPairing) {
        final PairPrompt? ask = onPairRequest;
        final bool ok = ask != null && await ask(link.peer.name, link.code);
        try {
          final List<int>? key = await link.confirm(ok);
          if (key != null) {
            await _paired(link.peer, key);
          }
        } on Object catch (e) {
          log?.call('Pairing with ${link.peer.name} failed: $e');
        }
        return;
      }
      final SyncLink l = link as SyncLink;
      await _locked(() async {
        try {
          await _refresh();
          await _run(l, peers[l.peer.id]!);
        } on Object catch (e) {
          peers[l.peer.id]?.lastError = '$e';
          log?.call('Sync with ${l.peer.name} failed: $e');
        } finally {
          await l.close();
        }
        notifyListeners();
      });
    }());
  }

  Future<void> _run(SyncLink link, SyncPeer peer) async {
    final SyncResult r = await exchange(link, data, _index);
    _index = r.index;
    _revision = indexRevision(_index);
    await _save();
    peer
      ..lastSync = DateTime.now()
      ..lastError = r.failed.isEmpty ? null : r.failed.join('; ')
      ..lastResult =
          'received ${r.received}, sent ${r.sent}'
          '${r.deleted == 0 ? '' : ', deleted ${r.deleted}'}';
    // The other side's next hello may still carry its old fingerprint.
    _quietUntil[peer.id] = DateTime.now().add(tick * 2);
    if (r.received + r.deleted + r.sent > 0) {
      log?.call('Synced with ${peer.name}: ${peer.lastResult}.');
    }
    for (final String f in r.failed) {
      log?.call('Sync: not taken from ${peer.name}: $f');
    }
    if (r.changedHere) {
      onChanged?.call();
    }
    _announce();
  }

  Future<void> _save() =>
      _saving = _saving.then((_) => _write(), onError: (_) => _write());

  Future<void> _write() async {
    try {
      await _writeState();
    } on FileSystemException catch (e) {
      log?.call('Sync state not saved: $e');
    }
  }

  Future<void> _writeState() => writePrivate(
    stateFile,
    jsonEncode(<String, Object?>{
      'format': 'pocket-amp-tools/sync@1',
      'id': id,
      'name': name,
      'enabled': enabled,
      'firewall': ?firewallOpened,
      'peers': <String, Object?>{
        for (final SyncPeer p in peers.values)
          p.id: <String, Object?>{'name': p.name, 'key': base64.encode(p.key)},
      },
      'index': indexToJson(_index),
    }),
  );
}
