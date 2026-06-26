// Provider-agnostic LLM interface. Swapping JHU gateway ↔ Bedrock ↔ Anthropic is a
// new file implementing this interface — no feature code changes. See DESIGN.md §6.

export type ChatRole = "system" | "user" | "assistant" | "tool";

export interface ChatMessage {
  role: ChatRole;
  content: string;
  /** present on assistant turns that call tools */
  toolCalls?: ToolCall[];
  /** present on role:"tool" turns, echoing the call this responds to */
  toolCallId?: string;
}

export interface ToolCall {
  id: string;
  name: string;
  arguments: Record<string, unknown>;
}

/** A tool the model may call. `parameters` is a JSON Schema object. */
export interface ToolDef {
  name: string;
  description: string;
  parameters: Record<string, unknown>;
}

export interface ChatOptions {
  model?: string;
  temperature?: number;
  tools?: ToolDef[];
  maxTokens?: number;
  signal?: AbortSignal;
}

export interface ChatResult {
  message: ChatMessage;
  finishReason: "stop" | "tool_calls" | "length" | string;
}

export interface LLMProvider {
  readonly name: string;
  chat(messages: ChatMessage[], opts?: ChatOptions): Promise<ChatResult>;
  streamChat(
    messages: ChatMessage[],
    opts?: ChatOptions,
  ): AsyncIterable<string>;
}
