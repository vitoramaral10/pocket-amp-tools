// SPDX-License-Identifier: GPL-3.0-only
//
// Update procedure for JieLi AC791N pedals over USB-MIDI. A Dart port of a
// Python tool that was used to update a real Pocket AMP from V1.03 to V1.05;
// the protocol comes from the FM1 Open browser updater (m-vave/fm1_open).

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'firmware_package.dart';
import 'presets/preset_backup.dart';
import 'presets/preset_session.dart';
import 'midi/midi_backend.dart';
import 'ota_protocol.dart';

/// USB ids seen on Pocket AMP units: firmware up to V1.03, V1.05, and the
/// update loader.
const Set<String> knownUsbIds = <String>{'4c4a:c755', '3654:7756', '4d4a:4155'};
const List<String> portNameHints = <String>[
  'pocket amp',
  'usb composite device',
  'jieli',
];

class UpdateException implements Exception {
  const UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Timing knobs; the defaults match the tool that was validated on hardware.
class UpdateTimings {
  const UpdateTimings({
    this.identityTimeout = const Duration(milliseconds: 750),
    this.loaderIdle = const Duration(seconds: 10),
    this.flashIdle = const Duration(seconds: 180),
    this.minPhaseTotal = const Duration(seconds: 120),
    this.afterSuccess = const Duration(milliseconds: 600),
    this.waitLoader = const Duration(seconds: 40),
    this.waitReboot = const Duration(seconds: 60),
    this.rescanEvery = const Duration(milliseconds: 600),
  });

  final Duration identityTimeout;
  final Duration loaderIdle;
  final Duration flashIdle;
  final Duration minPhaseTotal;
  final Duration afterSuccess;
  final Duration waitLoader;
  final Duration waitReboot;
  final Duration rescanEvery;
}

/// A pedal that answered the identity query.
class DetectedPedal {
  const DetectedPedal(this.port, this.identity, {this.presetsOnly = false});
  final MidiPortRef port;

  /// A name not on the confirmed list whose preset area is laid out like a
  /// Pocket AMP's: its presets can be used, its firmware is never updated.
  /// An FM-1 answers the same identity query on the same chip.
  final bool presetsOnly;

  /// e.g. `Pocket AMP_105`, or `ota-Pocket AMP_103` while in the loader.
  final String identity;

  bool get inLoader => identity.startsWith('ota-');
  String get family => familyOf(identity);

  /// `PIXIE1` when this is another brand's unit of [family], else null.
  String? get rebrand => rebrandOf(identity);
  String get version => versionOf(identity);
}

/// [backup] is run by the app before [PedalUpdater.update]; the updater
/// itself starts at [preparing].
enum UpdatePhase {
  backup,
  preparing,
  loader,
  waitingLoader,
  flash,
  rebooting,
  done,
}

class UpdateProgress {
  const UpdateProgress(this.phase, this.fraction);
  final UpdatePhase phase;

  /// 0..1 within the phase, or null when it cannot be measured.
  final double? fraction;
}

/// Frames in, frames out, on one open port.
class OtaLink {
  OtaLink(this._conn) {
    _sub = _conn.messages.listen(
      (Uint8List m) {
        trace?.call('rx ${_hex(m)}');
        final OtaMessage? msg = parseFrame(m);
        if (msg != null) {
          _queue.add(msg);
          _wake();
        }
      },
      onError: (Object e) {
        _gone = e is MidiPortGone ? e : MidiPortGone('$e');
        _wake();
      },
      onDone: () {
        _gone ??= const MidiPortGone('(closed)');
        _wake();
      },
    );
  }

  /// Raw traffic tap for diagnosing a device on the bench.
  static void Function(String line)? trace;

  static String _hex(List<int> b) {
    final String h = b
        .take(24)
        .map((int x) => x.toRadixString(16).padLeft(2, '0'))
        .join(' ');
    return b.length > 24 ? '$h … (${b.length} bytes)' : h;
  }

  final MidiConnection _conn;
  late final StreamSubscription<Uint8List> _sub;
  final Queue<OtaMessage> _queue = Queue<OtaMessage>();
  MidiPortGone? _gone;
  Completer<void>? _waiter;

  void _wake() {
    final Completer<void>? w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) {
      w.complete();
    }
  }

  /// Next frame, or null on timeout. Throws [MidiPortGone] once the port is
  /// gone and nothing is left in the queue.
  Future<OtaMessage?> read(Duration timeout) async {
    final Stopwatch clock = Stopwatch()..start();
    while (_queue.isEmpty) {
      if (_gone != null) {
        throw _gone!;
      }
      final Duration left = timeout - clock.elapsed;
      if (left <= Duration.zero) {
        return null;
      }
      final Completer<void> w = Completer<void>();
      _waiter = w;
      await w.future.timeout(left, onTimeout: () {});
    }
    return _queue.removeFirst();
  }

  Future<void> send(Uint8List sysex) {
    trace?.call('tx ${_hex(sysex)}');
    return _conn.send(sysex);
  }

  Future<Uint8List?> query(int command, Duration timeout) async {
    _queue.clear();
    await send(buildFrame(command));
    final Stopwatch clock = Stopwatch()..start();
    while (clock.elapsed < timeout) {
      final OtaMessage? m = await read(timeout - clock.elapsed);
      if (m != null && m.command == command) {
        return m.payload;
      }
    }
    return null;
  }

  Future<String?> identity(Duration timeout) async {
    for (int i = 0; i < 2; i++) {
      final Uint8List? reply = await query(cmdIdentity, timeout);
      if (reply != null) {
        return asciiZ(reply);
      }
    }
    return null;
  }

  Future<void> close() async {
    await _sub.cancel();
    try {
      await _conn.close();
    } catch (_) {
      // Closing a port whose device vanished is allowed to fail.
    }
  }
}

class PedalUpdater {
  PedalUpdater(
    this.backend, {
    this.timings = const UpdateTimings(),
    this.trustedLoaders = const <String>{knownLoaderSha256},
    void Function(String line)? log,
  }) : _log = log ?? ((String _) {});

  final MidiBackend backend;
  final UpdateTimings timings;

  /// SHA-256 of the update loaders this updater agrees to send.
  final Set<String> trustedLoaders;
  final void Function(String line) _log;

  static bool looksLikePedal(MidiPortRef p) {
    if (p.usbId != null && knownUsbIds.contains(p.usbId)) {
      return true;
    }
    final String n = p.name.toLowerCase();
    return portNameHints.any(n.contains);
  }

  /// Ports in the order they should be probed: likely pedals first. With
  /// [known], other ports are only probed if their name is not in it, i.e.
  /// they appeared after [known] was taken.
  Future<List<MidiPortRef>> _candidates([Set<String>? known]) async {
    // Bluetooth ports never get update traffic, not even the identity query.
    final List<MidiPortRef> ports = <MidiPortRef>[
      for (final MidiPortRef p in await backend.listPorts())
        if (!p.bluetooth) p,
    ];
    return <MidiPortRef>[
      ...ports.where(looksLikePedal),
      ...ports.where(
        (MidiPortRef p) =>
            !looksLikePedal(p) && (known == null || !known.contains(p.name)),
      ),
    ];
  }

  /// Opens [port] and asks for its identity. Returns the open link when
  /// [accept] likes the answer; closes it otherwise, also when the port fails
  /// with an I/O error while being asked.
  Future<(OtaLink, String)?> _probe(
    MidiPortRef port,
    bool Function(String identity) accept,
  ) async {
    final OtaLink link;
    try {
      link = OtaLink(await backend.open(port));
    } catch (e) {
      _log('  ${port.name}: cannot open ($e)');
      return null;
    }
    try {
      final String? id = await link.identity(timings.identityTimeout);
      if (id != null && accept(id)) {
        return (link, id);
      }
      if (id != null) {
        _log('  ${port.name}: answered "$id", not a supported pedal');
      }
    } on MidiPortGone {
      // Fall through and close.
    } on MidiIoException catch (e) {
      _log('  ${port.name}: I/O error ($e)');
    }
    await link.close();
    return null;
  }

  static bool _isSupported(String id) =>
      supportedProducts.contains(familyOf(id));

  /// Looks for a supported pedal on every MIDI port. Only the identity query
  /// is sent, and preset reads to a device that answered it with a name not
  /// on the list.
  Future<DetectedPedal?> detect() async {
    final List<MidiPortRef> ports = await _candidates();
    _log('Ports: ${ports.isEmpty ? '(none)' : ports.join(', ')}');
    final List<(MidiPortRef, String)> unlisted = <(MidiPortRef, String)>[];
    for (final MidiPortRef p in ports) {
      final (OtaLink, String)? hit = await _probe(p, (String id) {
        if (_isSupported(id)) {
          return true;
        }
        // In the loader there are no presets to look at.
        if (!id.startsWith('ota-')) {
          unlisted.add((p, id));
        }
        return false;
      });
      if (hit != null) {
        await hit.$1.close();
        _log('Found "${hit.$2}" on ${p.name}');
        return DetectedPedal(p, hit.$2);
      }
    }
    for (final (MidiPortRef p, String id) in unlisted) {
      if (await _hasPocketAmpPresets(p)) {
        _log('Found "$id" on ${p.name}, presets only');
        return DetectedPedal(p, id, presetsOnly: true);
      }
    }
    return _detectBluetooth();
  }

  /// Whether the preset area on [port] reads like a Pocket AMP's, in the
  /// V1.05 layout or the older one without an EQ table. Reads only.
  Future<bool> _hasPocketAmpPresets(MidiPortRef port) async {
    try {
      final PresetSession s = PresetSession(await backend.open(port));
      try {
        await readPresetBank(s, '');
        return true;
      } on UnknownPresetLayout catch (e) {
        return isOldPresetArea(e.area);
      } finally {
        await s.close();
      }
    } catch (e) {
      _log('  ${port.name}: presets not readable ($e)');
      return false;
    }
  }

  /// A Pocket AMP over Bluetooth, confirmed by reading its active preset.
  /// The radio does not tell the firmware version.
  Future<DetectedPedal?> _detectBluetooth() async {
    for (final MidiPortRef p in await backend.listPorts()) {
      if (!p.bluetooth) {
        continue;
      }
      try {
        final PresetSession s = PresetSession(await backend.open(p));
        try {
          await s.readLive();
        } finally {
          await s.close();
        }
        final String id = _isSupported(p.name) ? p.name : 'Pocket AMP_BLE';
        _log('Found "$id" over Bluetooth');
        return DetectedPedal(p, id);
      } catch (e) {
        _log('  ${p.name} (Bluetooth): $e');
      }
    }
    return null;
  }

  /// Reasons the update must not start, or empty when it may.
  List<String> blockers(FirmwarePackage pkg, DetectedPedal pedal) {
    return <String>[
      if (pedal.port.bluetooth)
        'The pedal is connected over Bluetooth. Firmware updates need the '
            'USB cable.',
      if (!pkg.isSupportedProduct)
        'This package is for "${reportedFamilyOf(pkg.product)}", which this tool does not support.',
      if (!trustedLoaders.contains(pkg.loaderSha256))
        'The package carries an unknown update loader; refusing to use it.',
      if (pedal.presetsOnly)
        '"${pedal.family}" is not on the list of pedals confirmed to be a '
            'Pocket AMP. Its presets can be used, but its firmware is not '
            'updated: a different pedal on the same chip would be bricked.'
      else if (pedal.family != pkg.productFamily)
        'The pedal is a "${pedal.family}" but the package is for "${pkg.productFamily}".',
      // Measured on a Pocket AMP 1.05: after reading the package it stops
      // asking for data instead of installing the version it already runs.
      if (!pedal.inLoader && pedal.identity == pkg.product)
        'The pedal already runs version ${pkg.version}. It does not reinstall '
            'the version it already has.',
    ];
  }

  /// Runs the whole update. Returns the identity the pedal reports at the end.
  ///
  /// Starting from a pedal already in the loader (`ota-...`) skips straight
  /// to the flash phase, which is how an interrupted update is resumed.
  Future<String> update(
    FirmwarePackage pkg,
    DetectedPedal pedal,
    void Function(UpdateProgress) onProgress,
  ) async {
    final List<String> no = blockers(pkg, pedal);
    if (no.isNotEmpty) {
      throw UpdateException(no.join('\n'));
    }
    onProgress(const UpdateProgress(UpdatePhase.preparing, null));
    final List<MidiPortRef> before = await backend.listPorts();
    // The pedal's own port name is never one of the others, even when it
    // does not look like a pedal: on Windows the Donner unit's port is just
    // "USB-MIDI", and it comes back under that name after each restart.
    final Set<String> others = <String>{
      for (final MidiPortRef p in before)
        if (!looksLikePedal(p) && p.name != pedal.port.name) p.name,
    };
    // Another pedal plugged in at the same time must never be taken for
    // this one when it comes back.
    final Set<String> otherPedals = <String>{
      for (final MidiPortRef p in before)
        if (looksLikePedal(p) && p.id != pedal.port.id) p.id,
    };
    // With two pedals plugged in, port ids can move to the other one while
    // this one reboots (Windows numbers them by position): refuse.
    if (otherPedals.isNotEmpty) {
      throw const UpdateException(
        'Another pedal is connected. Unplug it and keep only the pedal to '
        'update.',
      );
    }
    OtaLink link = OtaLink(await backend.open(pedal.port));
    try {
      final String? name = await link.identity(timings.identityTimeout);
      // Exactly the pedal the user confirmed, not just one of its family.
      if (name != pedal.identity) {
        throw UpdateException(
          'The pedal did not confirm its identity (expected '
          '"${pedal.identity}", got ${name == null ? 'nothing' : '"$name"'}). '
          'Click Detect again.',
        );
      }
      _log('Pedal "$name" -> package "${pkg.product}" (sha256 ${pkg.sha256})');

      if (!pedal.identity.startsWith('ota-')) {
        await link.send(armMessage);
        await _serve(
          link,
          pkg.image,
          finishLoader,
          timings.loaderIdle,
          UpdatePhase.loader,
          onProgress,
        );
        await link.close();
        onProgress(const UpdateProgress(UpdatePhase.waitingLoader, null));
        _log('Waiting for the pedal to come back in update mode...');
        (link, _) = await _waitFor(
          // Only this pedal's own update mode.
          (String id) => id == 'ota-${pedal.identity}',
          timings.waitLoader,
          others,
          otherPedals,
        );
      }

      await link.send(armMessage);
      await _serve(
        link,
        pkg.image,
        finishFlash,
        timings.flashIdle,
        UpdatePhase.flash,
        onProgress,
      );
      await link.close();
      onProgress(const UpdateProgress(UpdatePhase.rebooting, null));
      _log('Waiting for the pedal to restart...');
      final String result;
      (link, result) = await _waitFor(
        (String id) => !id.startsWith('ota-') && _isSupported(id),
        timings.waitReboot,
        others,
        otherPedals,
      );
      await link.close();
      _log('Pedal is back as "$result"');
      if (result != pkg.product) {
        throw UpdateException(
          'The pedal restarted as "$result", not "${pkg.product}". '
          'The new firmware may not have been accepted; try the update again.',
        );
      }
      onProgress(const UpdateProgress(UpdatePhase.done, 1));
      return result;
    } catch (_) {
      await link.close();
      rethrow;
    }
  }

  Future<(OtaLink, String)> _waitFor(
    bool Function(String) accept,
    Duration limit,
    Set<String> known,
    Set<String> skipIds,
  ) async {
    final Stopwatch clock = Stopwatch()..start();
    while (clock.elapsed < limit) {
      for (final MidiPortRef p in await _candidates(known)) {
        if (skipIds.contains(p.id)) {
          continue;
        }
        final (OtaLink, String)? hit = await _probe(p, accept);
        if (hit != null) {
          _log('Found "${hit.$2}" on ${p.name}');
          return hit;
        }
      }
      await Future<void>.delayed(timings.rescanEvery);
    }
    throw const UpdateException(
      'The pedal did not come back. Do not unplug it: reconnect it, open this '
      'app again and run the update once more; it resumes from update mode.',
    );
  }

  Future<void> _serve(
    OtaLink link,
    Uint8List image,
    int finish,
    Duration idle,
    UpdatePhase phase,
    void Function(UpdateProgress) onProgress,
  ) async {
    final Uint8List covered = Uint8List((image.length + 7) >> 3);
    int total = 0;
    final Stopwatch started = Stopwatch()..start();
    final Stopwatch sinceLast = Stopwatch()..start();
    final Duration maxTotal = idle * 3 > timings.minPhaseTotal
        ? idle * 3
        : timings.minPhaseTotal;
    double shown = -1;
    onProgress(UpdateProgress(phase, 0));
    while (true) {
      if (started.elapsed > maxTotal) {
        throw UpdateException('${phase.name}: took too long.');
      }
      if (sinceLast.elapsed > idle) {
        throw UpdateException(
          phase == UpdatePhase.loader && total < 64 * 1024
              ? 'The pedal stopped while reading the update. It does this '
                    'when it already runs this version. Its firmware was not '
                    'changed.'
              : '${phase.name}: the pedal stopped asking for data.',
        );
      }
      final OtaMessage? m = await link.read(const Duration(milliseconds: 250));
      if (m == null || m.command != cmdData || m.payload.length != 8) {
        continue;
      }
      final Uint8List req = m.payload;
      final int address = readLe(req, 1, 4);
      final int size = readLe(req, 5, 3);
      if (size <= 0 || size > 512) {
        throw UpdateException('${phase.name}: invalid request size ($size).');
      }
      if (address == finishLoader || address == finishFlash) {
        if (address != finish || size != 8) {
          throw UpdateException(
            '${phase.name}: unexpected end of phase 0x${address.toRadixString(16)}.',
          );
        }
        await link.send(buildFrame(cmdData, <int>[...req, ...successReply]));
        // The pedal restarts right after "success"; its port may vanish while
        // repeated end-of-phase requests are still being answered.
        final Stopwatch tail = Stopwatch()..start();
        try {
          while (tail.elapsed < timings.afterSuccess) {
            final OtaMessage? again = await link.read(
              const Duration(milliseconds: 100),
            );
            if (again != null &&
                again.command == cmdData &&
                again.payload.length == 8 &&
                readLe(again.payload, 1, 4) == finish) {
              await link.send(
                buildFrame(cmdData, <int>[...again.payload, ...successReply]),
              );
            }
          }
        } on MidiPortGone {
          // expected
        } on MidiIoException {
          // expected
        }
        onProgress(UpdateProgress(phase, 1));
        _log('${phase.name}: done (${started.elapsed.inSeconds}s)');
        return;
      }
      if (address + size > image.length) {
        throw UpdateException(
          '${phase.name}: request outside the package (0x${address.toRadixString(16)}+$size).',
        );
      }
      sinceLast.reset();
      await link.send(
        buildFrame(cmdData, <int>[
          ...req,
          ...image.sublist(address, address + size),
        ]),
      );
      for (int i = address; i < address + size; i++) {
        final int bit = 1 << (i & 7);
        if (covered[i >> 3] & bit == 0) {
          covered[i >> 3] |= bit;
          total++;
        }
      }
      final double f = (total / image.length).clamp(0, 0.99);
      if (f - shown >= 0.005) {
        shown = f;
        onProgress(UpdateProgress(phase, f));
      }
    }
  }
}
