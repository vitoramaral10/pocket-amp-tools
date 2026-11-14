// SPDX-License-Identifier: GPL-3.0-only

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../assistant/agent.dart';
import '../assistant/assistant.dart';
import '../assistant/providers.dart';
import 'settings_page.dart';

/// The assistant's conversation, beside the editor: what the user asked,
/// what it answered and each action it took, with a yes/no card for the
/// ones that write the pedal.
class AssistantPanel extends StatefulWidget {
  const AssistantPanel({
    super.key,
    required this.agent,
    required this.onClose,
    this.settings = AssistantSettings.load,
  });
  final AssistantAgent agent;
  final VoidCallback onClose;

  /// Read to show the service and whether one is set up.
  final Future<AssistantSettings> Function() settings;

  @override
  State<AssistantPanel> createState() => _AssistantPanelState();
}

class _AssistantPanelState extends State<AssistantPanel> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _focus = FocusNode();
  AssistantSettings? _settings;

  @override
  void initState() {
    super.initState();
    widget.agent.addListener(_toEnd);
    _load();
  }

  @override
  void dispose() {
    widget.agent.removeListener(_toEnd);
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final AssistantSettings s = await widget.settings();
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

  void _toEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients) {
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  });

  void _send() {
    final String t = _input.text;
    if (t.trim().isEmpty || widget.agent.busy) {
      return;
    }
    _input.clear();
    widget.agent.send(t);
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AssistantSettings? s = _settings;
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: ListenableBuilder(
        listenable: widget.agent,
        builder: (BuildContext context, _) {
          final AssistantAgent a = widget.agent;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _header(theme, s, a),
              const Divider(height: 1),
              Expanded(
                child: s != null && !s.ready
                    ? _notSetUp(theme)
                    : a.entries.isEmpty
                    ? _empty(theme)
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(12),
                        itemCount: a.entries.length,
                        itemBuilder: (BuildContext context, int i) =>
                            _entry(theme, a, a.entries[i]),
                      ),
              ),
              if (a.busy && a.waiting == null)
                const LinearProgressIndicator(minHeight: 2),
              _composer(theme, s, a),
            ],
          );
        },
      ),
    );
  }

  Widget _header(ThemeData theme, AssistantSettings? s, AssistantAgent a) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        child: Row(
          children: <Widget>[
            const Icon(Icons.auto_awesome, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text('Assistant', style: theme.textTheme.titleSmall),
                  if (s != null && s.ready)
                    Text(
                      '${aiProvider(s.provider)?.name ?? s.baseUrl.trim()} · '
                      '${s.model.trim()}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'New conversation',
              onPressed: a.busy || a.entries.isEmpty ? null : a.clear,
              icon: const Icon(Icons.add_comment_outlined, size: 20),
            ),
            IconButton(
              tooltip: 'Close',
              onPressed: widget.onClose,
              icon: const Icon(Icons.close, size: 20),
            ),
          ],
        ),
      );

  Widget _notSetUp(ThemeData theme) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            'Choose the AI service, its model and your API key to start.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
            label: const Text('Open settings'),
          ),
        ],
      ),
    ),
  );

  Widget _empty(ThemeData theme) {
    const List<String> ideas = <String>[
      'Make P01 a crunchy blues tone',
      'Turn on a short slapback delay',
      'Which IRs do I have in the library?',
      'Put a 4x12 cab IR in a free CAB slot',
    ];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Text(
          'Ask for a sound, or tell it what to change: blocks, models, knobs, '
          'the chain, the EQ, the files in your library. It edits the editor '
          'and, with the pedal connected, you hear it at once.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final String idea in ideas)
              ActionChip(
                label: Text(idea),
                onPressed: () {
                  _input.text = idea;
                  _send();
                },
              ),
          ],
        ),
      ],
    );
  }

  Widget _entry(ThemeData theme, AssistantAgent a, ChatEntry e) {
    final ColorScheme c = theme.colorScheme;
    switch (e.role) {
      case ChatRole.user:
        return Align(
          alignment: Alignment.centerRight,
          child: _bubble(
            theme,
            e.text,
            c.primaryContainer,
            c.onPrimaryContainer,
          ),
        );
      case ChatRole.assistant:
        return Align(
          alignment: Alignment.centerLeft,
          child: _bubble(
            theme,
            e.text,
            c.surfaceContainerHighest,
            c.onSurface,
            markdown: true,
          ),
        );
      case ChatRole.error:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(
            e.text,
            style: theme.textTheme.bodySmall?.copyWith(color: c.error),
          ),
        );
      case ChatRole.tool:
        return e.status == ToolStatus.waiting
            ? _confirm(theme, a, e)
            : _action(theme, e);
    }
  }

  Widget _bubble(
    ThemeData theme,
    String text,
    Color bg,
    Color fg, {
    bool markdown = false,
  }) => Container(
    margin: const EdgeInsets.symmetric(vertical: 4),
    constraints: const BoxConstraints(maxWidth: 340),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(12),
    ),
    child: markdown
        ? SelectableText.rich(
            markdownLite(text, theme.textTheme.bodyMedium!.copyWith(color: fg)),
          )
        : SelectableText(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(color: fg),
          ),
  );

  /// One action, in a line: what it did and how it went.
  Widget _action(ThemeData theme, ChatEntry e) {
    final ColorScheme c = theme.colorScheme;
    final ToolAnnotations n = e.tool!.annotations;
    final (IconData icon, Color color) = switch (e.status) {
      ToolStatus.running => (Icons.more_horiz, c.onSurfaceVariant),
      ToolStatus.done => (
        n.readOnly
            ? Icons.visibility_outlined
            : n.destructive
            ? Icons.upload
            : Icons.edit_outlined,
        c.onSurfaceVariant,
      ),
      ToolStatus.failed => (Icons.error_outline, c.error),
      ToolStatus.declined => (Icons.block, c.onSurfaceVariant),
      ToolStatus.waiting => (Icons.help_outline, c.primary),
    };
    // What an edit or a write did is worth reading; a look is not.
    final String? said = e.status == ToolStatus.failed
        ? e.outcome
        : e.status == ToolStatus.declined
        ? 'Declined'
        : n.readOnly
        ? null
        : e.outcome;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  e.text,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: c.onSurfaceVariant,
                  ),
                ),
                if (said != null && said.isNotEmpty)
                  Text(
                    said,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: e.status == ToolStatus.failed
                          ? c.error
                          : c.onSurface,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// An action that writes the pedal, waiting for the user's answer.
  Widget _confirm(ThemeData theme, AssistantAgent a, ChatEntry e) =>
      Card.outlined(
        margin: const EdgeInsets.symmetric(vertical: 6),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    Icons.warning_amber_rounded,
                    color: theme.colorScheme.tertiary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      e.tool!.annotations.title,
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(e.text, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 4),
              Text(
                'This writes the pedal\'s memory and cannot be undone from the app.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton(
                    onPressed: () => a.answer(e, false),
                    child: const Text('Decline'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => a.answer(e, true),
                    child: const Text('Allow'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );

  Widget _composer(ThemeData theme, AssistantSettings? s, AssistantAgent a) =>
      Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            Expanded(
              child: CallbackShortcuts(
                // Enter sends; Shift+Enter starts a new line.
                bindings: <ShortcutActivator, VoidCallback>{
                  const SingleActivator(LogicalKeyboardKey.enter): _send,
                },
                child: TextField(
                  controller: _input,
                  focusNode: _focus,
                  enabled: s != null && s.ready,
                  minLines: 1,
                  maxLines: 6,
                  textInputAction: TextInputAction.newline,
                  decoration: const InputDecoration(
                    hintText: 'Ask the assistant…',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (a.busy)
              IconButton.filledTonal(
                tooltip: 'Stop',
                onPressed: a.stop,
                icon: const Icon(Icons.stop),
              )
            else
              IconButton.filled(
                tooltip: 'Send',
                onPressed: s != null && s.ready ? _send : null,
                icon: const Icon(Icons.arrow_upward),
              ),
          ],
        ),
      );
}

/// The little Markdown models write in a chat: **bold**, `code`, lists with
/// "-", "*" or numbers, and "#" headings, as one span so it selects whole.
/// Anything else is shown as written.
TextSpan markdownLite(String text, TextStyle style) {
  final TextStyle bold = style.copyWith(fontWeight: FontWeight.w600);
  final List<InlineSpan> out = <InlineSpan>[];
  final List<String> lines = text.split('\n');
  final RegExp bullet = RegExp(r'^\s*[-*•]\s+(.*)$');
  final RegExp numbered = RegExp(r'^\s*(\d+)[.)]\s+(.*)$');
  final RegExp heading = RegExp(r'^\s*#{1,6}\s+(.*)$');
  for (final (int i, String line) in lines.indexed) {
    if (i > 0) {
      out.add(const TextSpan(text: '\n'));
    }
    RegExpMatch? m;
    if ((m = heading.firstMatch(line)) != null) {
      out.add(TextSpan(text: _plain(m!.group(1)!), style: bold));
    } else if ((m = bullet.firstMatch(line)) != null) {
      out
        ..add(const TextSpan(text: '•  '))
        ..addAll(_inline(m!.group(1)!, style, bold));
    } else if ((m = numbered.firstMatch(line)) != null) {
      out
        ..add(TextSpan(text: '${m!.group(1)}.  '))
        ..addAll(_inline(m.group(2)!, style, bold));
    } else {
      out.addAll(_inline(line, style, bold));
    }
  }
  return TextSpan(style: style, children: out);
}

final RegExp _marks = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`');

List<InlineSpan> _inline(String text, TextStyle style, TextStyle bold) {
  final List<InlineSpan> out = <InlineSpan>[];
  int at = 0;
  for (final RegExpMatch m in _marks.allMatches(text)) {
    if (m.start > at) {
      out.add(TextSpan(text: text.substring(at, m.start)));
    }
    out.add(
      m.group(1) != null
          ? TextSpan(text: m.group(1), style: bold)
          : TextSpan(
              text: m.group(2),
              style: style.copyWith(fontFamily: 'monospace'),
            ),
    );
    at = m.end;
  }
  if (at < text.length) {
    out.add(TextSpan(text: text.substring(at)));
  }
  return out;
}

String _plain(String text) => text.replaceAll('**', '');
