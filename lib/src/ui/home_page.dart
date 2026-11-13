// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'dart:ui' show AppExitResponse;

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../assistant/agent.dart';
import '../assistant/assistant.dart';
import '../firmware_package.dart';
import '../library/library.dart';
import '../midi/midi_backend.dart';
import '../pedal_updater.dart';
import '../presets/live_link.dart';
import '../presets/preset_backup.dart';
import '../presets/preset_service.dart';
import '../presets/preset_session.dart';
import '../net/capped_http.dart';
import '../presets/ir_upload.dart';
import '../presets/nam_file.dart';
import '../telemetry.dart';
import 'assistant_panel.dart';
import 'assistant_tools.dart';
import 'backups_page.dart';
import 'library_page.dart';
import 'onboarding.dart';
import 'presets_page.dart';
import 'visuals.dart';

/// Official download link published on M-VAVE's downloads page. The file is
/// fetched from M-VAVE's own server; this app never redistributes it.
const String officialFirmwareUrl =
    'https://yms-file-store.oss-cn-hongkong.aliyuncs.com/software/firmware/Pocket%20AMP.fwsc';

enum _Stage { idle, updating, success, failed }

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.backend, this.libraryRoot});

  /// Injected in tests; the platform backend otherwise.
  final MidiBackend? backend;

  /// Injected in tests; `Documents/Pocket AMP Tools/Library` otherwise.
  final Directory? libraryRoot;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> implements AssistantHost {
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

  /// Watches the port list so plugging or unplugging the pedal needs no click.
  Timer? _portWatch;
  Set<String>? _lastPorts;

  _Stage _stage = _Stage.idle;
  UpdateProgress? _progress;
  String? _resultMessage;

  final PresetWorkspace _workspace = PresetWorkspace();

  /// 0 presets, 1 library, 2 firmware, 3 backups.
  int _section = 0;

  Library? _library;
  LibraryKind _libKind = LibraryKind.amp;

  /// Null until read for [_libKind].
  List<LibraryItem>? _libItems;
  Map<int, String> _libLinks = <int, String>{};

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
    _workspace.details.open();
    // Detection only sends the identity query, so it is safe to run unasked.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      unawaited(_detect());
      _portWatch = Timer.periodic(const Duration(seconds: 2), (_) {
        unawaited(_watchPorts(backend));
      });
      if (!await onboardingSeen()) {
        if (mounted) {
          await showOnboarding(context);
        }
      } else if (Telemetry.available && await Telemetry.choice() == null) {
        await _askReports();
      }
    });
  }

  // Async work outlives the page when the window closes mid-task.
  @override
  void setState(VoidCallback fn) {
    if (mounted) {
      super.setState(fn);
    }
  }

  // --- assistant ------------------------------------------------------------

  late final AssistantAgent _agent = AssistantAgent(
    tools: assistantTools(this),
    settings: AssistantSettings.load,
  );

  /// The conversation stays when the panel closes.
  bool _assistantOpen = false;

  @override
  PresetWorkspace get workspace => _workspace;

  @override
  String? get pedal {
    final DetectedPedal? p = _pedal;
    if (p == null) {
      return null;
    }
    return '${p.rebrand}, firmware ${p.version}, '
        '${p.port.bluetooth ? 'Bluetooth (presets only, no file uploads)' : 'USB'}'
        '${p.inLoader ? ', in update mode' : ''}';
  }

  @override
  bool get canUpload =>
      _pedal != null && !_pedal!.inLoader && !_pedal!.port.bluetooth && !_busy;

  @override
  bool get canWrite =>
      _pedal != null &&
      !_pedal!.inLoader &&
      !_busy &&
      _workspace.draft != null &&
      _workspace.onPedal != null;

  @override
  Future<List<LibraryItem>> library(LibraryKind kind) async =>
      (await _lib()).list(kind);

  @override
  Future<Map<int, String>> links(LibraryKind kind) async =>
      (await _lib()).links(kind);

  @override
  Future<String> uploadToSlot(LibraryItem item, int slot, String name) async {
    final String? done = await _uploadNow(item, slot, name);
    return done ??
        (throw ToolError(_presetMessage ?? 'Another task is running.'));
  }

  @override
  Future<String> writePresets(PresetBackup presets) async {
    final String? done = await _restoreNow(
      presets,
      then: _workspace.written,
      expected: _workspace.onPedal,
    );
    return done ??
        (throw ToolError(_presetMessage ?? 'Another task is running.'));
  }

  @override
  void dispose() {
    _agent.stop();
    _agent.dispose();
    _portWatch?.cancel();
    _stopLive();
    _workspace.dispose();
    _lifecycle.dispose();
    super.dispose();
  }

  /// Closing the window mid-transfer is the easiest way to brick a pedal.
  Future<AppExitResponse> _onExitRequested() async {
    // A name or rating typed just before closing is still being written.
    await _workspace.details.saved;
    if (!mounted) {
      return AppExitResponse.exit;
    }
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
    final String shown = Telemetry.scrub(line)!;
    Telemetry.log(shown);
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

  /// Asks whether crash and update reports may be sent, and keeps the answer.
  Future<void> _askReports() async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Send error reports?'),
        content: const Text(reportsExplained),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Don't send"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(Telemetry.on ? 'Keep sending' : 'Send reports'),
          ),
        ],
      ),
    );
    if (yes != null) {
      await Telemetry.choose(yes);
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
        _workspace.pedalGone();
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
      // Read the pedal on its own, unless a read or an opened file is shown.
      final DetectedPedal? p = _pedal;
      if (p != null &&
          !p.inLoader &&
          _workspace.onPedal == null &&
          _workspace.draft == null) {
        await _readPresetsNow(); // restarts the live link when done
      } else {
        await _startLive();
      }
    }
  }

  /// Detects again when a port appears while no pedal is known, or when the
  /// known pedal's port goes away. Listing ports opens none of them.
  Future<void> _watchPorts(MidiBackend backend) async {
    if (_busy) {
      _lastPorts = null; // an update reboots the pedal: start over after it
      return;
    }
    final Set<String> now;
    try {
      now = <String>{
        for (final MidiPortRef p in await backend.listPorts())
          '${p.id}|${p.name}',
      };
    } catch (_) {
      return;
    }
    final Set<String>? before = _lastPorts;
    _lastPorts = now;
    if (before == null || _busy || !mounted) {
      return;
    }
    final DetectedPedal? p = _pedal;
    final bool changed = p == null
        ? now.difference(before).isNotEmpty
        : !now.contains('${p.port.id}|${p.port.name}');
    if (changed) {
      _addLog(
        p == null
            ? 'New MIDI port, looking for the pedal.'
            : 'Pedal port gone.',
      );
      await _detect();
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
      Telemetry.update(
        from: _pedal!.identity,
        to: _package!.product,
        after: after,
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
      Telemetry.update(
        from: _pedal?.identity ?? '?',
        to: _package?.product ?? '?',
        error: e,
      );
      setState(() {
        _stage = _Stage.failed;
        _resultMessage = '$e';
        _pedal = null;
      });
    }
  }

  /// Runs a pedal task with the live link closed; returns what was done,
  /// or null when it failed (the error is in [_presetMessage]) or another
  /// task was running.
  Future<String?> _runPresetTask(
    String task,
    Future<String> Function() run,
  ) async {
    if (_busy) {
      return null;
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
      // Success is said and gone; only errors stay on the page.
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(done)));
      }
      return done;
    } catch (e) {
      _addLog('$task failed: $e');
      setState(() {
        _presetMessage = '$e';
        _presetError = true;
      });
      return null;
    } finally {
      setState(() => _presetTask = null);
      await _startLive();
    }
  }

  /// Opens the live link when possible, and plays the selected preset as
  /// edited. As in M-EFCS, edits always play on a connected pedal; the link
  /// is closed around every other pedal operation.
  Future<void> _startLive() async {
    final DetectedPedal? p = _pedal;
    if (_busy ||
        _workspace.live != null ||
        _liveOpening != null || // one open at a time
        p == null ||
        p.inLoader ||
        _workspace.onPedal == null ||
        _workspace.onPedal!.oldLayout || // never tested writing to it
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

  Future<void> _readPresets() async {
    if (await _confirmDiscard('Read the presets again?')) {
      await _readPresetsNow();
    }
  }

  Future<void> _readPresetsNow() => _runPresetTask('Reading presets', () async {
    PresetBackup b;
    try {
      b = await _presets.backup(
        _pedal!,
        onProgress: (double f) => setState(() => _presetFraction = f),
      );
    } on UnknownPresetLayout catch (e) {
      final File raw = await PresetService.keepRaw(_pedal!.identity, e.area);
      if (isOldPresetArea(e.area)) {
        b = PresetBackup.oldLayout(_pedal!.identity, e.area);
        _workspace.load(
          b,
          'Read from ${_pedal!.identity} at '
          '${b.created.toLocal().toString().substring(11, 16)}',
          fromPedal: true,
        );
        return 'Read P01-P79. This firmware has no EQ and cannot read P80, '
            'so both are left out; its presets are only shown, not edited. '
            'Raw copy kept at ${raw.path}.';
      }
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

  // --- library --------------------------------------------------------------

  Future<Library> _lib() async => _library ??= Library(
    widget.libraryRoot ??
        Directory(
          '${(await getApplicationDocumentsDirectory()).path}'
          '${Platform.pathSeparator}Pocket AMP Tools'
          '${Platform.pathSeparator}Library',
        ),
  );

  Future<void> _loadLibrary() async {
    final LibraryKind k = _libKind;
    try {
      final Library lib = await _lib();
      final List<LibraryItem> items = await lib.list(k);
      final Map<int, String> links = await lib.links(k);
      if (k == _libKind) {
        setState(() {
          _libItems = items;
          _libLinks = links;
        });
      }
    } on Object catch (e) {
      if (e is! FileSystemException && e is! MissingPluginException) {
        rethrow;
      }
      setState(() {
        _libItems = <LibraryItem>[];
        _presetMessage = 'The library folder cannot be read: $e';
        _presetError = true;
      });
    }
  }

  void _setLibKind(LibraryKind k) {
    setState(() {
      _libKind = k;
      _libItems = null;
      _libLinks = <int, String>{};
      _presetMessage = null;
    });
    _loadLibrary();
  }

  void _libError(Object e) => setState(() {
    _presetMessage = '$e';
    _presetError = true;
  });

  Future<void> _importToLibrary() async {
    final LibraryKind k = _libKind;
    final List<XFile> files = await openFiles(
      acceptedTypeGroups: <XTypeGroup>[
        if (k == LibraryKind.amp)
          const XTypeGroup(
            label: 'NAM capture (A2)',
            extensions: <String>['nam'],
          )
        else
          const XTypeGroup(
            label: 'Impulse response',
            extensions: <String>['wav'],
          ),
      ],
    );
    if (files.isEmpty) {
      return;
    }
    final Library lib = await _lib();
    int added = 0;
    final List<String> failed = <String>[];
    for (final XFile f in files) {
      try {
        // An A2 file with every size is a few hundred KB; an IR, 6 KB.
        if (await f.length() > 16 << 20) {
          throw const LibraryException('the file is too large');
        }
        await lib.import(k, f.name, await f.readAsBytes());
        added++;
      } on Object catch (e) {
        if (e is! InvalidNamFile &&
            e is! InvalidIrFile &&
            e is! LibraryException &&
            e is! FileSystemException) {
          rethrow;
        }
        failed.add('${f.name}: $e');
      }
    }
    setState(() {
      _presetMessage = <String>[
        if (added > 0)
          'Added $added file${added == 1 ? '' : 's'} to the library.',
        ...failed,
      ].join('\n');
      _presetError = failed.isNotEmpty;
    });
    await _loadLibrary();
  }

  Future<void> _renameInLibrary(LibraryItem it) async {
    final String? name = await askRename(context, it.name);
    if (name == null) {
      return;
    }
    try {
      await (await _lib()).rename(it, name);
    } on Object catch (e) {
      if (e is! LibraryException && e is! FileSystemException) {
        rethrow;
      }
      _libError(e);
    }
    await _loadLibrary();
  }

  Future<void> _deleteFromLibrary(LibraryItem it) async {
    if (!await confirmDelete(context, it.name)) {
      return;
    }
    try {
      await (await _lib()).delete(it);
    } on FileSystemException catch (e) {
      _libError(e);
    }
    await _loadLibrary();
  }

  List<String>? _namesOf(LibraryKind k) =>
      k == LibraryKind.amp ? _workspace.ampNames : _workspace.cabNames;

  Future<void> _sendItem(LibraryItem it) async {
    final List<String>? names = _namesOf(it.kind);
    if (names == null) {
      return;
    }
    final int? slot = await chooseSlot(
      context,
      it.kind == LibraryKind.amp ? 'AMP' : 'CAB',
      it.name,
      names,
      _libLinks,
    );
    if (slot != null) {
      await _sendToSlot(it, slot);
    }
  }

  Future<void> _loadSlot(int slot) async {
    final List<LibraryItem>? items = _libItems;
    if (items == null || items.isEmpty) {
      return;
    }
    final LibraryItem? it = await chooseItem(
      context,
      _libKind == LibraryKind.amp ? 'AMP' : 'CAB',
      slot,
      items,
    );
    if (it != null) {
      await _sendToSlot(it, slot);
    }
  }

  Future<void> _sendToSlot(LibraryItem it, int slot) async {
    final bool amp = it.kind == LibraryKind.amp;
    final Uint8List bytes;
    try {
      bytes = await it.file.readAsBytes();
      Library.check(it.kind, bytes); // the file may have changed on disk
    } on Object catch (e) {
      if (e is! InvalidNamFile &&
          e is! InvalidIrFile &&
          e is! FileSystemException) {
        rethrow;
      }
      _libError('${it.name}: $e');
      return;
    }
    if (!mounted) {
      return;
    }
    final String? name = await confirmSlotUpload(
      context,
      slot,
      _namesOf(it.kind)?[slot] ?? 'slot ${slot + 1}',
      it.name,
      block: amp ? 'AMP' : 'CAB',
      what: amp ? 'models' : 'IRs',
      plays: amp ? 'model' : 'IR',
    );
    if (name == null) {
      return;
    }
    await _uploadNow(it, slot, name, bytes);
  }

  /// Sends [it] to slot [slot] as [name], already confirmed; returns what
  /// was done, or null when it failed (the error is in [_presetMessage]).
  Future<String?> _uploadNow(
    LibraryItem it,
    int slot,
    String name, [
    Uint8List? checked,
  ]) async {
    final bool amp = it.kind == LibraryKind.amp;
    final Uint8List bytes;
    if (checked != null) {
      bytes = checked;
    } else {
      bytes = await it.file.readAsBytes();
      Library.check(it.kind, bytes); // the file may have changed on disk
    }
    final String? done = await _runPresetTask(
      amp ? 'Sending the model' : 'Sending the IR',
      () async {
        void progress(double f) => setState(() => _presetFraction = f);
        if (amp) {
          _workspace.ampNames = await _presets.uploadAmp(
            _pedal!,
            slot,
            namFileToImage(utf8.decode(bytes), name),
            onProgress: progress,
          );
        } else {
          _workspace.cabNames = await _presets.uploadIr(
            _pedal!,
            slot,
            name,
            parseIrWav(bytes),
            onProgress: progress,
          );
        }
        await (await _lib()).link(it.kind, slot, it);
        return '"${it.name}" stored in ${amp ? 'AMP' : 'CAB'} slot ${slot + 1} '
            'as "$name".';
      },
    );
    await _loadLibrary();
    return done;
  }

  Future<void> _editBackup(PresetBackup b, String name) async {
    if (!await _confirmDiscard('Open this backup?')) {
      return;
    }
    _workspace.load(b, name, fromBackup: true);
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
    await _restoreNow(b, then: then, expected: expected);
  }

  /// Writes [b], already confirmed; returns what was done, or null when it
  /// failed (the error is in [_presetMessage]).
  Future<String?> _restoreNow(
    PresetBackup b, {
    void Function(PresetBackup written)? then,
    PresetBackup? expected,
  }) => _runPresetTask('Restoring presets', () async {
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
        (Icons.library_music_outlined, Icons.library_music, 'Library'),
        (Icons.system_update_alt_outlined, Icons.system_update_alt, 'Firmware'),
        (Icons.inventory_2_outlined, Icons.inventory_2, 'Backups'),
      ];

  void _go(int i) {
    // The update screen stays up until the pedal is written.
    if (_stage != _Stage.updating) {
      setState(() => _section = i);
      if (i == 1 && _libItems == null) {
        _loadLibrary();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // Material 3 window classes: a rail from medium (600), and the assistant
    // beside the editor only from expanded (840), where the editor still fits.
    final double windowWidth = MediaQuery.sizeOf(context).width;
    final bool wide = windowWidth >= 600;
    final bool besideEditor = windowWidth >= 840;
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
      ),
      1 => LibraryPage(
        kind: _libKind,
        onKind: _setLibKind,
        items: _libItems,
        links: _libLinks,
        names: _namesOf(_libKind),
        canUsePedal: _pedal != null && !_pedal!.inLoader,
        needsUsb: _pedal?.port.bluetooth ?? false,
        busy: _busy,
        task: _presetTask,
        fraction: _presetFraction,
        message: _presetMessage,
        messageIsError: _presetError,
        onReadNames: _readNames,
        onImport: _importToLibrary,
        onRename: _renameInLibrary,
        onDelete: _deleteFromLibrary,
        onSendItem: _sendItem,
        onLoadSlot: _loadSlot,
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
    // The assistant sits beside the presets editor; on a narrow window it
    // takes the page while open.
    final bool assistant = _assistantOpen && _section == 0;
    final Widget panel = AssistantPanel(
      agent: _agent,
      onClose: () => setState(() => _assistantOpen = false),
    );
    final Widget body = !assistant
        ? page
        : besideEditor
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(child: page),
              const VerticalDivider(width: 1),
              SizedBox(width: 380, child: panel),
            ],
          )
        : panel;
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
                Expanded(child: body),
              ],
            )
          : body,
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
    final bool compact = MediaQuery.sizeOf(context).width < 600;
    final String detectLabel = p == null ? 'Detect pedal' : 'Detect again';
    final String title = p == null
        ? (_detecting ? 'Looking for the pedal…' : 'No pedal connected')
        : p.rebrand == null
        ? p.family
        : '${p.rebrand} (${p.family})';
    final String subtitle = p == null
        ? 'Connect it by USB (or pair it by Bluetooth) and close other MIDI apps'
        : p.port.bluetooth
        ? 'Bluetooth · presets only'
        : p.presetsOnly
        ? 'Firmware ${p.version} · presets only'
        : p.inLoader
        ? 'In update mode'
        : 'Firmware ${p.version}';
    return AppBar(
      titleSpacing: 16,
      title: Row(
        children: <Widget>[
          _StatusLogo(
            icon: _detecting
                ? Icons.search
                : p == null
                ? Icons.usb_off
                : p.port.bluetooth
                ? Icons.bluetooth
                : p.inLoader
                ? Icons.system_update_alt
                : Icons.check,
            color: p == null
                ? theme.colorScheme.outline
                : p.inLoader
                ? theme.colorScheme.tertiary
                : theme.colorScheme.primary,
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
        if (_section == 0)
          ListenableBuilder(
            listenable: _workspace,
            builder: (BuildContext context, _) => IconButton(
              tooltip: _assistantOpen ? 'Hide the assistant' : 'Assistant',
              isSelected: _assistantOpen,
              icon: const Icon(Icons.auto_awesome),
              onPressed: () => setState(() => _assistantOpen = !_assistantOpen),
            ),
          ),
        // Plugging and unplugging are caught on their own; this is the retry.
        if (!compact) ...<Widget>[
          IconButton(
            tooltip: detectLabel,
            onPressed: _busy ? null : _detect,
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 4),
        ],
        if (Telemetry.available)
          IconButton(
            tooltip: 'Error reports',
            icon: const Icon(Icons.bug_report_outlined),
            onPressed: _askReports,
          ),
        PresetsMenu(
          workspace: _workspace,
          busy: _busy,
          canUsePedal: p != null && !p.inLoader,
          onRead: _readPresets,
          onOpen: _openPresetFile,
          onSave: _savePresetFile,
          log: _log,
          // On a phone the pedal's name needs the room.
          appBarItems: compact
              ? <Widget>[
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.refresh),
                    onPressed: _busy ? null : _detect,
                    child: Text(detectLabel),
                  ),
                ]
              : const <Widget>[],
          onAbout: () => showAboutDialog(
            context: context,
            applicationName: 'Pocket AMP Tools',
            applicationLegalese:
                'Community tool, not affiliated with M-VAVE.\n'
                'GPL-3.0. Update protocol from M-VAVE\'s FM1 Open '
                'project.',
          ),
          presetActions: _section == 0,
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
              if (_package != null &&
                  _pedal != null &&
                  !_pedal!.inLoader &&
                  !_pedal!.port.bluetooth) ...<Widget>[
                _VersionBanner(from: _pedal!.version, to: _package!.version),
                const SizedBox(height: 12),
              ],
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
          _InfoRow(
            'Product',
            reportedFamilyOf(p.product),
            Icons.category_outlined,
          ),
          _InfoRow('Version', p.version, Icons.new_releases_outlined),
          _InfoRow('Source', _packageSource ?? '', Icons.cloud_done_outlined),
          _InfoRow(
            'SHA-256',
            '${p.sha256.substring(0, 16)}…',
            Icons.fingerprint,
          ),
          _InfoRow(
            'Package',
            p.officialName ?? 'not a known official package',
            p.officialName != null
                ? Icons.verified_outlined
                : Icons.help_outline,
          ),
          _InfoRow(
            'Loader',
            p.hasKnownLoader ? 'known, verified' : 'UNKNOWN (refused)',
            p.hasKnownLoader
                ? Icons.verified_user_outlined
                : Icons.gpp_bad_outlined,
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
            padding: EdgeInsets.only(bottom: 12),
            child: Row(
              children: <Widget>[
                IconBadge(Icons.cloud_download_outlined),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Use the official .fwsc file from M-VAVE. Download it '
                    'here or open one you already have.',
                  ),
                ),
              ],
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
            Icons.speaker_outlined,
          ),
          _InfoRow(
            'Installed',
            p.port.bluetooth
                ? 'not known over Bluetooth'
                : p.inLoader
                ? 'update mode'
                : p.version,
            Icons.memory,
          ),
          _InfoRow(
            'Port',
            p.port.name,
            p.port.bluetooth ? Icons.bluetooth : Icons.usb,
          ),
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
            child: Row(
              children: <Widget>[
                const IconBadge(Icons.usb_off),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _detectedOnce
                        ? 'No Pocket AMP found. Connect it with a USB data cable, '
                              'turn it on, close the M-VAVE app and try again.'
                        : 'Connect the pedal by USB, turn it on and close any other '
                              'app that uses MIDI.',
                  ),
                ),
              ],
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
  const _InfoRow(this.label, this.value, this.icon);
  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 10, top: 1),
            child: Icon(icon, size: 18, color: theme.colorScheme.primary),
          ),
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

  static const List<(IconData, String)> _points = <(IconData, String)>[
    (
      Icons.save_outlined,
      'A firmware update can overwrite some presets and their EQ. When it can '
          'read them, the app backs up all 80 first and offers to restore them '
          'when it is done.',
    ),
    (
      Icons.battery_charging_full,
      'Charge the battery and use a reliable USB data cable.',
    ),
    (
      Icons.power_off_outlined,
      'Do not unplug, turn off or let the computer sleep until the app says '
          'it is done (about 2 minutes).',
    ),
    (
      Icons.info_outline,
      'Use at your own risk. This is a community tool, not affiliated with '
          'M-VAVE.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color on = theme.colorScheme.onErrorContainer;
    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: on),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(Icons.warning_amber_rounded, color: on),
                  const SizedBox(width: 8),
                  const Text(
                    'Before you update',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              for (final (IconData icon, String text) in _points)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(icon, size: 18, color: on),
                      const SizedBox(width: 10),
                      Expanded(child: Text(text)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The app logo with a badge for the pedal's state, at the top left.
class _StatusLogo extends StatelessWidget {
  const _StatusLogo({required this.icon, required this.color});
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final ColorScheme c = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: 44,
      child: Stack(
        children: <Widget>[
          Image.asset('assets/icon/app_icon.png', width: 40, height: 40),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: c.surface, width: 2),
              ),
              child: Icon(icon, size: 12, color: c.surface),
            ),
          ),
        ],
      ),
    );
  }
}

/// The version change an update makes, shown above the steps.
class _VersionBanner extends StatelessWidget {
  const _VersionBanner({required this.from, required this.to});
  final String from;
  final String to;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme c = theme.colorScheme;
    return Card(
      color: c.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: <Widget>[
            const IconBadge(Icons.system_update_alt, size: 56, strong: true),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    from == to ? 'Already on this version' : 'Update ready',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: c.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 4),
                  // One text, so each version is still written only once on
                  // screen (the pedal card names the installed one).
                  Text.rich(
                    TextSpan(
                      children: <InlineSpan>[
                        TextSpan(text: from),
                        WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Icon(
                              Icons.arrow_forward,
                              size: 28,
                              color: c.onPrimaryContainer,
                            ),
                          ),
                        ),
                        TextSpan(
                          text: to,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                    semanticsLabel: 'From version $from to $to',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      color: c.onPrimaryContainer,
                    ),
                  ),
                ],
              ),
            ),
          ],
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
