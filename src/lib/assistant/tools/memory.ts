// The `remember` tool — lets the assistant persist a durable fact to its own memory (design §16.2).
// Not audited (it writes the assistant's memory, not the user's calendar). Recall is automatic:
// the agent injects all remembered facts into the system prompt each turn.

import { remember } from "../memory";
import type { AssistantTool } from "../types";

const rememberTool: AssistantTool = {
  readOnly: true,
  actionKind: "remember",
  summarize: (a) => `Remembered ${String(a.key ?? "a preference")}`,
  def: {
    name: "remember",
    description:
      "Save a durable fact about the user for future sessions — e.g. a color/tag convention ('color-convention.teaching' → 'yellow'), a preferred timezone, or a soft contact you were given. Use a short, stable key and a JSON value. Don't store secrets or one-off chatter; only things worth reusing later.",
    parameters: {
      type: "object",
      properties: {
        key: { type: "string", description: "A short stable key, e.g. 'color-convention.research-meeting'." },
        value: { description: "Any JSON value (string, number, object)." },
      },
      required: ["key", "value"],
      additionalProperties: false,
    },
  },
  async run(args, ctx) {
    await remember(ctx.userId, String(args.key), args.value);
    return { ok: true };
  },
};

export const memoryTools: AssistantTool[] = [rememberTool];
