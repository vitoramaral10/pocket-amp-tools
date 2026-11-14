// SPDX-License-Identifier: GPL-3.0-only
//
// The assistant's settings and the pieces its agent shares: the service it
// asks (any endpoint that speaks the OpenAI chat-completions format: a
// provider, a proxy, a local server), the errors those services answer, and
// laying a partial preset over a whole one. Nothing here talks to the
// pedal.

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../presets/block_models.dart';
import '../presets/preset_backup.dart' show knobLabels, knobNames;

class AssistantSettings {
  const AssistantSettings({
    this.provider = '',
    this.baseUrl = '',
    this.model = '',
    this.apiKey = '',
    this.autoWrite = false,
  });

  /// Lets the assistant write the pedal's flash (send to a slot, write
  /// presets) without asking each time.
  final bool autoWrite;

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
          autoWrite: j['autoWrite'] == true,
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
      jsonEncode(<String, Object>{
        'provider': provider,
        'baseUrl': baseUrl.trim(),
        'model': model.trim(),
        'apiKey': apiKey.trim(),
        'autoWrite': autoWrite,
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

/// The error message in a service's error body, in the shapes they use:
/// `{"error": {"message": …}}`, `{"error": "…"}` or `{"message": …}`.
/// Cut short: it goes into one line on screen.
String? serviceError(List<int> bytes) {
  Object? j;
  try {
    j = jsonDecode(utf8.decode(bytes, allowMalformed: true));
  } on FormatException {
    return null;
  }
  if (j is List && j.isNotEmpty) {
    j = j.first; // Gemini wraps its error in a list
  }
  if (j is! Map) {
    return null;
  }
  final Object? error = j['error'];
  final Object? text = error is Map
      ? error['message']
      : error is String
      ? error
      : j['message'];
  if (text is! String || text.trim().isEmpty) {
    return null;
  }
  final String t = text.trim();
  return t.length > 300 ? '${t.substring(0, 300)}…' : t;
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
  for (final String key in <String>['volume', 'chain']) {
    if (answer.containsKey(key)) {
      out[key] = answer[key];
    }
  }
  // The EQ, like a block, keeps what the answer leaves out (only the bands,
  // say).
  final Object? answerEq = answer['eq'];
  final Object? currentEq = current['eq'];
  if (answerEq is Map && currentEq is Map) {
    out['eq'] = <String, Object?>{
      for (final MapEntry<Object?, Object?> e in currentEq.entries)
        '${e.key}': e.value,
      for (final MapEntry<Object?, Object?> e in answerEq.entries)
        '${e.key}': e.value,
    };
  } else if (answer.containsKey('eq')) {
    out['eq'] = answerEq;
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
