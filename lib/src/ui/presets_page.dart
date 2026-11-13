// SPDX-License-Identifier: GPL-3.0-only

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../presets/block_models.dart';
import '../presets/live_link.dart';
import '../presets/mefcs.dart';
import '../presets/preset_backup.dart';
import '../presets/preset_meta.dart';
import 'preset_meta_widgets.dart';
import 'settings_page.dart';
import 'visuals.dart';

/// The bank being edited and the bank last seen on the pedal, kept while the
/// user moves between sections.
class PresetWorkspace extends ChangeNotifier {
  /// What the user wrote about each slot; kept by the app, not the pedal.
  final PresetDetails details = PresetDetails();

  @override
  void dispose() {
    details.dispose();
    super.dispose();
  }

  /// Last read from, or written to, the pedal. Null until presets are read.
  PresetBackup? onPedal;

  /// What the editor shows and changes.
  PresetBackup? draft;

  /// Where [draft] came from, for the header.
  String? source;

  /// [draft] is one of the app's backups, not what the pedal holds, until
  /// it is written or discarded.
  bool fromBackup = false;

  /// [draft] holds what was read from (or written to) the pedal, not a
  /// file or backup.
  bool _fromPedal = false;
  int selected = 0;

  /// The block whose card is open, as in M-EFCS: an index into
  /// [blockNames], or [eqBlock] for the EQ. It stays open across presets.
  int openBlock = 1;
  static final int eqBlock = blockNames.length;

  void open(int block) {
    openBlock = block;
    notifyListeners();
  }

  /// Set while the edits are played on the pedal as they are made.
  LiveLink? live;

  /// AMP and CAB names read from the pedal, as stored.
  List<String>? ampNames;
  List<String>? cabNames;

  /// The model's name: from the pedal for AMP and CAB when read (user
  /// uploads replace them), from the V1.05 list otherwise.
  String modelLabel(String block, int model) {
    final List<String>? fromPedal = switch (block) {
      'AMP' => ampNames,
      'CAB' => cabNames,
      _ => null,
    };
    final String? known = modelName(block, model);
    if (fromPedal == null || model >= fromPedal.length) {
      return known ?? 'Model ${model + 1}';
    }
    final String raw = fromPedal[model];
    if (model == 0 && raw.isNotEmpty) {
      // The pedal overwrites the first character of the first name.
      return known != null && raw.substring(1) == known.substring(1)
          ? known
          : '?${raw.substring(1)}';
    }
    return raw;
  }

  void showOnPedal() {
    final PresetBackup? d = draft;
    if (live != null && d != null) {
      live!.show(selected, d.preset(selected));
    }
  }

  /// Changes a model. Played live, the pedal resets the block's knobs to the
  /// new model's defaults, and the draft takes them.
  Future<void> changeModel(int id, int block, int model) async {
    final PresetBackup d = draft!..setModel(id, block, model);
    notifyListeners();
    final Uint8List? body = await live?.model(block, model);
    // Only if the same draft is still open on the same preset.
    if (body != null && identical(draft, d) && selected == id) {
      for (int k = 0; k < 6; k++) {
        final int at = 20 + block * 12 + k * 2;
        draft!.setKnob(id, block, k, body[at] | (body[at + 1] << 8));
      }
      notifyListeners();
    }
  }

  /// What [draft] was last loaded from or written to: edits are counted
  /// against it, so they are guarded even with no pedal read.
  PresetBackup? _base;

  /// Presets (and their EQ) edited since the draft was loaded or written.
  Set<int> get unsaved {
    final PresetBackup? d = draft;
    final PresetBackup? b = _base;
    if (d == null || b == null) {
      return const <int>{};
    }
    final PresetDiff diff = PresetDiff.between(d, b);
    return <int>{...diff.presets, ...diff.eq};
  }

  void load(
    PresetBackup b,
    String from, {
    bool fromPedal = false,
    bool fromBackup = false,
  }) {
    this.fromBackup = fromBackup;
    _fromPedal = fromPedal;
    _base = b.copy();
    if (fromPedal) {
      onPedal = b;
    }
    draft = b.copy();
    source = from;
    if (b.oldLayout) {
      selected = selected.clamp(0, b.usableCount - 1);
      if (openBlock == eqBlock) {
        openBlock = 1;
      }
    }
    showOnPedal();
    notifyListeners();
  }

  /// Slots whose preset or EQ differ from the pedal; empty without a read.
  Set<int> get changed {
    final PresetBackup? d = draft;
    final PresetBackup? p = onPedal;
    if (d == null || p == null) {
      return const <int>{};
    }
    final PresetDiff diff = PresetDiff.between(d, p);
    return <int>{...diff.presets, ...diff.eq};
  }

  void edited() => notifyListeners();

  void select(int id) {
    selected = id;
    showOnPedal();
    notifyListeners();
  }

  /// The draft was saved to a file, so leaving now loses nothing.
  void saved() {
    _base = draft?.copy();
    notifyListeners();
  }

  void discard() {
    fromBackup = false;
    _fromPedal = true;
    draft = onPedal!.copy();
    _base = onPedal!.copy();
    showOnPedal();
    notifyListeners();
  }

  /// [b] is now what the pedal holds. The pedal keeps its own identity,
  /// whatever file the presets came from.
  void written(PresetBackup b) {
    fromBackup = false;
    _fromPedal = true;
    _base = b.copy();
    onPedal = PresetBackup(
      identity: onPedal?.identity ?? b.identity,
      created: b.created,
      presets: Uint8List.fromList(b.presets),
      eq: Uint8List.fromList(b.eq),
    );
    notifyListeners();
  }

  /// The pedal stopped answering. Its presets leave the editor, unless they
  /// hold edits not yet written or saved; a file or backup stays open.
  void pedalGone() {
    if (!_fromPedal || unsaved.isNotEmpty) {
      return;
    }
    draft = null;
    _base = null;
    source = null;
    _fromPedal = false;
    forgetPedal();
  }

  /// The pedal changed (another unit, or new firmware): what was read from
  /// it no longer says what it holds.
  void forgetPedal() {
    onPedal = null;
    // Names belong to the pedal (or firmware) they were read from.
    ampNames = null;
    cabNames = null;
    notifyListeners();
  }
}

String slotName(int id) => 'P${(id + 1).toString().padLeft(2, '0')}';

class PresetsPage extends StatelessWidget {
  const PresetsPage({
    super.key,
    required this.workspace,
    required this.canUsePedal,
    required this.busy,
    required this.task,
    required this.fraction,
    required this.message,
    required this.messageIsError,
    required this.onRead,
    required this.onOpen,
    required this.onSave,
    required this.onWrite,
  });

  final PresetWorkspace workspace;
  final bool canUsePedal;
  final bool busy;
  final String? task;
  final double? fraction;
  final String? message;
  final bool messageIsError;
  final VoidCallback onRead;
  final VoidCallback onOpen;
  final VoidCallback onSave;
  final VoidCallback onWrite;

  /// Keys for the whole page, so files work before anything is loaded. A
  /// focused slider or text field keeps its own arrows and Home/End.
  Map<ShortcutActivator, VoidCallback> _keys(BuildContext context) {
    final PresetBackup? draft = workspace.draft;
    void move(int by) {
      if (draft != null) {
        _move(workspace, _shownSlots(workspace, draft), by);
      }
    }

    // The open block, when it can be edited as its card allows (not EQ).
    final int id = workspace.selected;
    final int block = workspace.openBlock;
    final bool editable =
        !busy && draft != null && !draft.oldLayout && block < blockNames.length;
    void nextModel(int by) {
      if (editable) {
        final int n = blockModels[blockNames[block]]!.length;
        workspace.changeModel(id, block, (draft.model(id, block) + by) % n);
      }
    }

    return <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.arrowLeft): () => move(-1),
      const SingleActivator(LogicalKeyboardKey.arrowUp): () => move(-1),
      const SingleActivator(LogicalKeyboardKey.arrowRight): () => move(1),
      const SingleActivator(LogicalKeyboardKey.arrowDown): () => move(1),
      const SingleActivator(LogicalKeyboardKey.pageUp): () => move(-10),
      const SingleActivator(LogicalKeyboardKey.pageDown): () => move(10),
      const SingleActivator(LogicalKeyboardKey.home): () => move(-presetCount),
      const SingleActivator(LogicalKeyboardKey.end): () => move(presetCount),
      // Any slot, whatever the filter shows.
      const SingleActivator(LogicalKeyboardKey.f2): () async {
        if (draft == null) {
          return;
        }
        final int? id = await _askSlot(context, draft.usableCount);
        if (id != null) {
          workspace.select(id);
        }
      },
      // 1 opens the first chip of the chain row, 2 the next, and so on.
      for (int n = 1; n <= 9; n++)
        CharacterActivator('$n'): () {
          final List<int> chips = draft == null
              ? const <int>[]
              : _chipOrder(draft, workspace.selected);
          if (n <= chips.length) {
            workspace.open(chips[n - 1]);
          }
        },
      const SingleActivator(LogicalKeyboardKey.space): () {
        if (editable) {
          final bool on = !draft.isOn(id, block);
          draft.setOn(id, block, on);
          workspace.edited();
          workspace.live?.toggle(block, on);
        }
      },
      const CharacterActivator('['): () => nextModel(-1),
      const CharacterActivator(']'): () => nextModel(1),
      const CharacterActivator('?'): () => _showShortcuts(context),
      _ctrl(LogicalKeyboardKey.keyF): () {
        if (draft != null) {
          showMetaFilter(context, workspace.details, draft.usableCount);
        }
      },
      const SingleActivator(LogicalKeyboardKey.escape): () {
        if (workspace.details.filtering) {
          workspace.details.clearFilter();
        }
      },
      // Enabled as in the menu.
      _ctrl(LogicalKeyboardKey.keyC, shift: true): () {
        if (draft != null) {
          _copyPreset(context, workspace);
        }
      },
      _ctrl(LogicalKeyboardKey.keyV, shift: true): () {
        if (!busy && draft != null && !draft.oldLayout) {
          _pastePreset(context, workspace);
        }
      },
      _ctrl(LogicalKeyboardKey.keyO): () {
        if (!busy) {
          onOpen();
        }
      },
      // As the Write button shows; the write still asks first.
      _ctrl(LogicalKeyboardKey.keyS): () {
        if (!busy &&
            canUsePedal &&
            draft != null &&
            (workspace.changed.isNotEmpty || workspace.onPedal == null)) {
          onWrite();
        }
      },
      // Like the Discard changes button: every edit goes back to the pedal's.
      _ctrl(LogicalKeyboardKey.keyZ): () {
        if (!busy &&
            workspace.changed.isNotEmpty &&
            workspace.onPedal != null) {
          workspace.discard();
        }
      },
      _ctrl(LogicalKeyboardKey.keyS, shift: true): () {
        if (!busy && draft != null && !draft.oldLayout) {
          onSave();
        }
      },
      _ctrl(LogicalKeyboardKey.keyR): () {
        if (!busy && canUsePedal) {
          onRead();
        }
      },
    };
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[workspace, workspace.details]),
      builder: (BuildContext context, _) {
        final PresetBackup? draft = workspace.draft;
        final Widget page = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (_Toolbar.wanted(this)) _Toolbar(page: this),
            if (task != null)
              LinearProgressIndicator(value: fraction)
            else
              const Divider(height: 1),
            if (task == null && message != null) _MessageBar(page: this),
            if (draft != null && workspace.fromBackup)
              _BackupBar(page: this, draft: draft),
            Expanded(
              child: draft == null
                  ? _EmptyState(page: this)
                  : _Editor(workspace: workspace, draft: draft, busy: busy),
            ),
          ],
        );
        return CallbackShortcuts(
          bindings: _keys(context),
          child: Focus(autofocus: true, child: page),
        );
      },
    );
  }
}

/// The presets section's actions, in one menu on the app bar: the assistant,
/// files, reading the pedal again and moving a preset as JSON.
class PresetsMenu extends StatelessWidget {
  const PresetsMenu({
    super.key,
    required this.workspace,
    required this.busy,
    required this.canUsePedal,
    required this.onRead,
    required this.onOpen,
    required this.onSave,
    required this.onAbout,
    this.log,
    this.presetActions = true,
    this.appBarItems = const <Widget>[],
  });
  final PresetWorkspace workspace;
  final bool busy;
  final bool canUsePedal;
  final VoidCallback onRead;
  final VoidCallback onOpen;
  final VoidCallback onSave;
  final VoidCallback onAbout;

  /// Shown in Settings.
  final List<String>? log;

  /// Off outside the Presets page, where the menu only holds Settings and
  /// About.
  final bool presetActions;

  /// App bar actions that move into the menu on a compact window.
  final List<Widget> appBarItems;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: workspace,
    builder: (BuildContext context, _) {
      final bool idle = !busy;
      final bool loaded = workspace.draft != null;
      final bool editable = loaded && !workspace.draft!.oldLayout;
      return MenuAnchor(
        builder: (BuildContext context, MenuController menu, _) => IconButton(
          tooltip: presetActions ? 'Preset actions' : 'More',
          onPressed: () => menu.isOpen ? menu.close() : menu.open(),
          icon: const Icon(Icons.more_vert),
        ),
        menuChildren: <Widget>[
          if (appBarItems.isNotEmpty) ...<Widget>[
            ...appBarItems,
            const Divider(),
          ],
          if (presetActions) ...<Widget>[
            MenuItemButton(
              leadingIcon: const Icon(Icons.folder_open),
              onPressed: idle ? onOpen : null,
              shortcut: _ctrl(LogicalKeyboardKey.keyO),
              child: const Text('Open file…'),
            ),
            MenuItemButton(
              leadingIcon: const Icon(Icons.save_alt),
              onPressed: idle && editable ? onSave : null,
              shortcut: _ctrl(LogicalKeyboardKey.keyS, shift: true),
              child: const Text('Save file…'),
            ),
            MenuItemButton(
              leadingIcon: const Icon(Icons.download_for_offline_outlined),
              onPressed: idle && canUsePedal ? onRead : null,
              shortcut: _ctrl(LogicalKeyboardKey.keyR),
              child: const Text('Read again from pedal'),
            ),
            const Divider(),
            MenuItemButton(
              leadingIcon: const Icon(Icons.copy),
              onPressed: loaded ? () => _copyPreset(context, workspace) : null,
              shortcut: _ctrl(LogicalKeyboardKey.keyC, shift: true),
              child: const Text('Copy preset as JSON'),
            ),
            MenuItemButton(
              leadingIcon: const Icon(Icons.content_paste),
              onPressed: idle && editable
                  ? () => _pastePreset(context, workspace)
                  : null,
              shortcut: _ctrl(LogicalKeyboardKey.keyV, shift: true),
              child: const Text('Paste preset from JSON'),
            ),
            MenuItemButton(
              leadingIcon: const Icon(Icons.keyboard_outlined),
              onPressed: () => _showShortcuts(context),
              shortcut: const CharacterActivator('?'),
              child: const Text('Keyboard shortcuts'),
            ),
            const Divider(),
          ],
          MenuItemButton(
            leadingIcon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push<void>(
              context,
              MaterialPageRoute<void>(builder: (_) => SettingsPage(log: log)),
            ),
            child: const Text('Settings'),
          ),
          MenuItemButton(
            leadingIcon: const Icon(Icons.info_outline),
            onPressed: onAbout,
            child: const Text('About…'),
          ),
        ],
      );
    },
  );
}

/// The open preset to the clipboard as JSON, as the menu and Ctrl+Shift+C do.
Future<void> _copyPreset(
  BuildContext context,
  PresetWorkspace workspace,
) async {
  final int id = workspace.selected;
  await Clipboard.setData(
    ClipboardData(
      text: const JsonEncoder.withIndent('  ')
          .convert(workspace.draft!.presetFields(id)),
    ),
  );
  if (context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('${slotName(id)} copied as JSON.')));
  }
}

/// A preset in JSON from the clipboard into the open one.
Future<void> _pastePreset(
  BuildContext context,
  PresetWorkspace workspace,
) async {
  final int id = workspace.selected;
  String done;
  try {
    final String? text = (await Clipboard.getData('text/plain'))?.text;
    final Object? j = jsonDecode(text ?? '');
    if (j is! Map<String, Object?>) {
      throw const FormatException('expected one preset as a JSON object');
    }
    workspace.draft!.setPresetFields(id, j);
    workspace.edited();
    workspace.showOnPedal();
    done =
        'Pasted into ${slotName(id)}. Nothing is on the pedal until you '
        'write it.';
  } on FormatException catch (e) {
    done = 'Could not paste: ${e.message}';
  } on PlatformException catch (e) {
    done = 'Could not read the clipboard: ${e.message ?? e.code}';
  }
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
  }
}

/// Shown only when there is something to write, or a task running: the
/// task's name on the left, discard and write on the right.
class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.page});
  final PresetsPage page;

  static bool wanted(PresetsPage page) =>
      page.task != null || _actions(page).isNotEmpty;

  static List<Widget> _actions(PresetsPage page) {
    final PresetWorkspace w = page.workspace;
    final int changes = w.changed.length;
    final bool idle = !page.busy;
    return <Widget>[
      if (changes > 0) ...<Widget>[
        TextButton(
          onPressed: idle ? w.discard : null,
          child: const Text('Discard changes'),
        ),
        FilledButton.icon(
          onPressed: idle && page.canUsePedal ? page.onWrite : null,
          icon: const Icon(Icons.upload),
          label: Text(
            changes == 1
                ? 'Write 1 preset to pedal'
                : 'Write $changes presets to pedal',
          ),
        ),
      ] else if (w.draft != null && w.onPedal == null && page.canUsePedal)
        FilledButton.icon(
          onPressed: idle ? page.onWrite : null,
          icon: const Icon(Icons.upload),
          label: const Text('Write to pedal…'),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 16, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              page.task ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: _actions(page),
          ),
        ],
      ),
    );
  }
}

class _MessageBar extends StatelessWidget {
  const _MessageBar({required this.page});
  final PresetsPage page;

  @override
  Widget build(BuildContext context) {
    final ColorScheme c = Theme.of(context).colorScheme;
    return Container(
      color: page.messageIsError ? c.errorContainer : c.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
      child: Text(
        page.message!,
        style: TextStyle(
          color: page.messageIsError
              ? c.onErrorContainer
              : c.onSecondaryContainer,
        ),
      ),
    );
  }
}

/// Says the editor shows a backup, not the pedal, and offers to restore it.
class _BackupBar extends StatelessWidget {
  const _BackupBar({required this.page, required this.draft});
  final PresetsPage page;
  final PresetBackup draft;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme c = theme.colorScheme;
    return Container(
      color: c.tertiaryContainer,
      padding: const EdgeInsets.fromLTRB(24, 8, 16, 8),
      child: Row(
        children: <Widget>[
          Icon(Icons.history, color: c.onTertiaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Viewing a backup from '
              '${draft.created.toLocal().toString().substring(0, 16)}, not '
              'the pedal. Nothing changes on the pedal until you restore it.',
              style: TextStyle(color: c.onTertiaryContainer),
            ),
          ),
          const SizedBox(width: 12),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: c.onTertiaryContainer),
            // With nothing read yet there is no pedal copy to go back to.
            onPressed: page.busy
                ? null
                : page.workspace.onPedal != null
                ? page.workspace.discard
                : page.canUsePedal
                ? page.onRead
                : null,
            child: const Text('Back to the pedal'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: !page.busy && page.canUsePedal ? page.onWrite : null,
            icon: const Icon(Icons.upload),
            label: const Text('Restore to pedal…'),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.page});
  final PresetsPage page;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.tune,
      title: 'Edit your 80 presets',
      message: page.canUsePedal
          ? 'Read them from the pedal, change models, knobs, the signal chain '
                'and the EQ, then write back only what changed. You can also '
                'open a backup file.'
          : 'Connect the pedal to read its presets, or open a backup file to '
                'edit it without the pedal.',
      action: FilledButton.icon(
        onPressed: !page.busy && page.canUsePedal ? page.onRead : null,
        icon: const Icon(Icons.download_for_offline_outlined),
        label: const Text('Read presets from the pedal'),
      ),
    );
  }
}

class _Editor extends StatelessWidget {
  const _Editor({
    required this.workspace,
    required this.draft,
    required this.busy,
  });
  final PresetWorkspace workspace;
  final PresetBackup draft;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final Set<int> changed = workspace.changed;
    final List<int> shown = _shownSlots(workspace, draft);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final _Detail detail = _Detail(
          workspace: workspace,
          draft: draft,
          shown: shown,
          id: workspace.selected,
          enabled: !busy && !draft.oldLayout,
          showPicker: box.maxWidth < 760,
        );
        if (box.maxWidth < 760) {
          return detail;
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              width: 260,
              child: _PresetList(
                workspace: workspace,
                draft: draft,
                shown: shown,
                changed: changed,
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: detail),
          ],
        );
      },
    );
  }
}

/// One line per preset the filter lets through: its name (the AMP model until
/// it has one), its rating, the blocks that are on, and a dot when it differs
/// from the pedal.
List<String> _onBlocks(PresetBackup d, int id) => <String>[
  for (final int b in d.chain(id))
    if (b < blockNames.length && d.isOn(id, b)) blockNames[b],
];

/// The slots the filter lets through, in order.
List<int> _shownSlots(PresetWorkspace w, PresetBackup d) => <int>[
  for (int id = 0; id < d.usableCount; id++)
    if (w.details.matches(id)) id,
];

/// The blocks as the chain row shows them, with the EQ at its head or tail
/// (older clone firmware has none).
List<int> _chipOrder(PresetBackup d, int id) => <int>[
  if (!d.oldLayout && d.eqAtHead(id)) PresetWorkspace.eqBlock,
  ...d.chain(id),
  if (!d.oldLayout && !d.eqAtHead(id)) PresetWorkspace.eqBlock,
];

/// Moves [by] rows of the filtered list; from a slot the filter hides, the
/// first step lands on the nearest shown slot that way.
void _move(PresetWorkspace w, List<int> shown, int by) {
  final int at = w.selected;
  int i = shown.indexOf(at);
  if (i < 0) {
    // Index of the nearest shown slot past [at] in the direction moved.
    i = by > 0
        ? shown.indexWhere((int id) => id > at)
        : shown.lastIndexWhere((int id) => id < at);
    if (i < 0) {
      return;
    }
    by -= by.sign;
  }
  w.select(shown[(i + by).clamp(0, shown.length - 1)]);
}

bool get _apple => <TargetPlatform>{
  TargetPlatform.macOS,
  TargetPlatform.iOS,
}.contains(defaultTargetPlatform);

/// Ctrl, or ⌘ on Apple systems.
SingleActivator _ctrl(LogicalKeyboardKey key, {bool shift = false}) =>
    SingleActivator(key, control: !_apple, meta: _apple, shift: shift);

String _ctrlLabel(String key) => _apple ? '⌘$key' : 'Ctrl+$key';

/// `15`, `P15` or `p15` to its slot index; null outside the first [count].
int? parseSlot(String text, [int count = presetCount]) {
  final String t = text.trim();
  final int? n = int.tryParse(
    t.startsWith(RegExp('[pP]')) ? t.substring(1) : t,
  );
  return n != null && n >= 1 && n <= count ? n - 1 : null;
}

/// The editor's keys, shown from the menu or with `?`.
List<(String, String)> get _shortcuts => <(String, String)>[
  ('← ↑', 'Previous preset'),
  ('→ ↓', 'Next preset'),
  ('PgUp PgDn', '10 presets back or ahead'),
  ('Home End', 'First or last preset'),
  ('F2', 'Go to a preset by number'),
  ('1 – 7', 'Open a block, counting from the left of the chain'),
  ('Space', 'Turn the open block on or off'),
  ('[ ]', 'Previous or next model of the open block'),
  (_ctrlLabel('F'), 'Filter the presets'),
  ('Esc', 'Clear the filter'),
  (_ctrlLabel('Shift+C'), 'Copy the preset as JSON'),
  (_ctrlLabel('Shift+V'), 'Paste a preset from JSON'),
  (_ctrlLabel('O'), 'Open a file'),
  (_ctrlLabel('S'), 'Write to the pedal'),
  (_ctrlLabel('Shift+S'), 'Save to a file'),
  (_ctrlLabel('Z'), 'Discard all changes'),
  (_ctrlLabel('R'), 'Read again from the pedal'),
  ('?', 'Show these shortcuts'),
];

Future<void> _showShortcuts(BuildContext context) {
  final ThemeData theme = Theme.of(context);
  return showDialog<void>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      icon: const Icon(Icons.keyboard_outlined),
      title: const Text('Keyboard shortcuts'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final (String key, String what) in _shortcuts)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: <Widget>[
                  Container(
                    constraints: const BoxConstraints(minWidth: 40),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(key, style: theme.textTheme.labelLarge),
                  ),
                  const SizedBox(width: 16),
                  Text(what),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Text(
            'Moving between presets follows the filter, except F2. Arrows '
            'change presets unless a knob or text field has focus.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

Future<int?> _askSlot(BuildContext context, int count) {
  final TextEditingController text = TextEditingController();
  return showDialog<int>(
    context: context,
    builder: (BuildContext context) => ValueListenableBuilder<TextEditingValue>(
      valueListenable: text,
      builder: (BuildContext context, TextEditingValue v, _) {
        final int? id = parseSlot(v.text, count);
        void go() => Navigator.pop(context, id);
        return AlertDialog(
          title: const Text('Go to preset'),
          content: TextField(
            controller: text,
            autofocus: true,
            keyboardType: TextInputType.number,
            onSubmitted: id == null ? null : (_) => go(),
            decoration: InputDecoration(
              labelText: 'Preset number',
              hintText: '1 to $count',
              border: const OutlineInputBorder(),
              errorText: v.text.trim().isEmpty || id != null
                  ? null
                  : 'From 1 to $count',
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: id == null ? null : go,
              child: const Text('Go'),
            ),
          ],
        );
      },
    ),
  );
}

class _PresetList extends StatefulWidget {
  const _PresetList({
    required this.workspace,
    required this.draft,
    required this.shown,
    required this.changed,
  });
  final PresetWorkspace workspace;
  final PresetBackup draft;
  final List<int> shown;
  final Set<int> changed;

  @override
  State<_PresetList> createState() => _PresetListState();
}

class _PresetListState extends State<_PresetList> {
  static const double _row = 60;
  final ScrollController _scroll = ScrollController();

  PresetWorkspace get workspace => widget.workspace;
  PresetBackup get draft => widget.draft;
  List<int> get shown => widget.shown;
  Set<int> get changed => widget.changed;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Brings the selected preset into view, as it changes from the keyboard.
  void _reveal() {
    final int row = shown.indexOf(workspace.selected);
    if (!_scroll.hasClients || row < 0) {
      return;
    }
    final ScrollPosition p = _scroll.position;
    final double top = row * _row;
    if (top < p.pixels) {
      _scroll.jumpTo(top);
    } else if (top + _row > p.pixels + p.viewportDimension) {
      _scroll.jumpTo(
        (top + _row - p.viewportDimension).clamp(0, p.maxScrollExtent),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    final PresetDetails details = workspace.details;
    final TextStyle? quiet = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(left: 16, right: 4, top: 4),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  details.filtering
                      ? '${shown.length} of ${draft.usableCount} presets'
                      : '${draft.usableCount} presets',
                  style: quiet,
                ),
              ),
              if (details.filtering)
                IconButton(
                  tooltip: 'Clear the filter',
                  onPressed: details.clearFilter,
                  icon: const Icon(Icons.filter_list_off),
                ),
              FilterButton(details: details, count: draft.usableCount),
            ],
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('No preset matches the filter.', style: quiet),
                )
              : _list(theme, details),
        ),
      ],
    );
  }

  Widget _list(ThemeData theme, PresetDetails details) {
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.only(bottom: 8),
      itemCount: shown.length,
      itemExtent: _row,
      itemBuilder: (BuildContext context, int row) {
        final int id = shown[row];
        final PresetMeta meta = details.metas[id];
        final bool selected = id == workspace.selected;
        return ListTile(
          selected: selected,
          selectedTileColor: theme.colorScheme.secondaryContainer,
          shape: const StadiumBorder(),
          contentPadding: const EdgeInsets.only(left: 16, right: 12),
          leading: Text(
            slotName(id),
            style: theme.textTheme.labelLarge?.copyWith(
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
          title: Text(
            meta.name.isEmpty
                ? workspace.modelLabel('AMP', draft.model(id, 1))
                : meta.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text.rich(
            TextSpan(
              children: <InlineSpan>[
                if (meta.rating > 0) ...<InlineSpan>[
                  const WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Icon(Icons.star, size: 14),
                  ),
                  TextSpan(text: ' ${meta.rating}  '),
                ],
                for (final String b in _onBlocks(draft, id)) ...<InlineSpan>[
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: BlockIcon(
                      b,
                      size: 14,
                      color: blockInk(b, theme.brightness),
                    ),
                  ),
                  TextSpan(text: ' $b  '),
                ],
              ],
            ),
            semanticsLabel: <String>[
              if (meta.rating > 0) '${meta.rating} of 5 stars',
              ..._onBlocks(draft, id),
            ].join(', '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          trailing: changed.contains(id)
              ? Tooltip(
                  message: 'Differs from the pedal',
                  child: Icon(
                    Icons.circle,
                    size: 10,
                    color: theme.colorScheme.primary,
                  ),
                )
              : null,
          onTap: () => workspace.select(id),
        );
      },
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({
    required this.workspace,
    required this.draft,
    required this.shown,
    required this.id,
    required this.enabled,
    required this.showPicker,
  });
  final PresetWorkspace workspace;
  final PresetBackup draft;
  final List<int> shown;
  final int id;
  final bool enabled;
  final bool showPicker;

  void _edit(void Function() change) {
    change();
    workspace.edited();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int open = workspace.openBlock;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) => ListView(
        // The content is a column at most 1040 wide, centred on the page.
        padding: EdgeInsets.fromLTRB(
          math.max(24, (box.maxWidth - 1040) / 2),
          16,
          math.max(24, (box.maxWidth - 1040) / 2),
          32,
        ),
        children: _children(
          context,
          theme,
          open,
          box.maxWidth < 600,
          // Room for the summary beside the volume.
          box.maxWidth >= 840,
        ),
      ),
    );
  }

  List<int> get _pickable => <int>[
    for (int i = 0; i < draft.usableCount; i++)
      if (i == id || shown.contains(i)) i,
  ];

  String _pickerLabel(int i) {
    final String name = workspace.details.metas[i].name;
    return name.isEmpty ? slotName(i) : '${slotName(i)}  $name';
  }

  PresetMeta get _meta => workspace.details.metas[id];

  void _editDetails(BuildContext context) =>
      showMetaEditor(context, workspace.details, id, slotName(id));

  Widget _summary(BuildContext context) =>
      MetaSummary(meta: _meta, onEdit: () => _editDetails(context));

  Widget _volume({bool labelAbove = false}) => _LabeledSlider(
    labelAbove: labelAbove,
    label: 'Preset volume',
    value: draft.volume(id),
    max: 100,
    onChanged: enabled ? (int v) => _edit(() => draft.setVolume(id, v)) : null,
  );

  List<Widget> _children(
    BuildContext context,
    ThemeData theme,
    int open,
    bool compact,
    bool summaryInline,
  ) => <Widget>[
    Row(
      children: <Widget>[
        if (showPicker)
          DropdownButton<int>(
            value: id,
            underline: const SizedBox(),
            style: theme.textTheme.headlineSmall,
            // Wide enough for the names; the closed button shows no name.
            menuWidth: 320,
            // The open preset stays pickable when the filter hides it.
            items: <DropdownMenuItem<int>>[
              for (final int i in _pickable)
                DropdownMenuItem<int>(
                  value: i,
                  child: Text(
                    _pickerLabel(i),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            // Closed, it shows the slot alone: a name would not fit.
            selectedItemBuilder: (BuildContext context) => <Widget>[
              for (final int i in _pickable)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(slotName(i)),
                ),
            ],
            onChanged: (int? v) => workspace.select(v!),
          ),
        // The list beside it already names the preset; volume takes the room.
        // On a phone the picker leaves too little, so it gets its own line.
        if (summaryInline)
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.only(right: 24),
              child: _summary(context),
            ),
          ),
        if (!compact)
          Expanded(
            flex: 4,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: _volume(),
              ),
            ),
          )
        else
          const Spacer(),
        // Without the list, its filter button comes here.
        if (showPicker)
          FilterButton(details: workspace.details, count: draft.usableCount),
        // With nothing to sum up, the way in sits with the picker's buttons
        // and takes no line of its own.
        if (showPicker && _meta.isEmpty)
          IconButton(
            tooltip: MetaSummary.editTooltip,
            onPressed: () => _editDetails(context),
            icon: const Icon(Icons.edit_note),
          ),
        // As wide as the summary, so the volume stays in the middle.
        if (summaryInline) const Spacer(flex: 3),
      ],
    ),
    if (compact) _volume(labelAbove: true),
    if (!summaryInline && !(showPicker && _meta.isEmpty)) _summary(context),
    // Tighter on a phone, so the last knob stays above the navigation bar.
    SizedBox(height: compact ? 8 : 16),
    _ChainRow(
      draft: draft,
      id: id,
      enabled: enabled,
      label: workspace.modelLabel,
      open: open,
      onOpen: workspace.open,
      onReorder: (List<int> order) {
        if (!pedalTakesChain(order)) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'The pedal keeps FX and AMP at the start of the chain; '
                'the other four can go in any order.',
              ),
            ),
          );
          return;
        }
        _edit(() => draft.setChain(id, order));
        workspace.live?.chain(order);
      },
    ),
    SizedBox(height: compact ? 12 : 20),
    Align(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SizedBox(
          width: double.infinity,
          child: open < blockNames.length
              ? _BlockCard(
                  // A new card per block, so no state carries over.
                  key: ValueKey<int>(open),
                  workspace: workspace,
                  draft: draft,
                  id: id,
                  block: open,
                  enabled: enabled,
                  edit: _edit,
                )
              : _EqCard(draft: draft, id: id, enabled: enabled, edit: _edit),
        ),
      ),
    ),
  ];
}

class _ChainRow extends StatelessWidget {
  const _ChainRow({
    required this.draft,
    required this.id,
    required this.enabled,
    required this.onReorder,
    required this.label,
    required this.open,
    required this.onOpen,
  });
  final PresetBackup draft;
  final int id;
  final bool enabled;
  final void Function(List<int> order) onReorder;
  final String Function(String block, int model) label;
  final int open;
  final ValueChanged<int> onOpen;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<int> order = draft.chain(id);
    final bool eqHead = draft.eqAtHead(id);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        // Chips shrink to share the width; below 72 the row scrolls.
        final int n = order.length + 1;
        final double width = ((box.maxWidth - 8 * n) / n).clamp(72, 132);
        return _row(theme, order, eqHead, width);
      },
    );
  }

  Widget _row(ThemeData theme, List<int> order, bool eqHead, double width) {
    // EQ is not dragged: its place is the Head/Tail switch on its card.
    final Widget eq = Padding(
      padding: const EdgeInsets.only(right: 8),
      child: _ChainChip(
        name: 'EQ',
        model: eqHead ? 'Head' : 'Tail',
        on: draft.eqOn(id),
        selected: open == PresetWorkspace.eqBlock,
        onTap: () => onOpen(PresetWorkspace.eqBlock),
        theme: theme,
        width: width,
        hotkey: eqHead ? 1 : order.length + 1,
      ),
    );
    return SizedBox(
      height: 64,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          // Older clone firmware has no EQ.
          if (eqHead && !draft.oldLayout) eq,
          Flexible(
            child: _blocks(theme, order, width, eqHead && !draft.oldLayout),
          ),
          if (!eqHead && !draft.oldLayout) eq,
        ],
      ),
    );
  }

  Widget _blocks(
    ThemeData theme,
    List<int> order,
    double width,
    bool eqFirst,
  ) => ReorderableListView(
    shrinkWrap: true,
    scrollDirection: Axis.horizontal,
    // The default desktop handle is an icon drawn over the chip's text;
    // the whole chip is the handle instead.
    buildDefaultDragHandles: false,
    onReorderItem: (int from, int to) {
      final List<int> next = List<int>.of(order);
      next.insert(to, next.removeAt(from));
      onReorder(next);
    },
    children: <Widget>[
      for (final (int i, int b) in order.indexed)
        Padding(
          // A block normally appears once; the count keeps keys unique
          // if a stored chain repeats one.
          key: ValueKey<int>(
            b + 256 * order.take(i).where((int x) => x == b).length,
          ),
          padding: const EdgeInsets.only(right: 8),
          child: _dragHandle(
            index: i,
            enabled: enabled,
            child: _ChainChip(
              name: b < blockNames.length ? blockNames[b] : 'Block $b',
              model: b < blockNames.length
                  ? label(blockNames[b], draft.model(id, b))
                  : '',
              on: b < blockNames.length && draft.isOn(id, b),
              selected: b == open,
              onTap: b < blockNames.length ? () => onOpen(b) : null,
              theme: theme,
              width: width,
              hotkey: i + (eqFirst ? 2 : 1),
            ),
          ),
        ),
    ],
  );
}

/// Touch drags after a long press so the row still scrolls; a mouse drags
/// at once, as the default handles do.
Widget _dragHandle({
  required int index,
  required bool enabled,
  required Widget child,
}) => switch (defaultTargetPlatform) {
  TargetPlatform.android ||
  TargetPlatform.iOS ||
  TargetPlatform.fuchsia => ReorderableDelayedDragStartListener(
    index: index,
    enabled: enabled,
    child: child,
  ),
  _ => ReorderableDragStartListener(
    index: index,
    enabled: enabled,
    child: child,
  ),
};

class _ChainChip extends StatelessWidget {
  const _ChainChip({
    required this.name,
    required this.model,
    required this.on,
    required this.selected,
    required this.onTap,
    required this.theme,
    this.width = 132,
    this.hotkey,
  });
  final String name;

  /// The number key that opens it, shown in a corner where there is a
  /// keyboard.
  final int? hotkey;
  final String model;
  final bool on;
  final double width;

  /// Its card is the one open below.
  final bool selected;
  final VoidCallback? onTap;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    // Like the pedal's screen, an "on" block is a solid box in its colour
    // with white text. Off, it keeps its colour, faded, so every block is
    // still told apart by colour.
    final ColorScheme c = theme.colorScheme;
    final bool dark = theme.brightness == Brightness.dark;
    final Color block = blockColor(name) ?? c.primary;
    final Color fg = on
        ? Colors.white
        : blockInk(name, theme.brightness) ?? block;
    final Widget chip = Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: on ? block : block.withValues(alpha: dark ? 0.22 : 0.14),
        borderRadius: BorderRadius.circular(12),
        border: selected
            ? Border.all(color: c.onSurface, width: 2)
            : on
            ? null
            : Border.all(color: block.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: <Widget>[
          // Narrow chips drop the icon so the name and model still fit.
          if (width >= 110) ...<Widget>[
            BlockIcon(name, size: 28, color: fg),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: theme.textTheme.labelLarge?.copyWith(color: fg),
                ),
                Text(
                  on ? model : 'off',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: fg),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    final int? key = hotkey;
    final bool showKey =
        key != null &&
        key <= 9 &&
        onTap != null &&
        !<TargetPlatform>{
          TargetPlatform.android,
          TargetPlatform.iOS,
          TargetPlatform.fuchsia,
        }.contains(defaultTargetPlatform);
    return Semantics(
      button: true,
      selected: selected,
      hint: showKey ? 'Key $key' : null,
      child: MouseRegion(
        cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: showKey
              ? Stack(
                  children: <Widget>[
                    chip,
                    Positioned(
                      top: 3,
                      right: 7,
                      child: ExcludeSemantics(
                        child: Text(
                          '$key',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: fg.withValues(alpha: 0.75),
                            fontFeatures: const <FontFeature>[
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                )
              : chip,
        ),
      ),
    );
  }
}

class _BlockCard extends StatelessWidget {
  const _BlockCard({
    super.key,
    required this.workspace,
    required this.draft,
    required this.id,
    required this.block,
    required this.enabled,
    required this.edit,
  });
  final PresetWorkspace workspace;
  final PresetBackup draft;
  final int id;
  final int block;
  final bool enabled;
  final void Function(void Function() change) edit;

  // The card, its switch, list and sliders all take the block's colour.
  @override
  Widget build(BuildContext context) => Theme(
    data: blockTheme(Theme.of(context), blockNames[block]),
    child: Builder(builder: _card),
  );

  Widget _card(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String name = blockNames[block];
    final int model = draft.model(id, block);
    final bool on = draft.isOn(id, block);
    final List<(String, List<String>)> models = blockModels[name]!;
    final List<String> knobs = knobNames(name, model);
    return SizedBox(
      width: 280,
      child: Card.outlined(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  IconBadge.block(name, size: 32, strong: on),
                  const SizedBox(width: 10),
                  Text(name, style: theme.textTheme.titleMedium),
                  const Spacer(),
                  Switch(
                    value: on,
                    onChanged: enabled
                        ? (bool v) {
                            edit(() => draft.setOn(id, block, v));
                            workspace.live?.toggle(block, v);
                          }
                        : null,
                  ),
                ],
              ),
              DropdownButton<int>(
                value: model,
                isExpanded: true,
                items: <DropdownMenuItem<int>>[
                  for (final (int i, _) in models.indexed)
                    DropdownMenuItem<int>(
                      value: i,
                      child: Text(workspace.modelLabel(name, i)),
                    ),
                  if (model >= models.length)
                    DropdownMenuItem<int>(
                      value: model,
                      child: Text(workspace.modelLabel(name, model)),
                    ),
                ],
                onChanged: enabled
                    ? (int? v) => workspace.changeModel(id, block, v!)
                    : null,
              ),
              const SizedBox(height: 4),
              for (final (int k, String knob) in knobs.indexed)
                // "knobN" values are kept but not shown: the model has no
                // such knob.
                if (!knob.startsWith('knob'))
                  _LabeledSlider(
                    label: knob,
                    value: draft.knob(id, block, k),
                    max: 100,
                    dense: true,
                    onChanged: enabled
                        ? (int v) {
                            edit(() => draft.setKnob(id, block, k, v));
                            workspace.live?.knob(block, k, v);
                          }
                        : null,
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Whether the app can write preset [id]'s EQ record back. Some stored
/// records are not in a form Save EQ takes; they are kept as they are
/// unless the user resets them.
bool _eqWritable(PresetBackup draft, int id) {
  try {
    saveEqPacket(id, draft.eqRecord(id));
    return true;
  } on ArgumentError {
    return false;
  }
}

class _EqCard extends StatelessWidget {
  const _EqCard({
    required this.draft,
    required this.id,
    required this.enabled,
    required this.edit,
  });
  final PresetBackup draft;
  final int id;
  final bool enabled;
  final void Function(void Function() change) edit;

  bool get _writable => _eqWritable(draft, id);

  @override
  Widget build(BuildContext context) => Theme(
    data: blockTheme(Theme.of(context), 'EQ'),
    child: Builder(builder: _card),
  );

  Widget _card(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (!_writable) {
      return SizedBox(
        width: 280,
        child: Card.outlined(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('EQ', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(
                  'Stored in a form this app cannot write back '
                  '(${draft.eqRecord(id).map((int b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}). '
                  'It is kept as it is.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: enabled
                      ? () => edit(() {
                          draft.setEqOn(id, false);
                          draft.setEqAtHead(id, false);
                          for (int b = 0; b < 5; b++) {
                            draft.setEqBand(id, b, 0);
                          }
                        })
                      : null,
                  child: const Text('Reset EQ (off, flat)'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return SizedBox(
      width: 280,
      child: Card.outlined(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text('EQ', style: theme.textTheme.titleMedium),
                  const Spacer(),
                  Switch(
                    value: draft.eqOn(id),
                    onChanged: enabled
                        ? (bool v) => edit(() => draft.setEqOn(id, v))
                        : null,
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: SegmentedButton<bool>(
                  segments: const <ButtonSegment<bool>>[
                    ButtonSegment<bool>(value: true, label: Text('Head')),
                    ButtonSegment<bool>(value: false, label: Text('Tail')),
                  ],
                  selected: <bool>{draft.eqAtHead(id)},
                  onSelectionChanged: enabled
                      ? (Set<bool> v) =>
                            edit(() => draft.setEqAtHead(id, v.first))
                      : null,
                ),
              ),
              for (int band = 0; band < 5; band++)
                _LabeledSlider(
                  label: eqBandLabels[band],
                  value: draft.eqBand(id, band),
                  // Each band step is half a decibel.
                  format: (int v) =>
                      '${v > 0 ? '+' : ''}${(v * 0.5).toStringAsFixed(1)} dB',
                  valueWidth: 60,
                  min: -6,
                  max: 6,
                  dense: true,
                  onChanged: enabled
                      ? (int v) => edit(() => draft.setEqBand(id, band, v))
                      : null,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LabeledSlider extends StatelessWidget {
  const _LabeledSlider({
    required this.label,
    required this.value,
    required this.max,
    required this.onChanged,
    this.min = 0,
    this.dense = false,
    this.labelAbove = false,
    this.format,
    this.valueWidth = 36,
  });
  final String label;
  final int value;
  final int min;
  final int max;
  final bool dense;

  /// The label on its own line, so the slider takes the whole width.
  final bool labelAbove;
  final ValueChanged<int>? onChanged;

  /// How the value is written out; the bare number when null.
  final String Function(int value)? format;

  /// Width kept for the value beside the slider.
  final double valueWidth;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String shown = format?.call(value) ?? '$value';
    // A stored value outside the range is shown as it is; moving the slider
    // brings it back into range.
    final int top = value > max ? value : max;
    final int bottom = value < min ? value : min;
    // Knob and EQ sliders follow the volume's layout on a phone.
    final bool above =
        labelAbove || (dense && MediaQuery.sizeOf(context).width < 600);
    final Widget text = Text(label, style: theme.textTheme.bodyMedium);
    final Widget number = Text(
      shown,
      textAlign: TextAlign.end,
      style: theme.textTheme.bodyMedium?.copyWith(
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      ),
    );
    final Widget slider = Slider(
      value: value.toDouble(),
      min: bottom.toDouble(),
      max: top.toDouble(),
      // Ticks only where there are few steps (the EQ bands).
      divisions: top - bottom <= 20 ? top - bottom : null,
      label: shown,
      onChanged: onChanged == null ? null : (double v) => onChanged!(v.round()),
    );
    if (above) {
      // Label and value share the top line; the slider keeps its 48 dp
      // touch height and the whole width.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: <Widget>[
                Expanded(child: text),
                number,
              ],
            ),
          ),
          slider,
        ],
      );
    }
    return Row(
      children: <Widget>[
        SizedBox(width: dense ? 84 : 120, child: text),
        Expanded(child: slider),
        SizedBox(width: valueWidth, child: number),
      ],
    );
  }
}
