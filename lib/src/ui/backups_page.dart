// SPDX-License-Identifier: GPL-3.0-only

import 'dart:io';

import 'package:flutter/material.dart';

import '../presets/preset_backup.dart';
import 'visuals.dart';

/// The backups the app keeps on its own (one before every update), with a
/// way to open one in the editor or restore it.
class BackupsPage extends StatefulWidget {
  const BackupsPage({
    super.key,
    required this.list,
    required this.canRestore,
    required this.onEdit,
    required this.onRestore,
    required this.onRestoreRaw,
    required this.onSaveNew,
    this.task,
    this.fraction,
    this.message,
    this.messageIsError = false,
  });

  /// The running pedal task and the last result, shown above the list.
  final String? task;
  final double? fraction;
  final String? message;
  final bool messageIsError;

  final Future<List<(File, PresetBackup?, String?)>> Function() list;
  final bool canRestore;
  final void Function(PresetBackup b, String name) onEdit;
  final void Function(PresetBackup b, String name) onRestore;
  final void Function(File raw) onRestoreRaw;
  final Future<void> Function() onSaveNew;

  @override
  State<BackupsPage> createState() => _BackupsPageState();
}

class _BackupsPageState extends State<BackupsPage> {
  late Future<List<(File, PresetBackup?, String?)>> _files = widget.list();

  void _reload() => setState(() {
    _files = widget.list();
  });

  Future<void> _delete(File f) async {
    final String name = f.uri.pathSegments.last;
    final bool yes =
        await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: Text('Delete backup "$name"?'),
            content: const Text(
              'The file is deleted from this computer. This cannot be undone.',
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
    if (!yes) {
      return;
    }
    try {
      await f.delete();
    } on FileSystemException catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('Could not delete $name: ${e.message}')),
        );
      }
    }
    if (mounted) {
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool compact = MediaQuery.sizeOf(context).width < 600;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      children: <Widget>[
        Flex(
          // On a phone the button goes under the text instead of squeezing it.
          direction: compact ? Axis.vertical : Axis.horizontal,
          crossAxisAlignment: compact
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.center,
          spacing: 12,
          children: <Widget>[
            // flex 0 lays it out at its own height inside the list.
            Flexible(
              flex: compact ? 0 : 1,
              fit: FlexFit.tight,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('Backups', style: theme.textTheme.titleLarge),
                  Text(
                    'Kept in Documents/Pocket AMP Tools. The app adds one '
                    'before every firmware update.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            FilledButton.tonalIcon(
              onPressed: widget.canRestore
                  ? () async {
                      await widget.onSaveNew();
                      if (mounted) {
                        _reload();
                      }
                    }
                  : null,
              icon: const Icon(Icons.add),
              label: const Text('Back up the pedal now'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (widget.task != null) ...<Widget>[
          Text(widget.task!),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: widget.fraction),
          const SizedBox(height: 16),
        ] else if (widget.message != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              widget.message!,
              style: widget.messageIsError
                  ? TextStyle(color: theme.colorScheme.error)
                  : null,
            ),
          ),
        FutureBuilder<List<(File, PresetBackup?, String?)>>(
          future: _files,
          builder:
              (
                BuildContext context,
                AsyncSnapshot<List<(File, PresetBackup?, String?)>> snap,
              ) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snap.hasError) {
                  return Text(
                    'Could not list the backups: ${snap.error}',
                    style: TextStyle(color: theme.colorScheme.error),
                  );
                }
                final List<(File, PresetBackup?, String?)> files = snap.data!;
                if (files.isEmpty) {
                  return const EmptyState(
                    icon: Icons.inventory_2_outlined,
                    title: 'No backups yet.',
                    message:
                        'Back up the pedal now, or let the app do it: it '
                        'keeps a copy before every firmware update.',
                  );
                }
                return Card.outlined(
                  margin: EdgeInsets.zero,
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: <Widget>[
                      for (final (int i, (File f, PresetBackup? b, String? e))
                          in files.indexed) ...<Widget>[
                        if (i > 0) const Divider(height: 1),
                        _BackupTile(
                          file: f,
                          backup: b,
                          error: e,
                          canRestore: widget.canRestore,
                          canEdit: widget.task == null,
                          onEdit: widget.onEdit,
                          onRestore: widget.onRestore,
                          onRestoreRaw: widget.onRestoreRaw,
                          onDelete: () => _delete(f),
                        ),
                      ],
                    ],
                  ),
                );
              },
        ),
      ],
    );
  }
}

class _BackupTile extends StatelessWidget {
  const _BackupTile({
    required this.file,
    required this.backup,
    required this.error,
    required this.canRestore,
    required this.canEdit,
    required this.onEdit,
    required this.onRestore,
    required this.onRestoreRaw,
    required this.onDelete,
  });
  final VoidCallback onDelete;
  final bool canEdit;
  final File file;
  final PresetBackup? backup;
  final String? error;
  final bool canRestore;
  final void Function(PresetBackup b, String name) onEdit;
  final void Function(PresetBackup b, String name) onRestore;
  final void Function(File raw) onRestoreRaw;

  @override
  Widget build(BuildContext context) {
    final String name = file.uri.pathSegments.last;
    final PresetBackup? b = backup;
    final Widget delete = IconButton(
      tooltip: 'Delete backup',
      onPressed: canEdit ? onDelete : null,
      icon: const Icon(Icons.delete_outline),
    );
    if (b == null && error == null) {
      return ListTile(
        leading: const IconBadge(Icons.memory),
        title: Text(name),
        subtitle: const Text(
          'Raw copy from older firmware: P01–P79 can be restored; P80 and '
          'the EQ stay as they are on the pedal.',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            OutlinedButton.icon(
              onPressed: canRestore ? () => onRestoreRaw(file) : null,
              icon: const Icon(Icons.history),
              label: const Text('Restore…'),
            ),
            delete,
          ],
        ),
      );
    }
    if (b == null) {
      return ListTile(
        leading: const IconBadge(Icons.error_outline),
        title: Text(name),
        subtitle: Text('Not readable: $error'),
        trailing: delete,
      );
    }
    return ListTile(
      leading: const IconBadge(Icons.inventory_2_outlined),
      title: Text(b.created.toLocal().toString().substring(0, 16)),
      subtitle: Text('${b.identity} · $name'),
      trailing: MediaQuery.sizeOf(context).width < 640
          ? PopupMenuButton<VoidCallback>(
              tooltip: 'Actions',
              onSelected: (VoidCallback action) => action(),
              itemBuilder: (BuildContext context) =>
                  <PopupMenuEntry<VoidCallback>>[
                    PopupMenuItem<VoidCallback>(
                      value: () => onEdit(b, name),
                      enabled: canEdit,
                      child: const Text('Open in editor'),
                    ),
                    PopupMenuItem<VoidCallback>(
                      value: () => onRestore(b, name),
                      enabled: canRestore,
                      child: const Text('Restore…'),
                    ),
                    PopupMenuItem<VoidCallback>(
                      value: onDelete,
                      enabled: canEdit,
                      child: const Text('Delete…'),
                    ),
                  ],
            )
          : Wrap(
              spacing: 8,
              children: <Widget>[
                TextButton.icon(
                  onPressed: canEdit ? () => onEdit(b, name) : null,
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Open in editor'),
                ),
                OutlinedButton.icon(
                  onPressed: canRestore ? () => onRestore(b, name) : null,
                  icon: const Icon(Icons.history),
                  label: const Text('Restore…'),
                ),
                delete,
              ],
            ),
    );
  }
}
