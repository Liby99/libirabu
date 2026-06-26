import type {
  ChatMessage,
  ChatOptions,
  ChatResult,
  LLMProvider,
  ToolCall,
} from "./types";

// JHU gateway provider (OpenAI-compatible Chat Completions). Server-side only.
//
// STUB STATUS: the request/response shapes below assume a standard OpenAI-compatible
// endpoint. Before relying on this, confirm against the gateway: (a) exact base path
// (/v1/chat/completions?), (b) auth header, (c) model ids, (d) tool/function-calling
// support, (e) streaming format. See DESIGN.md §6/§8.2.

const DEFAULT_MODEL = process.env.JHU_GATEWAY_MODEL ?? "gpt-4o";

function endpoint(): { url: string; key: string } {
  const base = process.env.JHU_GATEWAY_URL;
  const key = process.env.JHU_GATEWAY_KEY;
  if (!base) throw new Error("JHU_GATEWAY_URL is not set");
  if (!key) throw new Error("JHU_GATEWAY_KEY is not set");
  return { url: `${base.replace(/\/$/, "")}/v1/chat/completions`, key };
}

function toApiMessages(messages: ChatMessage[]) {
  return messages.map((m) => {
    if (m.role === "tool") {
      return { role: "tool", content: m.content, tool_call_id: m.toolCallId };
    }
    if (m.role === "assistant" && m.toolCalls?.length) {
      return {
        role: "assistant",
        content: m.content || null,
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
    const res = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${key}`,
      },
      body: JSON.stringify({
        model: opts?.model ?? DEFAULT_MODEL,
        messages: toApiMessages(messages),
        tools: toApiTools(opts),
        temperature: opts?.temperature,
        max_tokens: opts?.maxTokens,
      }),
      signal: opts?.signal,
    });
    if (!res.ok) {
      throw new Error(`JHU gateway error ${res.status}: ${await res.text()}`);
    }
    const data = await res.json();
    const choice = data.choices?.[0];
    const msg = choice?.message ?? {};
    const toolCalls: ToolCall[] | undefined = msg.tool_calls?.map(
      (t: { id: string; function: { name: string; arguments: string } }) => ({
        id: t.id,
        name: t.function.name,
        arguments: safeParse(t.function.arguments),
      }),
    );
    return {
      message: {
        role: "assistant",
        content: msg.content ?? "",
        toolCalls,
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
        const delta = safeParse(payload)?.choices?.[0]?.delta?.content;
        if (delta) yield delta as string;
      }
    }
  }
}

function safeParse(s: string): any {
  try {
    return JSON.parse(s);
  } catch {
    return undefined;
  }
}
