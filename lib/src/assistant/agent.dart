// SPDX-License-Identifier: GPL-3.0-only
//
// The assistant as an agent: it talks with the user over several turns and
// acts through tools (read the presets, edit them, send files to the pedal),
// in the OpenAI chat-completions "tools" format every listed service speaks.
// Tools that write the pedal's flash wait for the user's yes unless the
// settings allow them outright.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../net/capped_http.dart';
import 'assistant.dart';

/// What a tool does to the world, as MCP's tool annotations say it: the
/// agent asks before a destructive one, and the panel shows each kind.
class ToolAnnotations {
  const ToolAnnotations({
    required this.title,
    this.readOnly = false,
    this.destructive = false,
  });

  /// Short, for the panel ("Send to slot").
  final String title;

  /// Only looks: never changes the editor or the pedal.
  final bool readOnly;

  /// Writes the pedal's flash and cannot be undone from the app.
  final bool destructive;
}

/// A tool the model may call.
class AssistantTool {
  const AssistantTool({
    required this.name,
    required this.description,
    required this.parameters,
    required this.annotations,
    required this.run,
    this.describe,
  });

  final String name;
  final String description;

  /// JSON Schema of the arguments object.
  final Map<String, Object?> parameters;
  final ToolAnnotations annotations;

  /// Returns what the model reads back, encoded as JSON. Throws
  /// [ToolError] for an answer the model should see as an error.
  final Future<Object?> Function(Map<String, Object?> args) run;

  /// One line for the panel and the confirmation, from the arguments.
  final String Function(Map<String, Object?> args)? describe;

  Map<String, Object?> toJson() => <String, Object?>{
    'type': 'function',
    'function': <String, Object?>{
      'name': name,
      'description': description,
      'parameters': parameters,
    },
  };
}

/// A refusal the model reads as the tool's answer, to correct its call.
class ToolError implements Exception {
  const ToolError(this.message);
  final String message;
  @override
  String toString() => message;
}

enum ChatRole { user, assistant, tool, error }

enum ToolStatus { running, waiting, done, failed, declined }

/// One line of the conversation as the panel shows it.
class ChatEntry {
  ChatEntry.user(this.text) : role = ChatRole.user, tool = null, args = null;
  ChatEntry.assistant(this.text)
    : role = ChatRole.assistant,
      tool = null,
      args = null;
  ChatEntry.error(this.text) : role = ChatRole.error, tool = null, args = null;
  ChatEntry.tool(AssistantTool this.tool, Map<String, Object?> this.args)
    : role = ChatRole.tool,
      text = tool.describe?.call(args) ?? tool.annotations.title;

  final ChatRole role;
  final String text;
  final AssistantTool? tool;
  final Map<String, Object?>? args;
  ToolStatus status = ToolStatus.running;

  /// What the tool answered, or why it failed, for the panel.
  String? outcome;
  Completer<bool>? _answer;
}

/// Runs the conversation. The panel listens to it.
class AssistantAgent extends ChangeNotifier {
  AssistantAgent({
    required this.tools,
    required this.settings,
    this.maxSteps = 24,
  });

  final List<AssistantTool> tools;

  /// Read before each message, so changes in Settings apply at once.
  final Future<AssistantSettings> Function() settings;

  /// Model calls per user message, so a confused model cannot loop forever.
  final int maxSteps;

  final List<ChatEntry> entries = <ChatEntry>[];

  /// The conversation in the service's format, without the system prompt.
  final List<Map<String, Object?>> _messages = <Map<String, Object?>>[];

  bool get busy => _busy;
  bool _busy = false;
  bool _stop = false;

  /// The entry waiting for the user's yes or no, if any.
  ChatEntry? get waiting {
    for (final ChatEntry e in entries.reversed) {
      if (e.status == ToolStatus.waiting && e.role == ChatRole.tool) {
        return e;
      }
    }
    return null;
  }

  /// Answers the confirmation [e] waits for.
  void answer(ChatEntry e, bool allow) {
    final Completer<bool>? c = e._answer;
    if (c != null && !c.isCompleted) {
      c.complete(allow);
    }
  }

  /// Stops after the step under way; a waiting confirmation is declined.
  void stop() {
    _stop = true;
    final ChatEntry? w = waiting;
    if (w != null) {
      answer(w, false);
    }
  }

  void clear() {
    if (_busy) {
      return;
    }
    entries.clear();
    _messages.clear();
    notifyListeners();
  }

  Future<void> send(String text) async {
    final String t = text.trim();
    if (t.isEmpty || _busy) {
      return;
    }
    _busy = true;
    _stop = false;
    entries.add(ChatEntry.user(t));
    _messages.add(<String, Object?>{'role': 'user', 'content': t});
    notifyListeners();
    try {
      final AssistantSettings s = await settings();
      if (!s.ready) {
        throw const AssistantException(
          'Choose the assistant\'s service and model in Settings first.',
        );
      }
      for (int step = 0; ; step++) {
        if (_stop) {
          entries.add(ChatEntry.error('Stopped.'));
          break;
        }
        if (step == maxSteps) {
          entries.add(
            ChatEntry.error(
              'Stopped after $maxSteps steps. Ask again to go on.',
            ),
          );
          break;
        }
        final Map<String, Object?> reply = await _complete(s);
        final String content = _text(reply['content']);
        final List<Map<String, Object?>> calls = _calls(reply['tool_calls']);
        _messages.add(<String, Object?>{
          'role': 'assistant',
          // Some services refuse an empty text next to tool calls.
          if (content.isNotEmpty || calls.isEmpty) 'content': content,
          if (calls.isNotEmpty) 'tool_calls': calls,
        });
        if (content.trim().isNotEmpty) {
          entries.add(ChatEntry.assistant(content.trim()));
          notifyListeners();
        }
        if (calls.isEmpty) {
          break;
        }
        for (final Map<String, Object?> call in calls) {
          _messages.add(<String, Object?>{
            'role': 'tool',
            'tool_call_id': call['id'],
            'content': await _call(call, s.autoWrite),
          });
        }
      }
    } on AssistantException catch (e) {
      entries.add(ChatEntry.error(e.message));
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Runs one tool call and returns what the model reads back.
  Future<String> _call(Map<String, Object?> call, bool autoWrite) async {
    final Object? fn = call['function'];
    final String name = fn is Map ? '${fn['name']}' : '';
    final AssistantTool? tool = tools
        .where((AssistantTool t) => t.name == name)
        .firstOrNull;
    if (tool == null) {
      return jsonEncode(<String, Object>{'error': 'No tool named "$name".'});
    }
    Map<String, Object?> args;
    try {
      final Object? raw = fn is Map ? fn['arguments'] : null;
      final Object? j = raw is String
          ? (raw.trim().isEmpty ? <String, Object?>{} : jsonDecode(raw))
          : raw ?? <String, Object?>{};
      if (j is! Map<String, Object?>) {
        throw const FormatException('expected an object');
      }
      args = j;
    } on FormatException catch (e) {
      return jsonEncode(<String, Object>{
        'error': 'The arguments are not a JSON object: ${e.message}',
      });
    }
    final ChatEntry e = ChatEntry.tool(tool, args);
    entries.add(e);
    if (_stop) {
      e.status = ToolStatus.declined;
      notifyListeners();
      return jsonEncode(<String, Object>{'error': 'The user stopped.'});
    }
    if (tool.annotations.destructive && !autoWrite) {
      e
        ..status = ToolStatus.waiting
        .._answer = Completer<bool>();
      notifyListeners();
      final bool allowed = await e._answer!.future;
      if (!allowed) {
        e.status = ToolStatus.declined;
        notifyListeners();
        return jsonEncode(<String, Object>{
          'error': 'The user declined this. Do not try it again unless asked.',
        });
      }
      e.status = ToolStatus.running;
    }
    notifyListeners();
    try {
      final Object? result = await tool.run(args);
      e
        ..status = ToolStatus.done
        ..outcome = result is String ? result : null;
      return jsonEncode(<String, Object?>{'result': result});
    } on ToolError catch (err) {
      e
        ..status = ToolStatus.failed
        ..outcome = err.message;
      return jsonEncode(<String, Object>{'error': err.message});
    } catch (err) {
      e
        ..status = ToolStatus.failed
        ..outcome = '$err';
      return jsonEncode(<String, Object>{'error': '$err'});
    } finally {
      notifyListeners();
    }
  }

  /// One model call; returns its message.
  Future<Map<String, Object?>> _complete(AssistantSettings s) async {
    if (s.keyWouldLeakInClear) {
      throw const AssistantException(
        'The API key would be sent unencrypted. Use an https:// address, or '
        'leave the key empty for a server on this computer.',
      );
    }
    final int status;
    final Uint8List bytes;
    try {
      final http.Request post = http.Request('POST', s.endpoint)
        // A redirect would carry the key to a host the user did not set.
        ..followRedirects = false
        ..headers.addAll(<String, String>{
          'content-type': 'application/json',
          if (s.apiKey.trim().isNotEmpty)
            'authorization': 'Bearer ${s.apiKey.trim()}',
        })
        ..body = jsonEncode(<String, Object?>{
          'model': s.model.trim(),
          'stream': false,
          'messages': <Map<String, Object?>>[
            <String, Object?>{'role': 'system', 'content': agentSystemPrompt()},
            ..._messages,
          ],
          'tools': <Object?>[for (final AssistantTool t in tools) t.toJson()],
        });
      // Slow on purpose: a local model on a CPU can take minutes.
      (status, bytes) = await sendCapped(
        post,
        1 << 20,
        timeout: const Duration(seconds: 120),
      );
    } on TooLarge {
      throw const AssistantException('The assistant answered too much text.');
    } catch (e) {
      throw AssistantException('Could not reach the assistant: $e');
    }
    if (status != 200) {
      final String? said = serviceError(bytes);
      final String why = said == null ? '' : ' It said: $said';
      throw AssistantException(switch (status) {
        401 || 403 => 'The service refused the API key.$why',
        404 => 'The service does not know this address or model.$why',
        429 =>
          'The service is rate-limiting this key, or its credit ran out.$why',
        _ => 'The service answered HTTP $status.$why',
      });
    }
    final Object? body;
    try {
      body = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const AssistantException(
        'The service did not answer in the chat-completions format.',
      );
    }
    final Object? choices = body is Map ? body['choices'] : null;
    final Object? first = choices is List && choices.isNotEmpty
        ? choices.first
        : null;
    final Object? message = first is Map ? first['message'] : null;
    if (message is! Map) {
      throw const AssistantException(
        'The service did not answer in the chat-completions format.',
      );
    }
    if (first is Map &&
        first['finish_reason'] == 'length' &&
        _calls(message['tool_calls']).isEmpty) {
      throw const AssistantException(
        'The answer was cut off by the service\'s length limit. Try a model '
        'without long reasoning.',
      );
    }
    return Map<String, Object?>.from(message);
  }
}

/// The text of a message's content: a string, or parts with "text".
String _text(Object? content) {
  if (content is String) {
    return content;
  }
  if (content is List) {
    return content
        .whereType<Map>()
        .map((Map p) => p['text'])
        .whereType<String>()
        .join();
  }
  return '';
}

/// The tool calls of a message, each with an id (some services leave it
/// out; the answer must still point back to its call).
List<Map<String, Object?>> _calls(Object? raw) => <Map<String, Object?>>[
  if (raw is List)
    for (final (int i, Object? c) in raw.indexed)
      if (c is Map && c['function'] is Map)
        <String, Object?>{
          'id': c['id'] is String && (c['id'] as String).isNotEmpty
              ? c['id']
              : 'call_$i',
          'type': 'function',
          'function': c['function'],
        },
];

/// What the model is told before the conversation.
String agentSystemPrompt() => '''
You are the assistant inside Pocket AMP Tools, an editor for the M-VAVE Pocket AMP guitar multi-effects pedal. You act through the tools; never claim a change you did not make with a tool.

The pedal holds 80 presets, P01 to P80. Each has a volume (0-100), a signal chain of six blocks (FX, AMP, MOD, DLY, REV, CAB; FX and AMP must be the first two, in either order; the other four in any order), each block on or off with a model and up to six knobs (0-100), and an EQ (on/off, at the head or tail of the chain, five bands from -6 to 6).
AMP and CAB have 20 slots each. The user can replace a slot with an amp capture (.nam) or an impulse response (.wav) from their library; the app cannot read a slot back, so the old content is lost for good.

How changes work:
- Editing a preset changes the editor and, when the pedal is connected, is heard on it at once, but nothing is stored on the pedal until write_presets. Tell the user when there are edits not yet written.
- upload_to_slot and write_presets write the pedal's flash; the user may be asked to allow them.
- Read before you change: look at the preset (get_preset) and the models and knob names (list_models) before editing, and the library and slots before uploading.
- When you change a block's model, give every knob of the new model a value.
- Choose models and knob values from what list_models says they do; the real gear it names is a guess from the model's name, so do not state it as fact. Models marked "bass only" are for bass guitar.
- The EQ is gentle: each band step is 0.5 dB (±3 dB at most). Shape tone mainly with the AMP knobs and the CAB Low/High Cut.
- Change only what the request needs. If a request is unclear, ask.
- The user can give each preset a name, a description, genres, uses, tags and a star rating. The app keeps them, not the pedal, and they are saved at once. Use them to find the preset the user means, and set them only when asked.

Answer in the user's language, briefly. Say what you changed in plain words (block, model, knob, values), not as JSON. Never name the tools to the user: say "write to the pedal", not write_presets.''';
