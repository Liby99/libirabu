// The `remember` tool — lets the assistant persist a durable fact to its own memory (design §16.2).
// Not audited (it writes the assistant's memory, not the user's calendar). Recall is automatic:
// the agent injects all remembered facts into the system prompt each turn.

import { remember, forget } from "../memory";
import type { AssistantTool } from "../types";

const rememberTool: AssistantTool = {
  readOnly: true,
  actionKind: "remember",
  summarize: (a) => `Remembered ${String(a.key ?? "a preference")}`,
  def: {
    name: "remember",
    description:
      "Save a DURABLE, GENERAL fact about the user so future sessions reuse it without re-asking. " +
      "REMEMBER: preferences & conventions (e.g. 'color-convention.teaching' → 'yellow', a default meeting length, a preferred timezone, naming habits), soft contacts you were given (a person's email/role), and standing constraints. " +
      "Do NOT remember: one-off chat, anything tied to a single event/date, secrets, or facts derivable from the calendar itself (don't restate existing events). " +
      "Prefer a stable dotted key ('domain.thing') and a small JSON value. If a fact changes, call remember again with the same key to update it. Keep it self-contained (a future session sees only the key+value, not this chat).",
    parameters: {
      type: "object",
      properties: {
        key: { type: "string", description: "A short stable dotted key, e.g. 'color-convention.research-meeting' or 'contact.alice'." },
        value: { description: "Any JSON value — usually a short string or small object holding the fact." },
      },
      required: ["key", "value"],
      additionalProperties: false,
    },
  },
  async run(args, ctx) {
    await remember(ctx.userId, String(args.key), args.value);
    return { ok: true, key: String(args.key), value: args.value };
  },
};

const forgetTool: AssistantTool = {
  readOnly: true,
  actionKind: "forget",
  summarize: (a) => `Forgot ${String(a.key ?? "a fact")}`,
  def: {
    name: "forget",
    description:
      "Delete a remembered fact by its key — use when a stored preference/contact is wrong or no longer applies (the user corrected it, or asked you to forget it). To CHANGE a fact, prefer calling remember with the same key instead.",
    parameters: {
      type: "object",
      properties: {
        key: { type: "string", description: "The exact key of the memory to delete." },
      },
      required: ["key"],
      additionalProperties: false,
    },
  },
  async run(args, ctx) {
    await forget(ctx.userId, String(args.key));
    return { ok: true, key: String(args.key) };
  },
};

export const memoryTools: AssistantTool[] = [rememberTool, forgetTool];
