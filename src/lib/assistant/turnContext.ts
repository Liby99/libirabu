// Request-scoped context for one assistant turn. The chat route wraps the agent run in
// runWithTurnContext({ conversationId }); code deep in the write path (logAiAction) then reads
// currentConversationId() to stamp each AI action with the conversation it happened in — WITHOUT
// threading the id through every function signature. Same AsyncLocalStorage pattern as apiKeys.ts.

import { AsyncLocalStorage } from "node:async_hooks";

interface TurnContext { conversationId?: string }
const als = new AsyncLocalStorage<TurnContext>();

export function runWithTurnContext<T>(ctx: TurnContext, fn: () => Promise<T>): Promise<T> {
  return als.run(ctx, fn);
}

export function currentConversationId(): string | undefined {
  return als.getStore()?.conversationId;
}
