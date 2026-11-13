// SPDX-License-Identifier: GPL-3.0-only

import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../firmware_package.dart';
import '../midi/midi_backend.dart';
import '../pedal_updater.dart';
import 'amp_upload.dart';
import 'ir_upload.dart';
import 'live_link.dart';
import 'preset_backup.dart';
import 'preset_session.dart';

/// Backs up and restores the preset bank of a detected pedal.
class PresetService {
  PresetService(this.backend);

  final MidiBackend backend;

  Future<PresetBackup> backup(
    DetectedPedal pedal, {
    void Function(double fraction)? onProgress,
  }) async {
    _checkPedal(pedal);
    final PresetSession s = PresetSession(await _open(pedal));
    try {
      return await readPresetBank(s, pedal.identity, onProgress: onProgress);
    } finally {
      await s.close();
    }
  }

  Future<PresetDiff> restore(
    DetectedPedal pedal,
    PresetBackup backup, {
    void Function(String step, double fraction)? onProgress,
    PresetBackup? expected,
  }) async {
    _checkPedal(pedal);
    if (familyOf(backup.identity) != pedal.family) {
      throw PresetIoException(
        'This backup is from a "${familyOf(backup.identity)}", '
        'not a "${pedal.family}".',
      );
    }
    final PresetSession s = PresetSession(await _open(pedal));
    try {
      return await restorePresetBank(
        s,
        backup,
        onProgress: onProgress,
        expected: expected,
      );
    } finally {
      await s.close();
    }
  }

  /// Restores P01..P79 from the raw copy [area] of [identity], a pedal on
  /// older clone firmware; P80 and the EQ stay as the pedal has them. Returns
  /// what was restored and the bank as written.
  Future<(PresetDiff, PresetBackup)> restoreOld(
    DetectedPedal pedal,
    String identity,
    Uint8List area, {
    void Function(String step, double fraction)? onProgress,
  }) async {
    _checkPedal(pedal);
    if (familyOf(identity) != pedal.family) {
      throw PresetIoException(
        'This raw copy is from a "${familyOf(identity)}", '
        'not a "${pedal.family}".',
      );
    }
    final PresetSession s = PresetSession(await _open(pedal));
    try {
      final PresetBackup now = await readPresetBank(
        s,
        pedal.identity,
        onProgress: (double f) => onProgress?.call('Reading the pedal', f),
      );
      final PresetBackup b = now.withOldPresets(area);
      return (
        await restorePresetBank(s, b, onProgress: onProgress, expected: now),
        b,
      );
    } on FormatException catch (e) {
      throw PresetIoException(e.message);
    } finally {
      await s.close();
    }
  }

  /// Opens the pedal for live editing. Close the link before any other
  /// operation: only one can use the port at a time.
  Future<LiveLink> openLive(
    DetectedPedal pedal, {
    required void Function(Object error) onError,
  }) async {
    _checkPedal(pedal);
    return LiveLink(PresetSession(await _open(pedal)), onError: onError);
  }

  /// AMP and CAB model names stored on the pedal, as stored.
  Future<(List<String>, List<String>)> readNames(DetectedPedal pedal) async {
    _checkPedal(pedal);
    final PresetSession s = PresetSession(await _open(pedal));
    try {
      return (await s.readNames(amp: true), await s.readNames(amp: false));
    } finally {
      await s.close();
    }
  }

  /// Puts [pcm] in CAB slot [slot] (0..19) named [name] and returns the CAB
  /// names read back afterwards.
  Future<List<String>> uploadIr(
    DetectedPedal pedal,
    int slot,
    String name,
    Uint8List pcm, {
    void Function(double fraction)? onProgress,
  }) => _upload(
    pedal,
    irUploadPackets(slot, name, pcm),
    amp: false,
    slot: slot,
    want: sanitizeIrName(name),
    what: 'IR',
    onProgress: onProgress,
  );

  /// Puts a "NAM\0" network [image] in AMP slot [slot] (0..19) and returns
  /// the AMP names read back afterwards.
  Future<List<String>> uploadAmp(
    DetectedPedal pedal,
    int slot,
    Uint8List image, {
    void Function(double fraction)? onProgress,
  }) => _upload(
    pedal,
    ampUploadPackets(slot, image),
    amp: true,
    slot: slot,
    want: namImageName(image),
    what: 'network',
    onProgress: onProgress,
  );

  Future<List<String>> _upload(
    DetectedPedal pedal,
    List<(Uint8List, String)> packets, {
    required bool amp,
    required int slot,
    required String want,
    required String what,
    void Function(double fraction)? onProgress,
  }) async {
    _checkPedal(pedal);
    if (pedal.port.bluetooth) {
      throw PresetIoException('Uploading an $what needs the USB cable.');
    }
    final PresetSession s = PresetSession(await _open(pedal));
    try {
      for (final (int i, (Uint8List packet, String step)) in packets.indexed) {
        // The last packet copies the buffer to flash.
        await s.write(packet, step, once: i == packets.length - 1);
        onProgress?.call((i + 1) / packets.length);
      }
      final List<String> names = await s.readNames(amp: amp);
      // The pedal overwrites the first character of the first name.
      final String got = names[slot];
      final bool same = slot == 0
          ? got.length == want.length && got.substring(1) == want.substring(1)
          : got == want;
      if (!same) {
        throw PresetIoException(
          'The pedal answered, but slot ${slot + 1} reads "$got", not '
          '"$want". Send the $what again.',
        );
      }
      return names;
    } finally {
      await s.close();
    }
  }

  /// Opens the pedal's port after checking it is still the port that was
  /// detected: on some systems a port's id goes to another device when
  /// devices are plugged or unplugged.
  Future<MidiConnection> _open(DetectedPedal pedal) async {
    final bool there = (await backend.listPorts()).any(
      (MidiPortRef p) =>
          p.id == pedal.port.id &&
          p.name == pedal.port.name &&
          p.usbId == pedal.port.usbId,
    );
    if (!there) {
      throw const PresetIoException(
        'The pedal is no longer where it was detected. Click Detect again.',
      );
    }
    return backend.open(pedal.port);
  }

  static void _checkPedal(DetectedPedal pedal) {
    if (pedal.inLoader) {
      throw const PresetIoException(
        'The pedal is in update mode; presets can only be read after the '
        'update finishes.',
      );
    }
  }

  /// Keeps a copy in `Documents/Pocket AMP Tools`, so a backup taken right
  /// before an update survives the app being closed.
  static Future<File> keepCopy(PresetBackup backup) async {
    final String text = backup.toJson();
    // A backup that cannot be opened again is no backup.
    final PresetBackup back = PresetBackup.fromJson(text);
    if (PresetDiff.between(back, backup).isEmpty == false) {
      throw const PresetIoException(
        'The backup file would not restore the same presets.',
      );
    }
    final File f = await _inKeepDir(backup.suggestedFileName);
    await f.writeAsString(text);
    return f;
  }

  /// Keeps the raw preset area of a pedal whose layout is unknown, so the
  /// bytes are not lost and can be studied later.
  static Future<File> keepRaw(String identity, Uint8List area) async {
    final String stamp = DateTime.now()
        .toIso8601String()
        .split('.')
        .first
        .replaceAll(':', '');
    // The identity comes from the device: keep only safe characters.
    final String name = identity.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final File f = await _inKeepDir('raw-$name-$stamp.bin');
    await f.writeAsBytes(area);
    return f;
  }

  /// Backups and raw copies kept in `Documents/Pocket AMP Tools`, by name,
  /// newest first. Files that do not read as a backup are listed with their
  /// error; a raw copy that can be restored has neither.
  static Future<List<(File, PresetBackup?, String?)>> kept() async {
    final Directory dir = (await _inKeepDir('x')).parent;
    // Backups made while the app was called Pocket AMP Upgrader stay where
    // they were and are listed too.
    final Directory old = Directory(
      '${dir.parent.path}${Platform.pathSeparator}Pocket AMP Upgrader',
    );
    // One unreadable folder or a file that goes away while listing leaves
    // the rest of the list.
    bool usable(File f) {
      try {
        return (f.path.endsWith('.json') ||
                rawIdentity(f.uri.pathSegments.last) != null) &&
            // Regular files only (no links, pipes or devices), and small: a
            // backup is about 100 KB.
            FileSystemEntity.typeSync(f.path, followLinks: false) ==
                FileSystemEntityType.file &&
            f.lengthSync() < 4 << 20;
      } on FileSystemException {
        return false;
      }
    }

    final List<File> files =
        <File>[
          for (final Directory d in <Directory>[dir, old])
            if (d.existsSync())
              ...() {
                try {
                  return d.listSync().whereType<File>().where(usable);
                } on FileSystemException {
                  return const <File>[];
                }
              }(),
        ]..sort(
          (File a, File b) =>
              b.uri.pathSegments.last.compareTo(a.uri.pathSegments.last),
        );
    return <(File, PresetBackup?, String?)>[
      for (final File f in files) await _read(f),
    ];
  }

  /// The pedal identity in the name [keepRaw] gives a raw copy, or null.
  static String? rawIdentity(String name) {
    final String? id = RegExp(r'^raw-(.+)-\d{4}-\d{2}-\d{2}T\d{6}\.bin$')
        .firstMatch(name)
        ?.group(1);
    final int cut = id?.lastIndexOf('_') ?? -1;
    // keepRaw wrote spaces as '_' (`DONNER Pocket AMP_008`); the last '_'
    // still splits the family from the version.
    return cut < 0
        ? id
        : '${id!.substring(0, cut).replaceAll('_', ' ')}${id.substring(cut)}';
  }

  /// A raw copy reads as no backup and no error when its P01..P79 can be
  /// restored (see [restoreOld]).
  static Future<(File, PresetBackup?, String?)> _read(File f) async {
    try {
      if (await f.length() > 4 << 20) {
        throw const FormatException('too large for a backup');
      }
      if (f.path.endsWith('.bin')) {
        return isOldPresetArea(await f.readAsBytes())
            ? (f, null, null)
            : (f, null, 'raw copy in a layout the app does not know');
      }
      return (f, PresetBackup.fromJson(await f.readAsString()), null);
    } catch (e) {
      return (f, null, '$e');
    }
  }

  static Future<File> _inKeepDir(String name) async {
    final Directory docs = await getApplicationDocumentsDirectory();
    final Directory dir = Directory(
      '${docs.path}${Platform.pathSeparator}Pocket AMP Tools',
    );
    await dir.create(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}$name');
  }
}
