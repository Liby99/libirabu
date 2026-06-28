// Selectable models for the assistant (shown in the panel's Settings). The user's choice is
// persisted (AssistantMemory key "assistant.model") and passed to the gateway as opts.model.
// Availability is per gateway project+key: the workers-ai/* ones below are allow-listed on the
// current key; the provider models (openai/anthropic) need the gateway's wholesale credits funded.

export interface ModelChoice {
  id: string;
  label: string;
  note?: string;
  needsCredits?: boolean; // provider model — only works once gateway wholesale credits are funded
}

export const MODEL_CHOICES: ModelChoice[] = [
  { id: "workers-ai/@cf/zai-org/glm-5.2", label: "GLM-5.2", note: "Z.ai · open" },
  { id: "workers-ai/@cf/openai/gpt-oss-120b", label: "gpt-oss 120B", note: "OpenAI open weights" },
  { id: "workers-ai/@cf/openai/gpt-oss-20b", label: "gpt-oss 20B", note: "smaller / faster" },
  { id: "workers-ai/@cf/qwen/qwq-32b", label: "Qwen QwQ 32B", note: "reasoning" },
  { id: "workers-ai/@cf/qwen/qwen2.5-coder-32b-instruct", label: "Qwen2.5 Coder 32B", note: "instruct" },
  { id: "openai/gpt-5.2", label: "GPT-5.2", note: "needs gateway credits", needsCredits: true },
  { id: "anthropic/claude-sonnet-4.6", label: "Claude Sonnet 4.6", note: "needs gateway credits", needsCredits: true },
];

export const FALLBACK_MODEL = "workers-ai/@cf/zai-org/glm-5.2";
