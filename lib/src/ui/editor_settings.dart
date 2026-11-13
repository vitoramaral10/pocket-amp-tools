// SPDX-License-Identifier: GPL-3.0-only

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// Whether writing the editor's presets over what was read from the pedal
/// asks first. A backup restored over presets the app has not read always
/// asks.
abstract final class EditorSettings {
  static Future<File> _file() async => File(
    '${(await getApplicationSupportDirectory()).path}'
    '${Platform.pathSeparator}editor.json',
  );

  /// On when there is no file or it cannot be read.
  static Future<bool> confirmWrite() async {
    try {
      final Object? j = jsonDecode(await (await _file()).readAsString());
      return j is! Map<String, Object?> || j['confirmWrite'] != false;
    } on Exception {
      return true;
    }
  }

  static Future<void> setConfirmWrite(bool on) async {
    final File f = await _file();
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode(<String, Object>{'confirmWrite': on}));
  }
}

/// The preset editor's settings.
class EditorSettingsCard extends StatefulWidget {
  const EditorSettingsCard({super.key});

  @override
  State<EditorSettingsCard> createState() => _EditorSettingsCardState();
}

class _EditorSettingsCardState extends State<EditorSettingsCard> {
  bool? _confirm;

  @override
  void initState() {
    super.initState();
    EditorSettings.confirmWrite().then((bool v) {
      if (mounted) {
        setState(() => _confirm = v);
      }
    });
  }

  Future<void> _set(bool v) async {
    setState(() => _confirm = v);
    try {
      await EditorSettings.setConfirmWrite(v);
    } on Exception catch (e) {
      if (mounted) {
        setState(() => _confirm = !v);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save the setting: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.tune),
                const SizedBox(width: 12),
                Text('Preset editor', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _confirm ?? true,
              onChanged: _confirm == null ? null : _set,
              title: const Text('Ask before writing to the pedal'),
              subtitle: const Text(
                'Off: Write to pedal and Ctrl+S write your edits at once. '
                'Restoring a backup over presets not read from the pedal '
                'always asks.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
