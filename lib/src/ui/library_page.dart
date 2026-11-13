// SPDX-License-Identifier: GPL-3.0-only

import 'package:flutter/material.dart';

import '../library/library.dart';
import '../presets/ir_upload.dart';
import 'visuals.dart';

/// The user's amp captures and IRs kept on the computer, next to the 20
/// pedal slots of the same kind, with a way to put a file in a slot.
class LibraryPage extends StatelessWidget {
  const LibraryPage({
    super.key,
    required this.kind,
    required this.onKind,
    required this.items,
    required this.links,
    required this.names,
    required this.canUsePedal,
    required this.needsUsb,
    required this.busy,
    required this.task,
    required this.fraction,
    required this.message,
    required this.messageIsError,
    required this.onReadNames,
    required this.onImport,
    required this.onRename,
    required this.onDelete,
    required this.onSendItem,
    required this.onLoadSlot,
  });

  final LibraryKind kind;
  final ValueChanged<LibraryKind> onKind;

  /// Null until the library folder is read.
  final List<LibraryItem>? items;

  /// Slot -> library file name, for slots written from the library.
  final Map<int, String> links;

  /// As stored on the pedal; null until read.
  final List<String>? names;
  final bool canUsePedal;

  /// Connected over Bluetooth: names can be read, files go over USB only.
  final bool needsUsb;
  final bool busy;
  final String? task;
  final double? fraction;
  final String? message;
  final bool messageIsError;
  final VoidCallback onReadNames;
  final VoidCallback onImport;
  final ValueChanged<LibraryItem> onRename;
  final ValueChanged<LibraryItem> onDelete;
  final ValueChanged<LibraryItem> onSendItem;
  final ValueChanged<int> onLoadSlot;

  bool get _canSend => canUsePedal && !needsUsb && !busy;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool amp = kind == LibraryKind.amp;
    final Widget files = _filesPanel(context, theme, amp);
    final Widget slots = _slotsPanel(context, theme, amp);
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      children: <Widget>[
        Wrap(
          spacing: 16,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.spaceBetween,
          children: <Widget>[
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Library', style: theme.textTheme.titleLarge),
                Text(
                  amp
                      ? 'Your amp captures: A2 .nam files from TONE3000. The '
                            'pedal plays their small (Lite) model.'
                      : 'Your IRs: WAV, 44.1 kHz, mono, 24-bit, '
                            '$irSampleCount samples.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            SegmentedButton<LibraryKind>(
              segments: const <ButtonSegment<LibraryKind>>[
                ButtonSegment<LibraryKind>(
                  value: LibraryKind.amp,
                  icon: BlockIcon('AMP', size: 18),
                  label: Text('Amps'),
                ),
                ButtonSegment<LibraryKind>(
                  value: LibraryKind.cab,
                  icon: BlockIcon('CAB', size: 18),
                  label: Text('Cabinets'),
                ),
              ],
              selected: <LibraryKind>{kind},
              onSelectionChanged: busy
                  ? null
                  : (Set<LibraryKind> s) => onKind(s.single),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (needsUsb)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'The pedal is connected over Bluetooth. Connect the USB cable '
              'to send files to it.',
              style: TextStyle(color: theme.colorScheme.tertiary),
            ),
          ),
        if (task != null) ...<Widget>[
          Text(task!),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: fraction),
          const SizedBox(height: 12),
        ] else if (message != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              message!,
              style: messageIsError
                  ? TextStyle(color: theme.colorScheme.error)
                  : null,
            ),
          ),
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) => c.maxWidth >= 900
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(child: files),
                    const SizedBox(width: 24),
                    Expanded(child: slots),
                  ],
                )
              : Column(
                  children: <Widget>[files, const SizedBox(height: 24), slots],
                ),
        ),
      ],
    );
  }

  Widget _heading(ThemeData theme, String title, Widget action) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: <Widget>[
        Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
        action,
      ],
    ),
  );

  Widget _filesPanel(BuildContext context, ThemeData theme, bool amp) {
    final List<LibraryItem>? list = items;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _heading(
          theme,
          list == null || list.isEmpty
              ? 'On this computer'
              : 'On this computer (${list.length})',
          FilledButton.tonalIcon(
            onPressed: busy ? null : onImport,
            icon: const Icon(Icons.add),
            label: Text(amp ? 'Add .nam files…' : 'Add WAV files…'),
          ),
        ),
        if (list == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (list.isEmpty)
          EmptyState(
            icon: Icons.library_music_outlined,
            title: amp ? 'No captures yet' : 'No IRs yet',
            message: amp
                ? 'Add the .nam files you downloaded; they are copied into '
                      'the library, so the originals can go.'
                : 'Add your WAV files; they are copied into the library, so '
                      'the originals can go.',
          )
        else
          Card.outlined(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: <Widget>[
                for (final (int i, LibraryItem it) in list.indexed) ...<Widget>[
                  if (i > 0) const Divider(height: 1),
                  ListTile(
                    leading: IconBadge.block(amp ? 'AMP' : 'CAB'),
                    title: Text(it.name, overflow: TextOverflow.ellipsis),
                    subtitle: _usedIn(it),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        TextButton(
                          onPressed: _canSend && names != null
                              ? () => onSendItem(it)
                              : null,
                          child: const Text('Send to pedal…'),
                        ),
                        PopupMenuButton<void Function()>(
                          tooltip: 'More',
                          enabled: !busy,
                          onSelected: (void Function() f) => f(),
                          itemBuilder: (BuildContext context) =>
                              <PopupMenuEntry<void Function()>>[
                                PopupMenuItem<void Function()>(
                                  value: () => onRename(it),
                                  child: const Text('Rename…'),
                                ),
                                PopupMenuItem<void Function()>(
                                  value: () => onDelete(it),
                                  child: const Text('Delete from library…'),
                                ),
                              ],
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget? _usedIn(LibraryItem it) {
    final List<int> slots = <int>[
      for (final MapEntry<int, String> e in links.entries)
        if (e.value == it.name) e.key + 1,
    ]..sort();
    return slots.isEmpty
        ? null
        : Text('In slot${slots.length > 1 ? 's' : ''} ${slots.join(', ')}');
  }

  Widget _slotsPanel(BuildContext context, ThemeData theme, bool amp) {
    final List<String>? n = names;
    final String block = amp ? 'AMP' : 'CAB';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _heading(
          theme,
          'On the pedal',
          OutlinedButton.icon(
            onPressed: canUsePedal && !busy ? onReadNames : null,
            icon: const Icon(Icons.refresh),
            label: Text(n == null ? 'Read from pedal' : 'Read again'),
          ),
        ),
        if (n == null)
          EmptyState(
            icon: Icons.speaker_group_outlined,
            title: amp ? 'AMP slots' : 'CAB slots',
            message: canUsePedal
                ? 'Read the slot names from the pedal to start.'
                : 'Connect the pedal to see its $block slots.',
          )
        else
          Card.outlined(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: <Widget>[
                for (int i = 0; i < n.length; i++) ...<Widget>[
                  if (i > 0) const Divider(height: 1),
                  ListTile(
                    leading: CircleAvatar(
                      radius: 18,
                      backgroundColor: theme.colorScheme.secondaryContainer,
                      foregroundColor: theme.colorScheme.onSecondaryContainer,
                      child: Text(
                        '${i + 1}',
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                    title: Text(slotName(n, i)),
                    subtitle: links[i] == null
                        ? null
                        : Text('From your library: ${links[i]}'),
                    trailing: TextButton(
                      onPressed: _canSend && (items?.isNotEmpty ?? false)
                          ? () => onLoadSlot(i)
                          : null,
                      child: const Text('Load from library…'),
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// The pedal overwrites the first character of the first name with the
/// request's checksum.
String slotName(List<String> names, int i) =>
    i == 0 && names[0].isNotEmpty ? '?${names[0].substring(1)}' : names[i];

/// Picks one of the 20 slots; null when cancelled.
Future<int?> chooseSlot(
  BuildContext context,
  String block,
  String file,
  List<String> names,
  Map<int, String> links,
) => showDialog<int>(
  context: context,
  builder: (BuildContext context) => SimpleDialog(
    title: Text('Send "$file" to which $block slot?'),
    children: <Widget>[
      for (int i = 0; i < names.length; i++)
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, i),
          child: Text(
            '${i + 1}.  ${slotName(names, i)}'
            '${links[i] == null ? '' : '  (from ${links[i]})'}',
          ),
        ),
    ],
  ),
);

/// Picks a library file for slot [slot]; null when cancelled.
Future<LibraryItem?> chooseItem(
  BuildContext context,
  String block,
  int slot,
  List<LibraryItem> items,
) => showDialog<LibraryItem>(
  context: context,
  builder: (BuildContext context) => SimpleDialog(
    title: Text('Put which file in $block slot ${slot + 1}?'),
    children: <Widget>[
      for (final LibraryItem it in items)
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, it),
          child: Text(it.name),
        ),
    ],
  ),
);

/// Asks for the name shown on the pedal and confirms; null when cancelled.
Future<String?> confirmSlotUpload(
  BuildContext context,
  int slot,
  String current,
  String suggested, {
  String block = 'CAB',
  String what = 'IRs',
  String plays = 'IR',
}) {
  final TextEditingController name = TextEditingController(
    text: sanitizeIrName(suggested),
  );
  return showDialog<String>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      icon: const Icon(Icons.warning_amber_rounded),
      title: Text('Replace $block slot ${slot + 1}?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '"$current" is replaced for good: the app cannot read $what back '
            'from the pedal. Presets that use this slot will play the new '
            '$plays.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: name,
            maxLength: irNameMaxLength,
            decoration: const InputDecoration(
              labelText: 'Name on the pedal',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: name,
          builder: (BuildContext context, TextEditingValue v, _) =>
              FilledButton(
                onPressed: sanitizeIrName(v.text).trim().isEmpty
                    ? null
                    : () => Navigator.pop(context, sanitizeIrName(v.text)),
                child: const Text('Replace'),
              ),
        ),
      ],
    ),
  );
}

/// Asks for a new file name; null when cancelled.
Future<String?> askRename(BuildContext context, String current) {
  final TextEditingController name = TextEditingController(text: current);
  return showDialog<String>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: const Text('Rename'),
      content: TextField(
        controller: name,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Name in the library',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (String v) => Navigator.pop(context, v),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, name.text),
          child: const Text('Rename'),
        ),
      ],
    ),
  );
}

/// Confirms deleting a library file.
Future<bool> confirmDelete(BuildContext context, String name) async =>
    await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('Delete "$name" from the library?'),
        content: const Text(
          'The file is deleted from this computer. Pedal slots that have it '
          'keep playing it.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    ) ??
    false;
