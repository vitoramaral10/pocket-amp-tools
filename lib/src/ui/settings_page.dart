// SPDX-License-Identifier: GPL-3.0-only

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../assistant/assistant.dart';
import '../assistant/providers.dart';

/// The app's settings, one card per subject.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

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
