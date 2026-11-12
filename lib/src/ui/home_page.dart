// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'dart:ui' show AppExitResponse;

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../firmware_package.dart';
import '../midi/midi_backend.dart';
import '../pedal_updater.dart';
import '../presets/live_link.dart';
import '../presets/preset_backup.dart';
import '../presets/preset_service.dart';
import '../presets/preset_session.dart';
import '../net/capped_http.dart';
import '../presets/ir_upload.dart';
import 'backups_page.dart';
import 'cabinets_page.dart';
import 'presets_page.dart';

/// Official download link published on M-VAVE's downloads page. The file is
/// fetched from M-VAVE's own server; this app never redistributes it.
const String officialFirmwareUrl =
    'https://yms-file-store.oss-cn-hongkong.aliyuncs.com/software/firmware/Pocket%20AMP.fwsc';

enum _Stage { idle, updating, success, failed }

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.backend});

  /// Injected in tests; the platform backend otherwise.
  final MidiBackend? backend;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final PedalUpdater _updater;
  late final PresetService _presets;
  late final AppLifecycleListener _lifecycle;
  final List<String> _log = <String>[];

  FirmwarePackage? _package;
  String? _packageSource;
  String? _packageError;
  bool _loadingPackage = false;

  DetectedPedal? _pedal;
  bool _detecting = false;
  bool _detectedOnce = false;

  _Stage _stage = _Stage.idle;
  UpdateProgress? _progress;
  String? _resultMessage;

  final PresetWorkspace _workspace = PresetWorkspace();

  /// 0 presets, 1 cabinets, 2 firmware, 3 backups.
  int _section = 0;

  /// Whether the user wants edits played on the pedal; the link itself is
  /// closed around every other pedal operation.
  bool _wantLive = true;

  /// Bumped by [_stopLive]: a live link that finishes opening after a stop
  /// (for example, once a firmware update has begun) is closed unused.
  int _liveGeneration = 0;
  Future<void>? _liveOpening;

  /// Set while a live link drains and closes: the port is still in use.
  Future<void>? _liveClosing;

  /// Backup taken right before the last update, offered for restoring after.
  PresetBackup? _preUpdateBackup;

  /// The raw copy taken before updating a pedal on older clone firmware,
  /// when its P01..P79 can be restored: the pedal's identity and the bytes.
  (String, Uint8List)? _preUpdateRaw;
  String? _presetTask;
  double? _presetFraction;
  String? _presetMessage;
  bool _presetError = false;

  @override
  void initState() {
    super.initState();
    final MidiBackend backend = widget.backend ?? MidiBackend.forPlatform();
    _updater = PedalUpdater(backend, log: _addLog);
    _presets = PresetService(backend);
    _lifecycle = AppLifecycleListener(onExitRequested: _onExitRequested);
    // Detection only sends the identity query, so it is safe to run unasked.
    WidgetsBinding.instance.addPostFrameCallback((_) => _detect());
  }

  // Async work outlives the page when the window closes mid-task.
  @override
  void setState(VoidCallback fn) {
    if (mounted) {
      super.setState(fn);
    }
  }

  @override
  void dispose() {
    _stopLive();
    _workspace.dispose();
    _lifecycle.dispose();
    super.dispose();
  }

  /// Closing the window mid-transfer is the easiest way to brick a pedal.
  Future<AppExitResponse> _onExitRequested() async {
    if (_stage != _Stage.updating && _presetTask == null) {
      if (_workspace.unsaved.isEmpty) {
        return AppExitResponse.exit;
      }
      return await _confirmDiscard('Close the app?')
          ? AppExitResponse.exit
          : AppExitResponse.cancel;
    }
    final bool? leave = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded),
        title: Text(
          _stage == _Stage.updating
              ? 'The pedal is being updated'
              : 'The app is busy with the pedal ($_presetTask)',
        ),
        content: Text(
          _stage == _Stage.updating
              ? 'Closing now can leave the pedal unusable. Wait until the app '
                    'says it is done.'
              : 'Closing now can leave a write half done. Wait until the app '
                    'says it is done.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Close anyway'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep it open'),
          ),
        ],
      ),
    );
    return leave == true ? AppExitResponse.exit : AppExitResponse.cancel;
  }

  /// True when there are no unsaved edits, or the user lets them go.
  Future<bool> _confirmDiscard(String title) async {
    final int n = _workspace.unsaved.length;
    if (n == 0) {
      return true;
    }
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(title),
        content: Text(
          '$n edited preset${n == 1 ? ' is' : 's are'} not written or saved. '
          'Write them to the pedal, or save them to a file, to keep them.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard my edits'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep editing'),
          ),
        ],
      ),
    );
    return go == true;
  }

  void _addLog(String line) {
    final String stamp = DateTime.now().toIso8601String().substring(11, 19);
    // The log is copied into public bug reports: no user name in paths.
    final String? home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    final String shown = home == null || home.isEmpty
        ? line
        : line.replaceAll(home, '~');
    if (mounted) {
      setState(() => _log.add('$stamp  $shown'));
    }
  }

  bool get _busy =>
      _liveClosing != null ||
      _stage == _Stage.updating ||
      _detecting ||
      _loadingPackage ||
      _presetTask != null;

  List<String> get _blockers => _package != null && _pedal != null
      ? _updater.blockers(_package!, _pedal!)
      : const <String>[];

  bool get _canUpdate =>
      !_busy && _package != null && _pedal != null && _blockers.isEmpty;

  // --- actions --------------------------------------------------------------

  Future<void> _openFile() async {
    final XFile? file = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(
          label: 'M-VAVE firmware',
          extensions: <String>['fwsc'],
          uniformTypeIdentifiers: <String>['public.data'],
        ),
      ],
    );
    if (file == null) {
      return;
    }
    await _loadPackage(() async {
      // The package is about 750 KB; anything past 4 MB is not it.
      if (await file.length() > 4 << 20) {
        throw const FormatException('the file is too large for a package');
      }
      return file.readAsBytes();
    }, file.name);
  }

  Future<void> _download() async {
    await _loadPackage(() async {
      _addLog('Downloading $officialFirmwareUrl');
      // The package is about 750 KB; anything past 4 MB is not it.
      final (int status, Uint8List body) = await sendCapped(
        http.Request('GET', Uri.parse(officialFirmwareUrl)),
        4 << 20,
      );
      if (status != 200) {
        throw HttpException('HTTP $status');
      }
      return body;
    }, 'M-VAVE download');
  }

  Future<void> _loadPackage(
    Future<List<int>> Function() read,
    String source,
  ) async {
    setState(() {
      _loadingPackage = true;
      _packageError = null;
    });
    try {
      final FirmwarePackage p = FirmwarePackage.parse(
        Uint8List.fromList(await read()),
      );
      _addLog('Package "${p.product}" from $source, sha256 ${p.sha256}');
      setState(() {
        _package = p;
        _packageSource = source;
      });
    } catch (e) {
      _addLog('Package rejected: $e');
      setState(() {
        _package = null;
        _packageError = '$e';
      });
    } finally {
      setState(() => _loadingPackage = false);
    }
  }

  Future<void> _detect() async {
    if (_busy) {
      return;
    }
    // Busy before the first await, so nothing else starts meanwhile.
    setState(() {
      _detecting = true;
      _pedal = null;
    });
    await _stopLive();
    try {
      final DetectedPedal? p = await _updater.detect();
      if (p == null) {
        _addLog('No pedal answered.');
      }
      // Another pedal (or new firmware) answered: what was read is not
      // what it holds. No answer at all changes nothing.
      if (p != null &&
          _workspace.onPedal != null &&
          p.identity != _workspace.onPedal!.identity) {
        _workspace.forgetPedal();
      }
      setState(() {
        _pedal = p;
        if (p != null && p.inLoader) {
          _section = 2;
        }
      });
    } catch (e) {
      _addLog('Detection failed: $e');
    } finally {
      setState(() {
        _detecting = false;
        _detectedOnce = true;
      });
      await _startLive();
    }
  }

  Future<void> _confirmAndUpdate() async {
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => ConfirmUpdateDialog(
        from: _pedal!.identity,
        to: _package!.product,
        rebrand: _pedal!.rebrand,
        family: _pedal!.family,
        official: _package!.officialName != null,
      ),
    );
    if (go != true || _busy) {
      return;
    }
    setState(() {
      _stage = _Stage.updating;
      _progress = null;
      _resultMessage = null;
      _preUpdateBackup = null;
      _preUpdateRaw = null;
    });
    await _stopLive();
    try {
      if (!_pedal!.inLoader) {
        setState(
          () => _progress = const UpdateProgress(UpdatePhase.backup, null),
        );
        try {
          final PresetBackup b = await _presets.backup(
            _pedal!,
            onProgress: (double f) => setState(
              () => _progress = UpdateProgress(UpdatePhase.backup, f),
            ),
          );
          final File copy = await PresetService.keepCopy(b);
          _addLog('Presets backed up to ${copy.path}');
          setState(() => _preUpdateBackup = b);
        } on UnknownPresetLayout catch (e) {
          // A rebrand on old firmware (PIXIE1 V0.07) keeps presets in another
          // layout; they cannot be restored on Pocket AMP firmware anyway.
          if (_pedal!.rebrand == null) {
            rethrow;
          }
          final File raw = await PresetService.keepRaw(
            _pedal!.identity,
            e.area,
          );
          final bool old = isOldPresetArea(e.area);
          _addLog(
            'Presets are not in the Pocket AMP layout (${e.message}); '
            'raw copy kept at ${raw.path}. '
            '${old ? 'P01-P79 can be restored after the update.' : 'They will not be restored.'}',
          );
          if (!mounted ||
              !await confirmUpdateWithoutBackup(
                context,
                raw.path,
                oldPresets: old,
              )) {
            _addLog('Update cancelled. Nothing was written.');
            setState(() => _stage = _Stage.idle);
            return;
          }
          _addLog('Continuing without a full preset backup.');
          if (old) {
            setState(() => _preUpdateRaw = (_pedal!.identity, e.area));
          }
        }
      }
      final String after = await _updater.update(
        _package!,
        _pedal!,
        (UpdateProgress p) => setState(() => _progress = p),
      );
      _workspace.forgetPedal();
      setState(() {
        _stage = _Stage.success;
        _resultMessage = 'The pedal restarted as $after.';
        _pedal = null;
      });
      await _detect();
    } catch (e) {
      _addLog('Update failed: $e');
      setState(() {
        _stage = _Stage.failed;
        _resultMessage = '$e';
        _pedal = null;
      });
    }
  }

  Future<void> _runPresetTask(
    String task,
    Future<String> Function() run,
  ) async {
    if (_busy) {
      return;
    }
    setState(() {
      _presetTask = task;
      _presetFraction = null;
      _presetMessage = null;
      _presetError = false;
    });
    await _stopLive();
    try {
      final String done = await run();
      _addLog(done);
      setState(() => _presetMessage = done);
    } catch (e) {
      _addLog('$task failed: $e');
      setState(() {
        _presetMessage = '$e';
        _presetError = true;
      });
    } finally {
      setState(() => _presetTask = null);
      await _startLive();
    }
  }

  /// Opens the live link when wanted and possible, and plays the selected
  /// preset as edited.
  Future<void> _startLive() async {
    final DetectedPedal? p = _pedal;
    if (!_wantLive ||
        _busy ||
        _workspace.live != null ||
        _liveOpening != null || // one open at a time
        p == null ||
        p.inLoader ||
        _workspace.onPedal == null ||
        _stage == _Stage.updating) {
      return;
    }
    final int generation = _liveGeneration;
    final Completer<void> opening = Completer<void>();
    _liveOpening = opening.future;
    try {
      final LiveLink link = await _presets.openLive(
        p,
        onError: (Object e) {
          _addLog('Live edit failed: $e');
          if (e is MidiPortGone) {
            // Unplugged while live: drop the link and the pedal, so nothing
            // keeps writing to a port that is gone.
            unawaited(_lostPedal());
            return;
          }
          if (mounted) {
            setState(() {
              _presetMessage = 'Live edit failed: $e';
              _presetError = true;
            });
          }
        },
      );
      if (generation != _liveGeneration || _stage == _Stage.updating) {
        await link.close();
      } else {
        _workspace.live = link;
        _workspace.showOnPedal();
      }
    } catch (e) {
      _addLog('Live editing not available: $e');
    } finally {
      opening.complete();
      _liveOpening = null;
    }
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _lostPedal() async {
    await _stopLive();
    if (mounted) {
      setState(() {
        _pedal = null;
        _presetMessage =
            'The pedal was disconnected. Edits stay here; connect it again '
            'and detect it to go on.';
        _presetError = true;
      });
    }
  }

  Future<void> _stopLive() async {
    _liveGeneration++;
    await _liveOpening;
    await _liveClosing;
    final LiveLink? l = _workspace.live;
    _workspace.live = null;
    if (l != null) {
      final Future<void> closing = l.close();
      _setClosing(closing);
      try {
        await closing;
      } finally {
        _setClosing(null);
      }
    }
  }

  void _setClosing(Future<void>? f) {
    _liveClosing = f;
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _setLive(bool on) async {
    _wantLive = on;
    on ? await _startLive() : await _stopLive();
    setState(() {});
  }

  Future<void> _readPresets() async {
    if (await _confirmDiscard('Read the presets again?')) {
      await _readPresetsNow();
    }
  }

  Future<void> _readPresetsNow() => _runPresetTask('Reading presets', () async {
    final PresetBackup b;
    try {
      b = await _presets.backup(
        _pedal!,
        onProgress: (double f) => setState(() => _presetFraction = f),
      );
    } on UnknownPresetLayout catch (e) {
      final File raw = await PresetService.keepRaw(_pedal!.identity, e.area);
      throw PresetIoException(
        'Presets are not in the Pocket AMP layout (${e.message}). '
        'Raw copy kept at ${raw.path}.',
      );
    }
    try {
      final (List<String> amp, List<String> cab) = await _presets.readNames(
        _pedal!,
      );
      _workspace
        ..ampNames = amp
        ..cabNames = cab;
    } catch (e) {
      _addLog('Model names not read: $e');
    }
    _workspace.load(
      b,
      'Read from ${_pedal!.identity} at '
      '${b.created.toLocal().toString().substring(11, 16)}',
      fromPedal: true,
    );
    return 'Read all 80 presets and their EQ.';
  });

  Future<void> _openPresetFile() async {
    if (!await _confirmDiscard('Open another file?')) {
      return;
    }
    final XFile? file = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(label: 'Preset backup', extensions: <String>['json']),
      ],
    );
    if (file == null) {
      return;
    }
    try {
      // A full backup is about 100 KB.
      if (await file.length() > 4 << 20) {
        throw const FormatException('the file is too large for a backup');
      }
      _workspace.load(
        PresetBackup.fromJson(await file.readAsString()),
        file.name,
      );
      setState(() => _presetMessage = null);
    } catch (e) {
      setState(() {
        _presetMessage = 'Not a valid backup: $e';
        _presetError = true;
      });
    }
  }

  Future<void> _savePresetFile() => _runPresetTask('Saving a file', () async {
    final PresetBackup b = _workspace.draft!;
    if (Platform.isAndroid) {
      // file_selector has no save dialog on Android: keep it with the backups.
      final File f = await PresetService.keepCopy(b);
      _workspace.saved();
      return 'Saved to ${f.path}.';
    }
    final FileSaveLocation? where = await getSaveLocation(
      suggestedName: b.suggestedFileName,
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(label: 'Preset backup', extensions: <String>['json']),
      ],
    );
    if (where == null) {
      return 'Not saved (no file chosen).';
    }
    await File(where.path).writeAsString(b.toJson());
    _workspace.saved();
    return 'Saved to ${where.path}.';
  });

  /// Backs up the pedal into the app's backup folder.
  Future<void> _backupNow() => _runPresetTask('Backing up', () async {
    final PresetBackup b = await _presets.backup(
      _pedal!,
      onProgress: (double f) => setState(() => _presetFraction = f),
    );
    final File f = await PresetService.keepCopy(b);
    return 'Backup kept at ${f.path}.';
  });

  Future<void> _readNames() => _runPresetTask('Reading names', () async {
    final (List<String> amp, List<String> cab) = await _presets.readNames(
      _pedal!,
    );
    _workspace
      ..ampNames = amp
      ..cabNames = cab;
    return 'Read the names of the 20 AMP and 20 CAB slots.';
  });

  Future<void> _replaceIr(int slot) async {
    final XFile? file = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(label: 'Impulse response', extensions: <String>['wav']),
      ],
    );
    if (file == null) {
      return;
    }
    final Uint8List pcm;
    try {
      if (await file.length() > 1 << 20) {
        throw const InvalidIrFile('the file is too large for a 2048-sample IR');
      }
      pcm = parseIrWav(await file.readAsBytes());
    } on Object catch (e) {
      if (e is! InvalidIrFile && e is! FileSystemException) {
        rethrow;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _presetMessage = '${file.name}: $e';
        _presetError = true;
      });
      return;
    }
    if (!mounted) {
      return;
    }
    final String? name = await confirmIrUpload(
      context,
      slot,
      _workspace.cabNames?[slot] ?? 'slot ${slot + 1}',
      file.name.replaceAll(RegExp(r'\.wav$', caseSensitive: false), ''),
    );
    if (name == null) {
      return;
    }
    await _runPresetTask('Sending the IR', () async {
      _workspace.cabNames = await _presets.uploadIr(
        _pedal!,
        slot,
        name,
        pcm,
        onProgress: (double f) => setState(() => _presetFraction = f),
      );
      return 'IR stored in CAB slot ${slot + 1} as "$name".';
    });
  }

  Future<void> _editBackup(PresetBackup b, String name) async {
    if (!await _confirmDiscard('Open this backup?')) {
      return;
    }
    _workspace.load(b, name);
    setState(() {
      _presetMessage = null;
      _section = 0;
    });
  }

  /// Writes a frozen copy of the draft, refusing if the pedal changed since
  /// it was read.
  Future<void> _writeDraft() => _restore(
    _workspace.draft!.copy(),
    'the editor',
    then: _workspace.written,
    expected: _workspace.onPedal,
  );

  Future<void> _restore(
    PresetBackup b,
    String from, {
    void Function(PresetBackup written)? then,
    PresetBackup? expected,
  }) async {
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(
          expected == null ? 'Restore presets?' : 'Write presets to the pedal?',
        ),
        content: Text(
          'Presets and EQ that differ from $from '
          '(${b.identity}, ${b.created.toLocal().toString().substring(0, 16)}) '
          'will be overwritten on the pedal. Presets that already match are '
          'left alone.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(expected == null ? 'Restore' : 'Write'),
          ),
        ],
      ),
    );
    if (go != true) {
      return;
    }
    await _runPresetTask('Restoring presets', () async {
      final PresetDiff d = await _presets.restore(
        _pedal!,
        b,
        onProgress: (String step, double f) => setState(() {
          _presetTask = step;
          _presetFraction = f;
        }),
        expected: expected,
      );
      if (then != null) {
        then(b);
      } else if (_workspace.onPedal != null) {
        _workspace.written(b);
      }
      final String kept = d.skippedEq.isEmpty
          ? ''
          : ' The EQ of ${d.skippedEq.map((int i) => 'P${i + 1}').join(', ')} '
                'was left as on the pedal: it is stored in a form this app '
                'cannot write.';
      return d.isEmpty
          ? 'Nothing to write: the pedal already matches.$kept'
          : 'Written and checked: $d.$kept';
    });
  }

  /// Restores P01..P79 from the raw copy [area] of a pedal that was on older
  /// clone firmware.
  Future<void> _restoreRaw(String identity, Uint8List area, String from) async {
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Restore presets from older firmware?'),
        content: Text(
          'P01 to P79 that differ from $from ($identity) will be overwritten '
          'on the pedal. P80 could not be read on that firmware and its EQ '
          'did not exist, so P80 and the EQ of every preset stay as they are.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (go != true) {
      return;
    }
    await _runPresetTask('Restoring presets', () async {
      final (PresetDiff d, PresetBackup b) = await _presets.restoreOld(
        _pedal!,
        identity,
        area,
        onProgress: (String step, double f) => setState(() {
          _presetTask = step;
          _presetFraction = f;
        }),
      );
      if (_workspace.onPedal != null) {
        _workspace.written(b);
      }
      return d.isEmpty
          ? 'Nothing to write: the pedal already matches.'
          : 'Written and checked: $d.';
    });
  }

  // --- view -----------------------------------------------------------------

  static const List<(IconData, IconData, String)> _sections =
      <(IconData, IconData, String)>[
        (Icons.tune_outlined, Icons.tune, 'Presets'),
        (Icons.speaker_outlined, Icons.speaker, 'Cabinets'),
        (Icons.system_update_alt_outlined, Icons.system_update_alt, 'Firmware'),
        (Icons.inventory_2_outlined, Icons.inventory_2, 'Backups'),
      ];

  void _go(int i) {
    // The update screen stays up until the pedal is written.
    if (_stage != _Stage.updating) {
      setState(() => _section = i);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool wide = MediaQuery.sizeOf(context).width >= 720;
    final Widget page = switch (_section) {
      0 => PresetsPage(
        workspace: _workspace,
        canUsePedal: _pedal != null && !_pedal!.inLoader,
        busy: _busy,
        task: _presetTask,
        fraction: _presetFraction,
        message: _presetMessage,
        messageIsError: _presetError,
        onRead: _readPresets,
        onOpen: _openPresetFile,
        onSave: _savePresetFile,
        onWrite: _writeDraft,
        liveOn: _workspace.live != null,
        onLive: _setLive,
      ),
      1 => CabinetsPage(
        names: _workspace.cabNames,
        canUsePedal: _pedal != null && !_pedal!.inLoader,
        irNeedsUsb: _pedal?.port.bluetooth ?? false,
        busy: _busy,
        task: _presetTask,
        fraction: _presetFraction,
        message: _presetMessage,
        messageIsError: _presetError,
        onReadNames: _readNames,
        onReplace: _replaceIr,
      ),
      2 => _firmwarePage(theme),
      _ => BackupsPage(
        list: PresetService.kept,
        canRestore: _pedal != null && !_pedal!.inLoader && !_busy,
        task: _presetTask,
        fraction: _presetFraction,
        message: _presetMessage,
        messageIsError: _presetError,
        onEdit: (PresetBackup b, String name) {
          if (!_busy) {
            _editBackup(b, name);
          }
        },
        onRestore: (PresetBackup b, String name) => _restore(b, name),
        onRestoreRaw: (File f) async {
          final String name = f.uri.pathSegments.last;
          final Uint8List area;
          try {
            if (await f.length() > 4 << 20) {
              throw const FileSystemException('too large for a raw copy');
            }
            area = await f.readAsBytes();
          } on FileSystemException catch (e) {
            setState(() {
              _presetMessage = 'Could not read $name: ${e.message}';
              _presetError = true;
            });
            return;
          }
          await _restoreRaw(PresetService.rawIdentity(name) ?? '?', area, name);
        },
        onSaveNew: _backupNow,
      ),
    };
    return Scaffold(
      appBar: _pedalBar(theme),
      body: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                NavigationRail(
                  selectedIndex: _section,
                  onDestinationSelected: _go,
                  labelType: NavigationRailLabelType.all,
                  destinations: <NavigationRailDestination>[
                    for (final (IconData off, IconData on, String label)
                        in _sections)
                      NavigationRailDestination(
                        icon: Icon(off),
                        selectedIcon: Icon(on),
                        label: Text(label),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: page),
              ],
            )
          : page,
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _section,
              onDestinationSelected: _go,
              destinations: <NavigationDestination>[
                for (final (IconData off, IconData on, String label)
                    in _sections)
                  NavigationDestination(
                    icon: Icon(off),
                    selectedIcon: Icon(on),
                    label: label,
                  ),
              ],
            ),
    );
  }

  /// Always on screen: which pedal is connected and a way to look again.
  PreferredSizeWidget _pedalBar(ThemeData theme) {
    final DetectedPedal? p = _pedal;
    final String title = p == null
        ? (_detecting ? 'Looking for the pedal…' : 'No pedal connected')
        : p.rebrand == null
        ? p.family
        : '${p.rebrand} (${p.family})';
    final String subtitle = p == null
        ? 'Connect it by USB (or pair it by Bluetooth) and close other MIDI apps'
        : p.port.bluetooth
        ? 'Bluetooth · presets only'
        : p.inLoader
        ? 'In update mode · ${p.port.name}'
        : 'Firmware ${p.version} · ${p.port.name}';
    return AppBar(
      backgroundColor: theme.colorScheme.surfaceContainer,
      titleSpacing: 16,
      title: Row(
        children: <Widget>[
          CircleAvatar(
            radius: 18,
            backgroundColor: p == null
                ? theme.colorScheme.surfaceContainerHighest
                : theme.colorScheme.primary,
            foregroundColor: p == null
                ? theme.colorScheme.onSurfaceVariant
                : theme.colorScheme.onPrimary,
            child: Icon(
              p == null
                  ? Icons.usb_off
                  : p.port.bluetooth
                  ? Icons.bluetooth
                  : Icons.usb,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
                Text(
                  subtitle,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: <Widget>[
        if (MediaQuery.sizeOf(context).width >= 720)
          FilledButton.tonalIcon(
            onPressed: _busy ? null : _detect,
            icon: _detecting
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            label: Text(p == null ? 'Detect pedal' : 'Detect again'),
          )
        else
          IconButton.filledTonal(
            tooltip: p == null ? 'Detect pedal' : 'Detect again',
            onPressed: _busy ? null : _detect,
            icon: const Icon(Icons.refresh),
          ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: 'Log',
          icon: Badge(
            isLabelVisible: _log.isNotEmpty,
            label: Text('${_log.length}'),
            child: const Icon(Icons.receipt_long_outlined),
          ),
          onPressed: () => showDialog<void>(
            context: context,
            builder: (BuildContext context) => Dialog(
              child: SizedBox(width: 680, child: _LogPanel(lines: _log)),
            ),
          ),
        ),
        IconButton(
          tooltip: 'About',
          icon: const Icon(Icons.info_outline),
          onPressed: () => showAboutDialog(
            context: context,
            applicationName: 'Pocket AMP Tools',
            applicationLegalese:
                'Community tool, not affiliated with M-VAVE.\n'
                'GPL-3.0. Update protocol from M-VAVE\'s FM1 Open '
                'project.',
          ),
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _firmwarePage(ThemeData theme) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            if (_stage == _Stage.updating)
              _ProgressCard(progress: _progress)
            else ...<Widget>[
              if (_stage == _Stage.success || _stage == _Stage.failed)
                _ResultCard(
                  success: _stage == _Stage.success,
                  message: _resultMessage ?? '',
                  onDismiss: () => setState(() => _stage = _Stage.idle),
                  action:
                      _stage == _Stage.success &&
                          (_preUpdateBackup != null || _preUpdateRaw != null) &&
                          _pedal != null &&
                          !_pedal!.inLoader &&
                          !_busy
                      ? FilledButton.icon(
                          icon: const Icon(Icons.history),
                          label: const Text(
                            'Restore my presets from before the update',
                          ),
                          onPressed: () => _preUpdateBackup != null
                              ? _restore(
                                  _preUpdateBackup!,
                                  'the backup taken before the update',
                                )
                              : _restoreRaw(
                                  _preUpdateRaw!.$1,
                                  _preUpdateRaw!.$2,
                                  'the raw copy taken before the update',
                                ),
                        )
                      : null,
                ),
              _firmwareCard(theme),
              const SizedBox(height: 12),
              _pedalCard(theme),
              const SizedBox(height: 12),
              const _WarningCard(),
              const SizedBox(height: 16),
              for (final String b in _blockers)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    b,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              if (_presetTask != null && _stage == _Stage.idle)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text('$_presetTask…'),
                ),
              FilledButton.icon(
                onPressed: _canUpdate ? _confirmAndUpdate : null,
                icon: const Icon(Icons.system_update_alt),
                label: Text(
                  _pedal?.inLoader == true
                      ? 'Resume update'
                      : 'Update firmware',
                ),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _firmwareCard(ThemeData theme) {
    final FirmwarePackage? p = _package;
    return _StepCard(
      number: 1,
      title: 'Firmware file',
      done: p != null,
      children: <Widget>[
        if (p != null) ...<Widget>[
          _InfoRow('Product', reportedFamilyOf(p.product)),
          _InfoRow('Version', p.version),
          _InfoRow('Source', _packageSource ?? ''),
          _InfoRow('SHA-256', '${p.sha256.substring(0, 16)}…'),
          _InfoRow('Package', p.officialName ?? 'not a known official package'),
          _InfoRow(
            'Loader',
            p.hasKnownLoader ? 'known, verified' : 'UNKNOWN (refused)',
          ),
          const SizedBox(height: 8),
        ] else if (_packageError != null) ...<Widget>[
          Text(
            'Not a valid package: $_packageError',
            style: TextStyle(color: theme.colorScheme.error),
          ),
          const SizedBox(height: 8),
        ] else
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              'Use the official .fwsc file from M-VAVE. Download it here or '
              'open one you already have.',
            ),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            FilledButton.tonalIcon(
              onPressed: _busy ? null : _download,
              icon: const Icon(Icons.cloud_download_outlined),
              label: const Text('Download from M-VAVE'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _openFile,
              icon: const Icon(Icons.folder_open),
              label: const Text('Open .fwsc file…'),
            ),
            if (_loadingPackage)
              const Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _pedalCard(ThemeData theme) {
    final DetectedPedal? p = _pedal;
    return _StepCard(
      number: 2,
      title: 'Pedal',
      done: p != null,
      children: <Widget>[
        if (p != null) ...<Widget>[
          _InfoRow(
            'Model',
            p.rebrand == null ? p.family : '${p.rebrand} (${p.family})',
          ),
          _InfoRow(
            'Installed',
            p.port.bluetooth
                ? 'not known over Bluetooth'
                : p.inLoader
                ? 'update mode'
                : p.version,
          ),
          _InfoRow('Port', p.port.name),
          if (p.inLoader)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'The pedal is waiting in update mode, probably from an '
                'interrupted update. Updating again will finish the job.',
                style: TextStyle(color: theme.colorScheme.tertiary),
              ),
            ),
        ] else
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _detectedOnce
                  ? 'No Pocket AMP found. Connect it with a USB data cable, '
                        'turn it on, close the M-VAVE app and try again.'
                  : 'Connect the pedal by USB, turn it on and close any other '
                        'app that uses MIDI.',
            ),
          ),
      ],
    );
  }
}

class _StepCard extends StatelessWidget {
  const _StepCard({
    required this.number,
    required this.title,
    required this.done,
    required this.children,
  });

  final int number;
  final String title;
  final bool done;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                CircleAvatar(
                  radius: 14,
                  backgroundColor: done
                      ? theme.colorScheme.primary
                      : theme.colorScheme.surfaceContainerHighest,
                  foregroundColor: done
                      ? theme.colorScheme.onPrimary
                      : theme.colorScheme.onSurfaceVariant,
                  child: done
                      ? const Icon(Icons.check, size: 16)
                      : Text('$number'),
                ),
                const SizedBox(width: 12),
                Text(title, style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}

class _WarningCard extends StatelessWidget {
  const _WarningCard();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: theme.colorScheme.onErrorContainer),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Before you update',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              SizedBox(height: 8),
              Text(
                '• A firmware update can overwrite some presets and their EQ. '
                'When it can read them, the app backs up all 80 first and offers '
                'to restore them when it is done.\n'
                '• Charge the battery and use a reliable USB data cable.\n'
                '• Do not unplug, turn off or let the computer sleep until the '
                'app says it is done (about 2 minutes).\n'
                '• Use at your own risk. This is a community tool, not '
                'affiliated with M-VAVE.',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.progress});
  final UpdateProgress? progress;

  static const List<(UpdatePhase, String)> _steps = <(UpdatePhase, String)>[
    (UpdatePhase.backup, 'Backing up your presets'),
    (UpdatePhase.preparing, 'Checking the pedal'),
    (UpdatePhase.loader, 'Sending the update loader'),
    (UpdatePhase.waitingLoader, 'Waiting for update mode'),
    (UpdatePhase.flash, 'Writing the firmware'),
    (UpdatePhase.rebooting, 'Waiting for the pedal to restart'),
  ];

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final UpdatePhase current = progress?.phase ?? UpdatePhase.preparing;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Updating…', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 4),
            Text(
              'Do not unplug or turn off the pedal.',
              style: TextStyle(
                color: theme.colorScheme.error,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            for (final (UpdatePhase phase, String label) in _steps)
              _phaseRow(theme, phase, label, current),
          ],
        ),
      ),
    );
  }

  Widget _phaseRow(
    ThemeData theme,
    UpdatePhase phase,
    String label,
    UpdatePhase current,
  ) {
    final bool done = phase.index < current.index;
    final bool active = phase == current;
    final double? fraction = active ? progress?.fraction : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                done
                    ? Icons.check_circle
                    : active
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 20,
                color: done || active
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outline,
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(label)),
              if (fraction != null) Text('${(fraction * 100).floor()}%'),
            ],
          ),
          if (active)
            Padding(
              padding: const EdgeInsets.only(left: 32, top: 6),
              child: LinearProgressIndicator(value: fraction),
            ),
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.success,
    required this.message,
    required this.onDismiss,
    this.action,
  });

  final bool success;
  final String message;
  final VoidCallback onDismiss;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color bg = success
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.errorContainer;
    final Color fg = success
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onErrorContainer;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        color: bg,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ListTile(
              leading: Icon(
                success ? Icons.check_circle : Icons.error_outline,
                color: fg,
              ),
              title: Text(
                success ? 'Update finished' : 'Update failed',
                style: TextStyle(color: fg, fontWeight: FontWeight.w600),
              ),
              subtitle: Text(message, style: TextStyle(color: fg)),
              trailing: IconButton(
                tooltip: 'Dismiss',
                icon: Icon(Icons.close, color: fg),
                onPressed: onDismiss,
              ),
            ),
            if (action != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(72, 0, 16, 16),
                child: action,
              ),
          ],
        ),
      ),
    );
  }
}

class ConfirmUpdateDialog extends StatefulWidget {
  const ConfirmUpdateDialog({
    super.key,
    required this.from,
    required this.to,
    required this.rebrand,
    required this.family,
    required this.official,
  });
  final String from;
  final String to;

  /// False for a package whose exact content this app does not know: it
  /// could be a newer official release, or something else wearing its name.
  final bool official;

  /// Set for another brand's unit (e.g. `PIXIE1`), which this turns into a
  /// [family]; that needs its own, explicit consent.
  final String? rebrand;
  final String family;

  @override
  State<ConfirmUpdateDialog> createState() => ConfirmUpdateDialogState();
}

class ConfirmUpdateDialogState extends State<ConfirmUpdateDialog> {
  bool _understood = false;
  bool _unknownUnderstood = false;
  bool _rebrandUnderstood = false;

  bool get _canGo =>
      _understood &&
      (widget.rebrand == null || _rebrandUnderstood) &&
      (widget.official || _unknownUnderstood);

  @override
  Widget build(BuildContext context) {
    final String? rebrand = widget.rebrand;
    return AlertDialog(
      scrollable: true,
      icon: const Icon(Icons.warning_amber_rounded),
      title: const Text('Write new firmware?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('${widget.from}  →  ${widget.to}'),
          const SizedBox(height: 12),
          const Text(
            'An interrupted update can leave the pedal unusable. Keep it '
            'connected and powered until the app says it is done.',
          ),
          if (rebrand != null) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              'This is a $rebrand, sold as a rebranded ${widget.family}. This '
              'writes the ${widget.family} firmware: afterwards the pedal '
              'reports itself as a ${widget.family}, and this app cannot put '
              'the $rebrand firmware back. '
              '${rebrandEvidence[rebrand] ?? 'No unit has been updated this way yet.'} '
              'If its hardware differs, the pedal may stop working.',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _rebrandUnderstood,
              onChanged: (bool? v) =>
                  setState(() => _rebrandUnderstood = v ?? false),
              title: Text(
                'Turn my $rebrand into a ${widget.family}. I accept it may '
                'brick the pedal.',
              ),
              controlAffinity: ListTileControlAffinity.leading,
            ),
          ],
          if (!widget.official) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              'This is not a firmware package this app knows. It may be a '
              'newer official release, or a modified file: only the update '
              'loader inside it was checked. Write it only if it came from '
              "M-VAVE's own site.",
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _unknownUnderstood,
              onChanged: (bool? v) =>
                  setState(() => _unknownUnderstood = v ?? false),
              title: const Text('I trust where this file came from.'),
              controlAffinity: ListTileControlAffinity.leading,
            ),
          ],
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _understood,
            onChanged: (bool? v) => setState(() => _understood = v ?? false),
            title: const Text('I backed up my presets and accept the risk.'),
            controlAffinity: ListTileControlAffinity.leading,
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _canGo ? () => Navigator.pop(context, true) : null,
          child: const Text('Update'),
        ),
      ],
    );
  }
}

class _LogPanel extends StatelessWidget {
  const _LogPanel({required this.lines});
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: true,
        title: const Text('Log'),
        subtitle: Text('${lines.length} log lines'),
        children: <Widget>[
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: lines.isEmpty
                  ? null
                  : () => Clipboard.setData(
                      ClipboardData(
                        text:
                            '${Platform.operatingSystem} '
                            '${Platform.operatingSystemVersion}\n'
                            '${lines.join('\n')}',
                      ),
                    ),
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy for a bug report'),
            ),
          ),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 240),
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SingleChildScrollView(
              reverse: true,
              child: SelectableText(
                lines.join('\n'),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Asks before updating a rebrand whose presets cannot be backed up; true
/// only when the user picks "Update without a backup".
Future<bool> confirmUpdateWithoutBackup(
  BuildContext context,
  String rawPath, {
  bool oldPresets = false,
}) async {
  final bool? go = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext context) => AlertDialog(
      icon: const Icon(Icons.warning_amber_rounded),
      title: Text(
        oldPresets
            ? 'Presets can only be backed up in part'
            : 'Presets cannot be backed up',
      ),
      content: Text(
        oldPresets
            ? 'This firmware keeps presets in an older layout. A raw copy was '
                  'saved to:\n$rawPath\n\n'
                  'After the update, P01 to P79 can be restored from it. P80 '
                  'cannot be read on this firmware and will be lost.\n\n'
                  'Nothing has been written to the pedal yet.'
            : "This pedal's presets are not in the Pocket AMP layout, so they "
                  'cannot be restored on the new firmware. A raw copy was '
                  'saved to:\n$rawPath\n\n'
                  'Nothing has been written to the pedal yet. If you continue, '
                  'its current presets may be lost for good.',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Update without a backup'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
  return go == true;
}
