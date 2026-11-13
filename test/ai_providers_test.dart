// SPDX-License-Identifier: GPL-3.0-only

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_tools/src/assistant/assistant.dart';
import 'package:pocket_amp_tools/src/assistant/providers.dart';

void main() {
  test('every provider has its own id and a usable address', () {
    expect(
      aiProviders.map((AiProvider p) => p.id).toSet(),
      hasLength(aiProviders.length),
    );
    for (final AiProvider p in aiProviders) {
      final Uri u = AssistantSettings(baseUrl: p.baseUrl, model: 'm').endpoint;
      expect(u.path, endsWith('/chat/completions'), reason: p.name);
      // A key may only travel encrypted, except to this computer.
      expect(u.scheme, p.local ? 'http' : 'https', reason: p.name);
      expect(p.local || p.model.isNotEmpty, isTrue, reason: p.name);
    }
  });

  test('an unknown id is a custom address', () {
    expect(aiProvider(''), isNull);
    expect(aiProvider('openai')!.name, 'ChatGPT (OpenAI)');
  });
}
