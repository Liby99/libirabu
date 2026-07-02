import type {
  ChatMessage,
  ChatOptions,
  ChatResult,
  LLMProvider,
  ToolCall,
} from "./types";

// JHU WSE AI Gateway provider (OpenAI-compatible "compat" route). Server-side only.
//
// VERIFIED against the WSE AI Gateway docs (gateway.engineering.jhu.edu/docs):
//  - Base URL:  https://gateway.engineering.jhu.edu/gateway   (set as JHU_GATEWAY_URL)
//  - Route:     POST {base}/compat/chat/completions           (OpenAI chat-completions shape)
//  - Auth:      Authorization: Bearer jhu_live_sk_...         (a *gateway project key*)
//  - Models:    provider-prefixed, e.g. "anthropic/claude-sonnet-4.6", "openai/gpt-5.2",
//               "workers-ai/@cf/<org>/<model>" for cheap/open tiers.
//  - Setup:     the model must be allow-listed on BOTH the project and the key.
//  - ⚠ Beta:    streaming is "not yet in the supported path" — the agent loop uses the
//               non-streaming chat() below; streamChat() is best-effort only.

const DEFAULT_MODEL = process.env.JHU_GATEWAY_MODEL ?? "anthropic/claude-sonnet-4.6";

function endpoint(): { url: string; key: string } {
  const base = process.env.JHU_GATEWAY_URL;
  const key = process.env.JHU_GATEWAY_KEY;
  if (!base) throw new Error("JHU_GATEWAY_URL is not set");
  if (!key) throw new Error("JHU_GATEWAY_KEY is not set");
  return { url: `${base.replace(/\/$/, "")}/compat/chat/completions`, key };
}

function toApiMessages(messages: ChatMessage[]) {
  return messages.map((m) => {
    if (m.role === "tool") {
      return { role: "tool", content: m.content, tool_call_id: m.toolCallId };
    }
    if (m.role === "assistant" && m.toolCalls?.length) {
      return {
        // Workers-AI compat requires content to be a string (rejects null) on tool-call turns.
        role: "assistant",
        content: m.content || "",
        tool_calls: m.toolCalls.map((t) => ({
          id: t.id,
          type: "function",
          function: { name: t.name, arguments: JSON.stringify(t.arguments) },
        })),
      };
    }
    return { role: m.role, content: m.content };
  });
}

function toApiTools(opts?: ChatOptions) {
  if (!opts?.tools?.length) return undefined;
  return opts.tools.map((t) => ({
    type: "function",
    function: {
      name: t.name,
      description: t.description,
      parameters: t.parameters,
    },
  }));
}

export class JhuGatewayProvider implements LLMProvider {
  readonly name = "jhu-gateway";

  async chat(messages: ChatMessage[], opts?: ChatOptions): Promise<ChatResult> {
    const { url, key } = endpoint();
    const body = JSON.stringify({
      model: opts?.model ?? DEFAULT_MODEL,
      messages: toApiMessages(messages),
      tools: toApiTools(opts),
      temperature: opts?.temperature,
      max_tokens: opts?.maxTokens,
    });
    // The gateway/upstream throws intermittent 5xx (AiError "Internal server error"); retry those
    // with backoff. 4xx (bad request) and 402 (credits) are not retried.
    const res = await fetchWithRetry(url, key, body, opts?.signal);
    const data = await res.json();
    const choice = data.choices?.[0];
    const msg = choice?.message ?? {};
    const toolCalls: ToolCall[] | undefined = msg.tool_calls?.map(
      (t: { id: string; function: { name: string; arguments: string } }) => ({
        id: t.id,
        name: t.function.name,
        arguments: (safeParse(t.function.arguments) as Record<string, unknown>) ?? {},
      }),
    );
    // Reasoning models expose their "thinking" either as a sibling field (`reasoning_content` —
    // vLLM/DeepSeek convention — or `reasoning`), or inline as a `<think>…</think>` block in
    // content. Capture whichever is present; strip an inline block out of the visible content.
    let content: string = msg.content ?? "";
    let reasoning: string | undefined = msg.reasoning_content ?? msg.reasoning ?? undefined;
    const think = content.match(/<think>([\s\S]*?)<\/think>/i);
    if (think) {
      reasoning = reasoning ?? think[1].trim();
      content = content.replace(/<think>[\s\S]*?<\/think>/i, "").trim();
    }
    return {
      message: {
        role: "assistant",
        content,
        toolCalls,
        ...(reasoning ? { reasoning } : {}),
      },
      finishReason: choice?.finish_reason ?? "stop",
    };
  }

  async *streamChat(
    messages: ChatMessage[],
    opts?: ChatOptions,
  ): AsyncIterable<string> {
    const { url, key } = endpoint();
    const res = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${key}`,
      },
      body: JSON.stringify({
        model: opts?.model ?? DEFAULT_MODEL,
        messages: toApiMessages(messages),
        temperature: opts?.temperature,
        max_tokens: opts?.maxTokens,
        stream: true,
      }),
      signal: opts?.signal,
    });
    if (!res.ok || !res.body) {
      throw new Error(`JHU gateway stream error ${res.status}`);
    }
    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";
      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed.startsWith("data:")) continue;
        const payload = trimmed.slice(5).trim();
        if (payload === "[DONE]") return;
        const parsed = safeParse(payload) as { choices?: { delta?: { content?: string } }[] } | undefined;
        const delta = parsed?.choices?.[0]?.delta?.content;
        if (delta) yield delta;
      }
    }
  }
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// POST to the gateway, retrying transient failures (HTTP >= 500, 429, and network errors).
// Returns a successful Response, or throws with the last error body on permanent failure.
async function fetchWithRetry(url: string, key: string, body: string, signal?: AbortSignal): Promise<Response> {
  const MAX_ATTEMPTS = 3;
  let lastDetail = "";
  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
    let res: Response | undefined;
    try {
      res = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}` },
        body,
        signal,
      });
    } catch (e) {
      lastDetail = e instanceof Error ? e.message : String(e);
      if (attempt < MAX_ATTEMPTS) { await sleep(400 * attempt); continue; }
      throw new Error(`JHU gateway request failed: ${lastDetail}`);
    }
    if (res.ok) return res;
    lastDetail = `${res.status}: ${await res.text()}`;
    const transient = res.status >= 500 || res.status === 429;
    if (transient && attempt < MAX_ATTEMPTS) { await sleep(400 * attempt); continue; }
    throw new Error(`JHU gateway error ${lastDetail}`);
  }
  throw new Error(`JHU gateway error ${lastDetail}`);
}

function safeParse(s: string): unknown {
  try {
    return JSON.parse(s);
  } catch {
    return undefined;
  }
}
