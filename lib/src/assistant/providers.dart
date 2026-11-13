// SPDX-License-Identifier: GPL-3.0-only

/// An AI service the assistant can ask through its OpenAI-compatible
/// chat-completions endpoint, with a bearer key.
class AiProvider {
  const AiProvider({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.model,
    this.keyUrl = '',
    this.local = false,
  });

  /// Stored in the settings; never shown.
  final String id;
  final String name;

  /// `/chat/completions` is added to it.
  final String baseUrl;

  /// A sensible default; the user can type any model the service offers.
  final String model;

  /// Where the user creates a key, when known.
  final String keyUrl;

  /// Runs on this computer: the address is the user's to set and no key is
  /// needed.
  final bool local;
}

/// The services offered in Settings. Addresses and default models were
/// checked against each provider's own documentation in November 2026;
/// models change often, so the model field stays editable.
/// Left out: Perplexity (its chat completions for Sonar ended in 2026),
/// 01.AI (no current documentation found) and Tencent Hunyuan (the old
/// endpoint takes no new customers, the new one does not document its
/// key header).
const List<AiProvider> aiProviders = <AiProvider>[
  AiProvider(
    id: 'openai',
    name: 'ChatGPT (OpenAI)',
    baseUrl: 'https://api.openai.com/v1',
    model: 'gpt-6.1-terra',
    keyUrl: 'https://platform.openai.com/api-keys',
  ),
  AiProvider(
    id: 'anthropic',
    name: 'Claude (Anthropic)',
    baseUrl: 'https://api.anthropic.com/v1',
    model: 'claude-sonnet-5-5',
    keyUrl: 'https://platform.claude.com/settings/keys',
  ),
  AiProvider(
    id: 'gemini',
    name: 'Gemini (Google)',
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
    model: 'gemini-3.8-flash',
    keyUrl: 'https://aistudio.google.com/apikey',
  ),
  AiProvider(
    id: 'xai',
    name: 'Grok (xAI)',
    baseUrl: 'https://api.x.ai/v1',
    model: 'grok-4.7',
    keyUrl: 'https://console.x.ai',
  ),
  AiProvider(
    id: 'mistral',
    name: 'Mistral',
    baseUrl: 'https://api.mistral.ai/v1',
    model: 'mistral-small-latest',
    keyUrl: 'https://console.mistral.ai/api-keys',
  ),
  AiProvider(
    id: 'cohere',
    name: 'Cohere',
    baseUrl: 'https://api.cohere.ai/compatibility/v1',
    model: 'command-a-plus-05-2026',
    keyUrl: 'https://dashboard.cohere.com/api-keys',
  ),
  AiProvider(
    id: 'deepseek',
    name: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com',
    model: 'deepseek-flash',
    keyUrl: 'https://platform.deepseek.com/',
  ),
  // Alibaba's keys belong to a region: a Beijing key fails abroad.
  AiProvider(
    id: 'qwen-intl',
    name: 'Qwen (Alibaba) · international',
    baseUrl: 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1',
    model: 'qwen-plus',
    keyUrl:
        'https://modelstudio.console.alibabacloud.com/model/settings/api-key',
  ),
  AiProvider(
    id: 'qwen-cn',
    name: 'Qwen (Alibaba) · China',
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    model: 'qwen-plus',
    keyUrl: 'https://bailian.console.aliyun.com/model/settings/api-key',
  ),
  AiProvider(
    id: 'kimi-intl',
    name: 'Kimi (Moonshot) · international',
    baseUrl: 'https://api.moonshot.ai/v1',
    model: 'kimi-k3.1-pro',
    keyUrl: 'https://platform.kimi.ai/console/api-keys',
  ),
  AiProvider(
    id: 'kimi-cn',
    name: 'Kimi (Moonshot) · China',
    baseUrl: 'https://api.moonshot.cn/v1',
    model: 'kimi-k3.1-pro',
    keyUrl: 'https://platform.kimi.com/console/api-keys',
  ),
  AiProvider(
    id: 'zai',
    name: 'GLM (Z.ai) · international',
    baseUrl: 'https://api.z.ai/api/paas/v4',
    model: 'glm-5.3',
    keyUrl: 'https://z.ai/manage-apikey/apikey-list',
  ),
  AiProvider(
    id: 'zhipu',
    name: 'GLM (Zhipu) · China',
    baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    model: 'glm-5.3',
    keyUrl: 'https://bigmodel.cn/usercenter/proj-mgmt/apikeys',
  ),
  AiProvider(
    id: 'minimax-intl',
    name: 'MiniMax · international',
    baseUrl: 'https://api.minimax.io/v1',
    model: 'MiniMax-M3',
  ),
  AiProvider(
    id: 'minimax-cn',
    name: 'MiniMax · China',
    baseUrl: 'https://api.minimax.cn/v1',
    model: 'MiniMax-M3',
  ),
  AiProvider(
    id: 'qianfan',
    name: 'ERNIE (Baidu Qianfan)',
    baseUrl: 'https://qianfan.baidubce.com/v2',
    model: 'ernie-5.1',
  ),
  AiProvider(
    id: 'doubao',
    name: 'Doubao (ByteDance Volcengine)',
    baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
    model: 'doubao-seed-2-1-pro-260915',
    keyUrl: 'https://ark.volcengine.com/region:cn-beijing/apikey',
  ),
  AiProvider(
    id: 'stepfun',
    name: 'StepFun',
    baseUrl: 'https://api.stepfun.com/v1',
    model: 'step-3.7-flash',
  ),
  AiProvider(
    id: 'siliconflow',
    name: 'SiliconFlow',
    baseUrl: 'https://api.siliconflow.com/v1',
    model: 'Qwen/Qwen3-32B',
    keyUrl: 'https://cloud.siliconflow.com/account/ak',
  ),
  AiProvider(
    id: 'openrouter',
    name: 'OpenRouter',
    baseUrl: 'https://openrouter.ai/api/v1',
    model: '~anthropic/claude-sonnet-latest',
    keyUrl: 'https://openrouter.ai/settings/keys',
  ),
  AiProvider(
    id: 'groq',
    name: 'Groq',
    baseUrl: 'https://api.groq.com/openai/v1',
    model: 'openai/gpt-oss-120b',
    keyUrl: 'https://console.groq.com/keys',
  ),
  AiProvider(
    id: 'together',
    name: 'Together AI',
    baseUrl: 'https://api.together.ai/v1',
    model: 'openai/gpt-oss-120b',
    keyUrl: 'https://api.together.ai/settings/projects/~current/api-keys',
  ),
  AiProvider(
    id: 'fireworks',
    name: 'Fireworks',
    baseUrl: 'https://api.fireworks.ai/inference/v1',
    model: 'accounts/fireworks/models/glm-5p3-flash',
    keyUrl: 'https://app.fireworks.ai/settings/users/api-keys',
  ),
  AiProvider(
    id: 'cerebras',
    name: 'Cerebras',
    baseUrl: 'https://api.cerebras.ai/v1',
    model: 'gpt-oss-120b',
  ),
  AiProvider(
    id: 'deepinfra',
    name: 'DeepInfra',
    baseUrl: 'https://api.deepinfra.com/v1/openai',
    model: 'deepseek-ai/DeepSeek-V4-Flash-0731',
  ),
  AiProvider(
    id: 'nvidia',
    name: 'NVIDIA NIM',
    baseUrl: 'https://integrate.api.nvidia.com/v1',
    model: 'openai/gpt-oss-120b',
    keyUrl: 'https://build.nvidia.com',
  ),
  AiProvider(
    id: 'ollama',
    name: 'Ollama (this computer)',
    baseUrl: 'http://localhost:11434/v1',
    model: 'gpt-oss:20b',
    local: true,
  ),
  AiProvider(
    id: 'lmstudio',
    name: 'LM Studio (this computer)',
    baseUrl: 'http://localhost:1234/v1',
    model: '',
    local: true,
  ),
];

/// The provider with [id], or null for a custom address.
AiProvider? aiProvider(String id) {
  for (final AiProvider p in aiProviders) {
    if (p.id == id) {
      return p;
    }
  }
  return null;
}
