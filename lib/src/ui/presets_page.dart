// SPDX-License-Identifier: GPL-3.0-only

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../presets/block_models.dart';
import '../presets/live_link.dart';
import '../presets/mefcs.dart';
import '../presets/preset_backup.dart';
import 'assistant_dialog.dart';
import 'visuals.dart';

/// The bank being edited and the bank last seen on the pedal, kept while the
/// user moves between sections.
class PresetWorkspace extends ChangeNotifier {
  /// Last read from, or written to, the pedal. Null until presets are read.
  PresetBackup? onPedal;

  /// What the editor shows and changes.
  PresetBackup? draft;

  /// Where [draft] came from, for the header.
  String? source;
  int selected = 0;

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

  void load(PresetBackup b, String from, {bool fromPedal = false}) {
    _base = b.copy();
    if (fromPedal) {
      onPedal = b;
    }
    draft = b.copy();
    source = from;
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
    draft = onPedal!.copy();
    _base = onPedal!.copy();
    showOnPedal();
    notifyListeners();
  }

  /// [b] is now what the pedal holds. The pedal keeps its own identity,
  /// whatever file the presets came from.
  void written(PresetBackup b) {
    _base = b.copy();
    onPedal = PresetBackup(
      identity: onPedal?.identity ?? b.identity,
      created: b.created,
      presets: Uint8List.fromList(b.presets),
      eq: Uint8List.fromList(b.eq),
    );
    notifyListeners();
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
    required this.liveOn,
    required this.onLive,
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

  /// Whether edits are played on the pedal as they are made.
  final bool liveOn;
  final ValueChanged<bool> onLive;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: workspace,
      builder: (BuildContext context, _) {
        final PresetBackup? draft = workspace.draft;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _Toolbar(page: this),
            if (task != null)
              LinearProgressIndicator(value: fraction)
            else
              const Divider(height: 1),
            if (task == null && message != null) _MessageBar(page: this),
            Expanded(
              child: draft == null
                  ? _EmptyState(page: this)
                  : _Editor(workspace: workspace, draft: draft, busy: busy),
            ),
          ],
        );
      },
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.page});
  final PresetsPage page;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final PresetWorkspace w = page.workspace;
    final int changes = w.changed.length;
    final bool idle = !page.busy;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 16, 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text('Presets', style: theme.textTheme.titleLarge),
                Text(
                  page.task ?? w.source ?? 'Nothing loaded yet',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          OutlinedButton.icon(
            onPressed: idle && page.canUsePedal ? page.onRead : null,
            icon: const Icon(Icons.download_for_offline_outlined),
            label: const Text('Read from pedal'),
          ),
          OutlinedButton.icon(
            onPressed: idle ? page.onOpen : null,
            icon: const Icon(Icons.folder_open),
            label: const Text('Open file…'),
          ),
          OutlinedButton.icon(
            onPressed: idle && w.draft != null ? page.onSave : null,
            icon: const Icon(Icons.save_alt),
            label: const Text('Save file…'),
          ),
          if (w.onPedal != null && page.canUsePedal)
            Tooltip(
              message:
                  'Play each change on the pedal as you make it. '
                  'Volume and EQ are heard only after you write. '
                  'Nothing is stored until you write.',
              child: FilterChip(
                selected: page.liveOn,
                onSelected: idle ? page.onLive : null,
                avatar: Icon(
                  page.liveOn ? Icons.graphic_eq : Icons.volume_off_outlined,
                  size: 18,
                ),
                showCheckmark: false,
                label: Text(page.liveOn ? 'Live on pedal' : 'Live off'),
              ),
            ),
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
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final _Detail detail = _Detail(
          workspace: workspace,
          draft: draft,
          id: workspace.selected,
          enabled: !busy,
          showPicker: box.maxWidth < 760,
          changed: changed,
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

/// One line per preset: AMP model, the blocks that are on, and a dot when it
/// differs from the pedal.
List<String> _onBlocks(PresetBackup d, int id) => <String>[
  for (final int b in d.chain(id))
    if (b < blockNames.length && d.isOn(id, b)) blockNames[b],
];

class _PresetList extends StatelessWidget {
  const _PresetList({
    required this.workspace,
    required this.draft,
    required this.changed,
  });
  final PresetWorkspace workspace;
  final PresetBackup draft;
  final Set<int> changed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: presetCount,
      itemExtent: 60,
      itemBuilder: (BuildContext context, int id) {
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
            workspace.modelLabel('AMP', draft.model(id, 1)),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text.rich(
            TextSpan(
              children: <InlineSpan>[
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
            semanticsLabel: _onBlocks(draft, id).join(', '),
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
    required this.id,
    required this.enabled,
    required this.showPicker,
    required this.changed,
  });
  final PresetWorkspace workspace;
  final PresetBackup draft;
  final int id;
  final bool enabled;
  final bool showPicker;
  final Set<int> changed;

  void _edit(void Function() change) {
    change();
    workspace.edited();
  }

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(
      ClipboardData(
        text: const JsonEncoder.withIndent('  ')
            .convert(draft.presetFields(id)),
      ),
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${slotName(id)} copied as JSON.')),
      );
    }
  }

  Future<void> _paste(BuildContext context) async {
    String done;
    try {
      final String? text = (await Clipboard.getData('text/plain'))?.text;
      final Object? j = jsonDecode(text ?? '');
      if (j is! Map<String, Object?>) {
        throw const FormatException('expected one preset as a JSON object');
      }
      _edit(() => draft.setPresetFields(id, j));
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

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      children: <Widget>[
        Row(
          children: <Widget>[
            if (showPicker)
              DropdownButton<int>(
                value: id,
                underline: const SizedBox(),
                style: theme.textTheme.headlineSmall,
                items: <DropdownMenuItem<int>>[
                  for (int i = 0; i < presetCount; i++)
                    DropdownMenuItem<int>(value: i, child: Text(slotName(i))),
                ],
                onChanged: (int? v) => workspace.select(v!),
              )
            else
              Text(slotName(id), style: theme.textTheme.headlineSmall),
            Expanded(
              child: changed.contains(id)
                  ? Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 12),
                        child: Chip(
                          label: const Text(
                            'Not on the pedal yet',
                            overflow: TextOverflow.ellipsis,
                          ),
                          visualDensity: VisualDensity.compact,
                          side: BorderSide.none,
                          backgroundColor: theme.colorScheme.primaryContainer,
                        ),
                      ),
                    )
                  : const SizedBox(),
            ),
            IconButton(
              tooltip: 'Ask the assistant',
              onPressed: enabled
                  ? () async {
                      final String? done = await showAssistant(
                        context,
                        workspace,
                      );
                      if (done != null && context.mounted) {
                        ScaffoldMessenger.of(context)
                            .showSnackBar(SnackBar(content: Text(done)));
                      }
                    }
                  : null,
              icon: const Icon(Icons.auto_awesome),
            ),
            IconButton(
              tooltip: 'Copy this preset as JSON',
              onPressed: () => _copy(context),
              icon: const Icon(Icons.copy),
            ),
            IconButton(
              tooltip: 'Paste a preset from JSON',
              onPressed: enabled ? () => _paste(context) : null,
              icon: const Icon(Icons.content_paste),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: _LabeledSlider(
              label: 'Volume',
              value: draft.volume(id),
              max: 100,
              onChanged: enabled
                  ? (int v) => _edit(() => draft.setVolume(id, v))
                  : null,
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text('Signal chain', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Drag to change the order. The guitar enters on the left; FX and '
          'AMP stay first.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        _ChainRow(
          draft: draft,
          id: id,
          enabled: enabled,
          label: workspace.modelLabel,
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
        const SizedBox(height: 20),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: <Widget>[
            for (final int b in <int>{
              ...draft.chain(id).where((int b) => b < blockNames.length),
              for (int b = 0; b < blockNames.length; b++) b,
            })
              _BlockCard(
                workspace: workspace,
                draft: draft,
                id: id,
                block: b,
                enabled: enabled,
                edit: _edit,
              ),
            _EqCard(draft: draft, id: id, enabled: enabled, edit: _edit),
          ],
        ),
      ],
    );
  }
}

class _ChainRow extends StatelessWidget {
  const _ChainRow({
    required this.draft,
    required this.id,
    required this.enabled,
    required this.onReorder,
    required this.label,
  });
  final PresetBackup draft;
  final int id;
  final bool enabled;
  final void Function(List<int> order) onReorder;
  final String Function(String block, int model) label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<int> order = draft.chain(id);
    return SizedBox(
      height: 64,
      child: ReorderableListView(
        scrollDirection: Axis.horizontal,
        buildDefaultDragHandles: enabled,
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
              child: _ChainChip(
                name: b < blockNames.length ? blockNames[b] : 'Block $b',
                model: b < blockNames.length
                    ? label(blockNames[b], draft.model(id, b))
                    : '',
                on: b < blockNames.length && draft.isOn(id, b),
                theme: theme,
              ),
            ),
        ],
      ),
    );
  }
}

class _ChainChip extends StatelessWidget {
  const _ChainChip({
    required this.name,
    required this.model,
    required this.on,
    required this.theme,
  });
  final String name;
  final String model;
  final bool on;
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
    return Container(
      width: 120,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: on ? block : block.withValues(alpha: dark ? 0.22 : 0.14),
        borderRadius: BorderRadius.circular(12),
        border: on ? null : Border.all(color: block.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Row(
            children: <Widget>[
              BlockIcon(name, size: 16, color: fg),
              const SizedBox(width: 6),
              Text(
                name,
                style: theme.textTheme.labelLarge?.copyWith(color: fg),
              ),
            ],
          ),
          Text(
            on ? model : 'off',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: fg),
          ),
        ],
      ),
    );
  }
}

class _BlockCard extends StatelessWidget {
  const _BlockCard({
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

  /// Whether the app can write this preset's EQ record back. Some stored
  /// records are not in a form Save EQ takes; they are kept as they are
  /// unless the user resets them.
  bool get _writable {
    try {
      saveEqPacket(id, draft.eqRecord(id));
      return true;
    } on ArgumentError {
      return false;
    }
  }

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
                  label: 'Band ${band + 1}',
                  value: draft.eqBand(id, band),
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
  });
  final String label;
  final int value;
  final int min;
  final int max;
  final bool dense;
  final ValueChanged<int>? onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // A stored value outside the range is shown as it is; moving the slider
    // brings it back into range.
    final int top = value > max ? value : max;
    final int bottom = value < min ? value : min;
    return Row(
      children: <Widget>[
        SizedBox(
          width: dense ? 84 : 96,
          child: Text(label, style: theme.textTheme.bodyMedium),
        ),
        Expanded(
          child: Slider(
            value: value.toDouble(),
            min: bottom.toDouble(),
            max: top.toDouble(),
            // Ticks only where there are few steps (the EQ bands).
            divisions: top - bottom <= 20 ? top - bottom : null,
            label: '$value',
            onChanged: onChanged == null
                ? null
                : (double v) => onChanged!(v.round()),
          ),
        ),
        SizedBox(
          width: 36,
          child: Text(
            '$value',
            textAlign: TextAlign.end,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}
