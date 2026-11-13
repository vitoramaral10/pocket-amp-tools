// SPDX-License-Identifier: GPL-3.0-only

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../assistant/assistant.dart';
import '../assistant/providers.dart';
import 'editor_settings.dart';

/// The app's settings, one card per subject.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, this.log});

  /// The session log; null where it is not at hand (the assistant panel).
  /// shortcut: a snapshot when the page opens, lines added later need a reopen.
  final List<String>? log;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: <Widget>[
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: const AssistantSettingsCard(),
          ),
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: const Padding(
              padding: EdgeInsets.only(top: 16),
              child: EditorSettingsCard(),
            ),
          ),
        ),
        if (log != null)
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Padding(
                padding: const EdgeInsets.only(top: 16),
                child: LogCard(lines: log!),
              ),
            ),
          ),
      ],
    ),
  );
}

/// Where the assistant's requests go: an OpenAI-compatible service.
class AssistantSettingsCard extends StatefulWidget {
  const AssistantSettingsCard({super.key});

  @override
  State<AssistantSettingsCard> createState() => _AssistantSettingsCardState();
}

class _AssistantSettingsCardState extends State<AssistantSettingsCard> {
  final TextEditingController _url = TextEditingController();
  final TextEditingController _model = TextEditingController();
  final TextEditingController _key = TextEditingController();

  /// An [AiProvider.id], or empty for a custom address.
  String _provider = '';
  bool _autoWrite = false;
  bool _loaded = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    AssistantSettings.load().then((AssistantSettings s) {
      if (!mounted) {
        return;
      }
      setState(() {
        // Settings saved before the provider list match it by address.
        _provider =
            aiProvider(s.provider)?.id ??
            aiProviders
                .where((AiProvider p) => p.baseUrl == s.baseUrl.trim())
                .firstOrNull
                ?.id ??
            '';
        _autoWrite = s.autoWrite;
        _url.text = s.baseUrl;
        _model.text = s.model;
        _key.text = s.apiKey;
        _loaded = true;
      });
    });
  }

  @override
  void dispose() {
    _url.dispose();
    _model.dispose();
    _key.dispose();
    super.dispose();
  }

  AssistantSettings get _settings => AssistantSettings(
    provider: _provider,
    baseUrl: _url.text,
    model: _model.text,
    apiKey: _key.text,
    autoWrite: _autoWrite,
  );

  /// Picking a provider fills its address and default model; both stay
  /// editable.
  void _pick(String? id) {
    final AiProvider? p = aiProvider(id ?? '');
    setState(() {
      _provider = p?.id ?? '';
      if (p != null) {
        _url.text = p.baseUrl;
        _model.text = p.model;
      }
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    String done;
    try {
      await _settings.save();
      done = 'Assistant settings saved.';
    } catch (e) {
      done = 'Could not save the assistant settings: $e';
    }
    if (mounted) {
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AiProvider? provider = aiProvider(_provider);
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: !_loaded
            ? const SizedBox(
                height: 80,
                child: Center(child: CircularProgressIndicator()),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      const Icon(Icons.auto_awesome),
                      const SizedBox(width: 12),
                      Text('Assistant', style: theme.textTheme.titleMedium),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'The assistant sends your request and the preset to this '
                    'service and puts its answer in the editor.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  DropdownMenu<String>(
                    initialSelection: _provider,
                    label: const Text('Service'),
                    expandedInsets: EdgeInsets.zero,
                    enableFilter: true,
                    requestFocusOnTap: true,
                    menuHeight: 360,
                    onSelected: _pick,
                    dropdownMenuEntries: <DropdownMenuEntry<String>>[
                      for (final AiProvider p in aiProviders)
                        DropdownMenuEntry<String>(value: p.id, label: p.name),
                      const DropdownMenuEntry<String>(
                        value: '',
                        label: 'Other (OpenAI-compatible address)',
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Known services keep their address out of the way; a
                  // custom or local one is the user's to type.
                  if (provider == null || provider.local) ...<Widget>[
                    TextField(
                      controller: _url,
                      decoration: const InputDecoration(
                        labelText: 'Address',
                        hintText: 'https://…/v1',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextField(
                    controller: _model,
                    decoration: const InputDecoration(
                      labelText: 'Model',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _key,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: provider?.local ?? false
                          ? 'API key (not needed on this computer)'
                          : 'API key',
                      helperText: 'Kept on this computer, in plain text.',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  if (provider != null && provider.keyUrl.isNotEmpty)
                    _KeyLink(url: provider.keyUrl),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _autoWrite,
                    onChanged: (bool v) => setState(() => _autoWrite = v),
                    title: const Text('Write to the pedal without asking'),
                    subtitle: const Text(
                      'Off: the assistant asks before it sends a file to a '
                      'slot or writes presets. On: it does them on its own; '
                      'a slot it replaces is lost for good.',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: _saving ? null : _save,
                      child: const Text('Save'),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Where to create a key, to select or copy; the app opens no browser.
class _KeyLink extends StatelessWidget {
  const _KeyLink({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: <Widget>[
          Text('Get a key at ', style: theme.textTheme.bodySmall),
          Flexible(
            child: SelectableText(
              url,
              maxLines: 1,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Copy address',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: url));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Address copied.')),
                );
              }
            },
            icon: const Icon(Icons.copy),
          ),
        ],
      ),
    );
  }
}

/// The session log, copied whole into bug reports.
class LogCard extends StatelessWidget {
  const LogCard({super.key, required this.lines});
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
