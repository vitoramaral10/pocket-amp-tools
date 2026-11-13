// SPDX-License-Identifier: GPL-3.0-only

import 'package:flutter/material.dart';

import '../assistant/assistant.dart';
import '../presets/preset_backup.dart';
import 'presets_page.dart';
import 'settings_page.dart';

/// Asks the assistant to change the selected preset. The answer goes into
/// the editor (and is heard live when live editing is on); nothing is
/// written to the pedal until the user writes.
Future<String?> showAssistant(BuildContext context, PresetWorkspace w) =>
    showDialog<String>(
      context: context,
      // Closed only by its buttons: an answer must not land unseen.
      barrierDismissible: false,
      builder: (BuildContext context) => _AssistantDialog(workspace: w),
    );

class _AssistantDialog extends StatefulWidget {
  const _AssistantDialog({required this.workspace});
  final PresetWorkspace workspace;

  @override
  State<_AssistantDialog> createState() => _AssistantDialogState();
}

class _AssistantDialogState extends State<_AssistantDialog> {
  final TextEditingController _request = TextEditingController();

  /// As saved in Settings; null while loading.
  AssistantSettings? _settings;
  bool _asking = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _request.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final AssistantSettings s = await AssistantSettings.load();
    if (mounted) {
      setState(() => _settings = s);
    }
  }

  Future<void> _openSettings() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
    );
    await _load();
  }

  Future<void> _ask() async {
    final PresetWorkspace w = widget.workspace;
    final int id = w.selected;
    final PresetBackup draft = w.draft!;
    setState(() {
      _asking = true;
      _error = null;
    });
    try {
      final Map<String, Object> current = draft.presetFields(id);
      try {
        // Checked before asking: a preset the editor cannot take back would
        // waste the request and the user's tokens.
        draft.copy().setPresetFields(id, current);
      } on FormatException catch (e) {
        _show(
          'The assistant cannot edit ${slotName(id)}: it holds values this '
          'app cannot write (${e.message}).',
        );
        return;
      }
      final Map<String, Object?> answer = await askAssistant(
        _settings!,
        _request.text.trim(),
        current,
      );
      if (!mounted || !identical(w.draft, draft) || w.selected != id) {
        return; // the editor moved on meanwhile
      }
      draft.setPresetFields(id, mergeSuggestion(current, answer));
      w.edited();
      w.showOnPedal();
      if (mounted) {
        Navigator.pop(
          context,
          'The assistant changed ${slotName(id)}. Listen, adjust, and write '
          'it when you like it.',
        );
      }
    } on AssistantException catch (e) {
      _show(e.message);
    } on FormatException catch (e) {
      _show('The suggestion is not a preset the pedal can take: ${e.message}');
    } catch (e) {
      _show('$e');
    } finally {
      if (mounted) {
        setState(() => _asking = false);
      }
    }
  }

  void _show(String error) {
    if (mounted) {
      setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return PopScope(canPop: !_asking, child: _dialog(theme));
  }

  Widget _dialog(ThemeData theme) {
    return AlertDialog(
      scrollable: true,
      icon: const Icon(Icons.auto_awesome),
      title: Text(
        'Ask the assistant about ${slotName(widget.workspace.selected)}',
      ),
      content: SizedBox(
        width: 480,
        child: _settings == null
            ? const SizedBox(
                height: 80,
                child: Center(child: CircularProgressIndicator()),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (!_settings!.ready) ...<Widget>[
                    Text(
                      'The assistant needs a service to ask. Set its address '
                      'and model in Settings.',
                      style: theme.textTheme.bodyMedium,
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _openSettings,
                        icon: const Icon(Icons.settings_outlined),
                        label: const Text('Open settings'),
                      ),
                    ),
                  ] else ...<Widget>[
                    TextField(
                      controller: _request,
                      autofocus: true,
                      minLines: 2,
                      maxLines: 5,
                      decoration: const InputDecoration(
                        labelText: 'What should it sound like?',
                        hintText:
                            'e.g. less gain, a short slapback delay, '
                            'brighter for a single-coil guitar',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'The request and this preset are sent to the service '
                      'set in Settings. The answer replaces the preset in the '
                      'editor; nothing is stored on the pedal until you write.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        _error!,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                ],
              ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _asking ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _asking || !(_settings?.ready ?? false) ? null : _ask,
          icon: _asking
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.auto_awesome),
          label: const Text('Suggest'),
        ),
      ],
    );
  }
}
