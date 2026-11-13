// SPDX-License-Identifier: GPL-3.0-only
//
// Asks an AI model for a preset. The user brings the service: any endpoint
// that speaks the OpenAI chat-completions format (a provider, a proxy, a
// local server). The app sends the request and the current preset, and gets
// back one preset in the backup file's shape, which is then checked like a
// file. Nothing here talks to the pedal.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../net/capped_http.dart';

import '../presets/block_models.dart';
import '../presets/preset_backup.dart' show knobLabels, knobNames;

class AssistantSettings {
  const AssistantSettings({
    this.provider = '',
    this.baseUrl = '',
    this.model = '',
    this.apiKey = '',
  });

  /// The [AiProvider.id] picked in Settings, or empty for a custom address.
  final String provider;

  /// e.g. `https://api.example.com/v1`; `/chat/completions` is added.
  final String baseUrl;
  final String model;

  /// Kept in plain text in the app's support folder, readable only by the
  /// user.
  final String apiKey;

  bool get ready => baseUrl.trim().isNotEmpty && model.trim().isNotEmpty;

  /// The chat-completions address, keeping any query (`?api-version=…`).
  Uri get endpoint {
    final Uri base = Uri.parse(baseUrl.trim());
    final List<String> path = <String>[
      ...base.pathSegments.where((String p) => p.isNotEmpty),
    ];
    final bool done =
        path.length >= 2 &&
        path[path.length - 2] == 'chat' &&
        path.last == 'completions';
    return base.replace(
      pathSegments: done ? path : <String>[...path, 'chat', 'completions'],
    );
  }

  /// A key may only travel encrypted, or to this computer.
  bool get keyWouldLeakInClear {
    if (apiKey.trim().isEmpty) {
      return false;
    }
    final Uri u = endpoint;
    return u.scheme != 'https' &&
        !<String>{'localhost', '127.0.0.1', '::1', '[::1]'}.contains(u.host);
  }

  static Future<File> _file() async => File(
    '${(await getApplicationSupportDirectory()).path}'
    '${Platform.pathSeparator}assistant.json',
  );

  /// Empty settings when there is no file or it cannot be read.
  static Future<AssistantSettings> load() async {
    try {
      final Object? j = jsonDecode(await (await _file()).readAsString());
      if (j is Map<String, Object?>) {
        return AssistantSettings(
          provider: j['provider'] as String? ?? '',
          baseUrl: j['baseUrl'] as String? ?? '',
          model: j['model'] as String? ?? '',
          apiKey: j['apiKey'] as String? ?? '',
        );
      }
    } catch (_) {
      // No settings yet.
    }
    return const AssistantSettings();
  }

  Future<void> save() async {
    final File f = await _file();
    await f.parent.create(recursive: true);
    // Written aside and locked down before it takes the real name, so the
    // key is never readable by others, even for a moment.
    final File tmp = File('${f.path}.tmp');
    await tmp.writeAsString('');
    if (Platform.isLinux || Platform.isMacOS) {
      try {
        await Process.run('chmod', <String>['600', tmp.path]);
      } catch (_) {
        // Best effort: the file still works.
      }
    }
    await tmp.writeAsString(
      jsonEncode(<String, String>{
        'provider': provider,
        'baseUrl': baseUrl.trim(),
        'model': model.trim(),
        'apiKey': apiKey.trim(),
      }),
      flush: true,
    );
    await tmp.rename(f.path);
  }
}

class AssistantException implements Exception {
  const AssistantException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What the model is told about the preset format and the pedal.
String assistantSystemPrompt() {
  final StringBuffer models = StringBuffer();
  blockModels.forEach((String block, List<(String, List<String>)> list) {
    models.writeln('$block:');
    for (final (String name, List<String> knobs) in list) {
      models.writeln('  "$name": ${knobs.join(', ')}');
    }
  });
  return '''
You design presets for the M-VAVE Pocket AMP, a guitar multi-effects pedal.
A preset is a JSON object with this shape:
{"volume": 0-100,
 "chain": the six blocks "FX","AMP","MOD","DLY","REV","CAB" in signal order, each once; FX and AMP must be the first two (in either order), the other four in any order,
 "blocks": {"FX": {"on": true|false, "model": "<model name>", "knobs": [{"label": "<knob>", "value": 0-100}, ... six entries]}, ... one entry per block},
 "eq": {"on": true|false, "position": "head"|"tail", "bands": [five whole numbers from -6 to 6]}}
Each block's "knobs" is a list of exactly six entries, in the order of the model's knobs below; the position decides which knob a value sets, the "label" is only a reminder. Positions past the model's knobs are unused (for example a model with four knobs has unused 5th and 6th entries); keep their values as they are, or 0.
Models and their knobs per block (firmware V1.05):
$models
Change only what the request needs; keep everything else as in the current preset.
Answer with the JSON object only, no text before or after it.''';
}

/// One request to the model. Returns the preset as decoded JSON.
Future<Map<String, Object?>> askAssistant(
  AssistantSettings settings,
  String request,
  Map<String, Object> currentPreset,
) async {
  if (!settings.ready) {
    throw const AssistantException(
      'Set the assistant address and model first.',
    );
  }
  if (settings.keyWouldLeakInClear) {
    throw const AssistantException(
      'The API key would be sent unencrypted. Use an https:// address, or '
      'leave the key empty for a server on this computer.',
    );
  }
  final Map<String, Object> current = Map<String, Object>.of(currentPreset)
    ..remove('preset');
  final int status;
  final Uint8List bytes;
  try {
    final http.Request post = http.Request('POST', settings.endpoint)
      // A redirect would carry the key to a host the user did not set.
      ..followRedirects = false
      ..headers.addAll(<String, String>{
        'content-type': 'application/json',
        if (settings.apiKey.trim().isNotEmpty)
          'authorization': 'Bearer ${settings.apiKey.trim()}',
      })
      ..body = jsonEncode(<String, Object>{
        'model': settings.model.trim(),
        'stream': false,
        'messages': <Map<String, String>>[
          <String, String>{
            'role': 'system',
            'content': assistantSystemPrompt(),
          },
          <String, String>{
            'role': 'user',
            'content':
                'Request: $request\n\nCurrent preset:\n${jsonEncode(current)}',
          },
        ],
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
  if (status == 401 || status == 403) {
    throw const AssistantException('The assistant refused the API key.');
  }
  if (status != 200) {
    throw AssistantException(
      'The assistant answered HTTP $status. Check the address and the '
      'model name.',
    );
  }
  final Map<String, Object?>? preset;
  try {
    preset = firstJsonObject(_content(jsonDecode(utf8.decode(bytes))));
  } on FormatException {
    throw const AssistantException(
      'The assistant did not answer in the chat-completions format.',
    );
  }
  if (preset == null) {
    throw const AssistantException('The assistant did not answer a preset.');
  }
  return preset;
}

/// The text of a chat-completions answer: `content` as a string, or as a
/// list of parts with `text` (what some proxies pass through).
String? _content(Object? body) {
  if (body is! Map) {
    return null;
  }
  final Object? choices = body['choices'];
  if (choices is! List || choices.isEmpty || choices.first is! Map) {
    return null;
  }
  final Object? message = (choices.first as Map)['message'];
  final Object? content = message is Map ? message['content'] : null;
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
  return null;
}

/// The first complete JSON object in [text], skipping code fences or words
/// around it.
Map<String, Object?>? firstJsonObject(String? text) {
  if (text == null) {
    return null;
  }
  // A few starting braces at most: each try scans to the end of the text.
  int tries = 0;
  for (
    int start = text.indexOf('{');
    start >= 0 && tries++ < 8;
    start = text.indexOf('{', start + 1)
  ) {
    int depth = 0;
    bool inString = false;
    for (int i = start; i < text.length; i++) {
      final String c = text[i];
      if (inString) {
        if (c == r'\') {
          i++;
        } else if (c == '"') {
          inString = false;
        }
      } else if (c == '"') {
        inString = true;
      } else if (c == '{') {
        depth++;
      } else if (c == '}' && --depth == 0) {
        try {
          final Object? j = jsonDecode(text.substring(start, i + 1));
          if (j is Map<String, Object?>) {
            return j;
          }
        } on FormatException {
          // Not JSON after all; try the next brace.
        }
        break;
      }
    }
  }
  return null;
}

/// Lays [answer] over [current] (both in the backup file's preset shape), so
/// a reply that leaves out unchanged fields or the unused knob values still
/// makes a whole preset. Knobs may come as the file's list (by position) or
/// as an object of knob names. The result is checked like a file before use.
Map<String, Object?> mergeSuggestion(
  Map<String, Object?> current,
  Map<String, Object?> answer,
) {
  final Map<String, Object?> out = Map<String, Object?>.of(current)
    ..remove('preset');
  for (final String key in <String>['volume', 'chain', 'eq']) {
    if (answer.containsKey(key)) {
      out[key] = answer[key];
    }
  }
  final Object? answerBlocks = answer['blocks'];
  final Object? currentBlocks = current['blocks'];
  if (answerBlocks is Map && currentBlocks is Map) {
    final Map<String, Object?> blocks = <String, Object?>{};
    for (final MapEntry<Object?, Object?> e in currentBlocks.entries) {
      final String name = '${e.key}';
      final Object? now = e.value;
      final Object? asked = answerBlocks[name];
      if (now is! Map || asked is! Map) {
        blocks[name] = now;
        continue;
      }
      final Object? model = asked['model'] ?? now['model'];
      final int? index = model is String
          ? blockModels[name]?.indexWhere(
              ((String, List<String>) m) => m.$1 == model,
            )
          : model is int
          ? model
          : null;
      final List<String>? names = index == null || index < 0
          ? null
          : knobNames(name, index);
      final bool sameModel = model == now['model'];
      final Object? askedKnobs = asked['knobs'];
      final List<Object?>? askedValues = _knobValues(askedKnobs, names);
      final List<Object?> nowValues = sameModel
          ? _knobValues(now['knobs'], names) ?? List<Object?>.filled(6, null)
          : List<Object?>.filled(6, null);
      blocks[name] = <String, Object?>{
        'on': asked['on'] ?? now['on'],
        'model': model,
        // An unknown model, or a list of the wrong length, goes through as
        // given, for the check to refuse or keep it.
        'knobs': names == null || askedValues == null
            ? askedKnobs ?? now['knobs']
            : <Map<String, Object?>>[
                for (final (int k, String label) in knobLabels(
                  name,
                  index!,
                ).indexed)
                  <String, Object?>{
                    'label': label,
                    'value': askedValues[k] ?? nowValues[k] ?? 0,
                  },
              ],
      };
    }
    out['blocks'] = blocks;
  }
  return out;
}

/// The six knob values in [knobs], null where not given: a list by position
/// (numbers or objects with a "value"), an object by the knob [names]. Null
/// when [knobs] is a list of more than six, or neither shape fits.
List<Object?>? _knobValues(Object? knobs, List<String>? names) {
  if (knobs == null) {
    return List<Object?>.filled(6, null);
  }
  if (knobs is List) {
    if (knobs.length > 6) {
      return null;
    }
    return <Object?>[
      for (int k = 0; k < 6; k++)
        if (k >= knobs.length)
          null
        else if (knobs[k] is Map)
          (knobs[k] as Map<Object?, Object?>)['value']
        else
          knobs[k],
    ];
  }
  if (knobs is Map && names != null) {
    return <Object?>[for (final String n in names) knobs[n]];
  }
  return null;
}
