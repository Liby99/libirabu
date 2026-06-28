// The agent loop: a ReAct/tool-calling loop over the JHU gateway. Yields SSE ServerEvents
// (text + action cards + calendar_changed). Read-only tools run directly; MUTATING tools are
// gated by the sandboxed auditor (design §5, §7). P1 enables additive create_event.

import { getLLM, type ChatMessage } from "@/lib/llm";
import { toolByName, toolDefs } from "./tools/registry";
import { plannedModulesPrompt } from "./tools/capabilities";
import { recallAll, getSelectedModel } from "./memory";
import { audit } from "./auditor";
import { buildAuditContext } from "./auditContext";
import type { ServerEvent, ViewContext } from "./types";

const MAX_STEPS = 10;

export interface AgentInput {
  userId: string;
  message: string;
  view: ViewContext;
  history?: ChatMessage[];
  attachments?: { filename: string; text: string }[];
  signal?: AbortSignal; // aborts when the user hits Stop (client closes the SSE)
}

function buildSystem(view: ViewContext, memory: Record<string, unknown>): string {
  const now = new Date();
  const today = now.toISOString().slice(0, 10);
  const weekday = now.toLocaleDateString("en-US", { weekday: "long" });
  const memoryLine = Object.keys(memory).length
    ? `What you remember about this user (reuse it; don't re-derive or re-ask): ${JSON.stringify(memory)}`
    : "";
  return [
    "You are the assistant inside libirabu, a research calendar app. You help the user understand and plan their calendar.",
    `Today is ${weekday}, ${today}.`,
    `The user's current view: year ${view.year}, zoom "${view.zoom}", focused month ${view.focusedMonth} (0=Jan)` +
      (view.focusedWeekStart ? `, week of ${view.focusedWeekStart}.` : "."),
    ...(memoryLine ? [memoryLine] : []),
    "",
    "Event kinds: 'timed' (an hourly event on one day), 'band' (a multi-day bar pinned to the year-scale track lanes — that's just WHERE it's shown; it does NOT mean the event lasts all day, so never call it 'all-day'), 'deadline' (a single moment, optionally in a timezone like AOE). Each has title, color, tags (string[]), notes (markdown), optional repeat.",
    "",
    "Tools: get_screen_state grounds 'this week'/'next month'; list_events reads the calendar; web_search then web_open look things up online; create_event adds an event; update_event edits one; delete_event removes one; set_view navigates the user's view; remember saves a durable preference for next time.",
    "",
    "You can create, edit, and delete events, and navigate the view. Creates and edits apply immediately (auditor-checked). DELETES require the user to confirm in the UI: after you call delete_event, tell the user you've QUEUED the deletion for their confirmation — do NOT say it's already deleted. To remove a single occurrence of a recurring event (a one-time skip), pass occurrenceDate to delete_event — never delete the whole series for one skip. To edit/delete, first find the event's id via list_events.",
    `Not built yet (you have NO tools for these): ${plannedModulesPrompt()}. If a request needs one, do what you CAN with the calendar (e.g. put a person's name/email or other detail into the relevant event's notes), tell the user that module isn't available yet, and never pretend you did it.`,
    "",
    "Conventions:",
    "- Colors are personal. Before choosing one, read the user's existing similar events with list_events and reuse their color/tags; don't guess. Palette: default, red, orange, yellow, green, blue, purple.",
    "- Conference CFP deadlines are almost always Anywhere-on-Earth: create a 'deadline' with originTz:\"AOE\" and originAt at 23:59 on the date.",
    "- When you learn a durable preference (a color/tag convention, a contact's details, a default), call remember so future sessions reuse it without re-asking.",
    "- To add a TODO, put a markdown checkbox in an event's notes with DSL tokens, e.g. `- [ ] submit abstract due:2026-07-01 !! #paper-submission @project:foo start:2026-06-15`. Use start: to keep not-yet-actionable items out of the feed. Use real markdown links [label](url).",
    "- Don't fabricate facts (dates, URLs). If something isn't known yet, mark it tentative, add a TODO to confirm, or ask.",
    "",
    "Every create is checked by a separate safety auditor. If a tool result says the action was denied/blocked, tell the user it was blocked and the reason — do NOT claim you made the change, and do NOT retry the same action.",
    "",
    "Response style:",
    "- Be brief and conversational. Don't pad. NEVER use markdown tables or raw HTML (no <br>, <td>) — use short bullets or plain prose.",
    "- Describe events naturally (day, time, title; for a multi-day band give its date range). Do NOT surface internal fields (color, track, tags, ids, kind) and NEVER label an event 'all-day' or mention bands/tracks — unless the user explicitly asks.",
    "- DON'T ask clarifying questions for routine requests — make the sensible default assumption and just answer. (\"next week\" = the upcoming Mon–Sun; \"my week\" = the focused week.) Only ask when a request is genuinely ambiguous, or before a consequential/irreversible change.",
    "- For overview questions (\"what's on my radar\", \"what's coming up\", \"how's my week\"): give a SHORT, prioritized highlight of just the few most important or time-sensitive items (deadlines, key meetings) — do NOT list everything. Offer to show the full list if they want it. Enumerate fully only when the user explicitly asks to list events.",
    "- Make sure any weekday you mention actually matches the date.",
  ].join("\n");
}

const errMsg = (e: unknown): string => (e instanceof Error ? e.message : String(e));

export async function* runAgent(input: AgentInput): AsyncGenerator<ServerEvent> {
  const { userId, message, view } = input;
  const memory = await recallAll(userId).catch(() => ({}));
  const model = await getSelectedModel(userId).catch(() => undefined); // user's pick; else provider default
  // The auditor sees ONLY the user's verbatim turns (never the actor's reasoning/tool output).
  const userTurns = [
    ...(input.history ?? []).filter((h) => h.role === "user").map((h) => h.content),
    message,
  ];
  // Attachment text is injected as context for the ACTOR, but deliberately kept out of `userTurns`
  // so a malicious file can't reach the injection-isolated auditor (design §7.1, §10).
  const attachmentMsgs: ChatMessage[] = (input.attachments ?? []).length
    ? [{
        role: "user",
        content: (input.attachments ?? [])
          .map((a) => `The user attached a file "${a.filename}". Its contents:\n${a.text}`)
          .join("\n\n---\n\n"),
      }]
    : [];

  const messages: ChatMessage[] = [
    { role: "system", content: buildSystem(view, memory) },
    ...(input.history ?? []),
    ...attachmentMsgs,
    { role: "user", content: message },
  ];

  for (let step = 0; step < MAX_STEPS; step++) {
    if (input.signal?.aborted) return; // user hit Stop between steps
    let result;
    try {
      // gpt-oss emits hidden reasoning before the visible answer; without a generous budget the
      // gateway's small default max_tokens is consumed by reasoning → empty content (finish=length).
      result = await getLLM().chat(messages, { tools: toolDefs, maxTokens: 2048, signal: input.signal, model });
    } catch (e) {
      if (input.signal?.aborted) return; // aborted mid-call — end quietly
      yield { t: "error", message: errMsg(e) };
      return;
    }

    const m = result.message;
    const calls = m.toolCalls ?? [];
    console.log(`[asst] step ${step} finish=${result.finishReason} contentLen=${(m.content || "").trim().length} tools=${calls.length}`);
    if (m.content && m.content.trim()) yield { t: "text", delta: m.content };

    if (calls.length === 0) {
      // Don't end silently: if the model produced nothing this turn, say why (so a long
      // "thinking…" that suddenly drops is explained, not blank).
      if (!m.content || !m.content.trim()) {
        yield {
          t: "text",
          delta: result.finishReason === "length"
            ? "⚠️ I hit my output limit before answering — the request may be too complex for this model. Tap **Retry**, or try breaking it into smaller steps."
            : "⚠️ The model returned an empty response. Tap **Retry** to try again.",
        };
      }
      yield { t: "done" };
      return;
    }

    messages.push({ role: "assistant", content: m.content ?? "", toolCalls: calls });

    for (const call of calls) {
      const tool = toolByName.get(call.name);
      if (!tool) {
        messages.push({ role: "tool", content: JSON.stringify({ error: `unknown tool ${call.name}` }), toolCallId: call.id });
        continue;
      }
      let summary = call.name;
      try { summary = tool.summarize(call.arguments); } catch { /* keep name */ }
      console.log(`[asst] call ${call.name} ${JSON.stringify(call.arguments).slice(0, 240)}`);
      yield { t: "action", id: call.id, kind: tool.actionKind, status: "running", summary };

      // Mutating tools: run the sandboxed auditor first, with server-built (trusted) calendar
      // context — today + existing events on the proposed day. The auditor never calls tools itself.
      if (!tool.readOnly) {
        const auditCtx = await buildAuditContext(userId, call.arguments).catch(() => "");
        const verdict = await audit(userTurns, { name: call.name, arguments: call.arguments }, auditCtx, model);
        if (verdict.decision === "deny") {
          console.log(`[asst] BLOCKED ${call.name}: ${verdict.reason}`);
          yield { t: "action", id: call.id, kind: tool.actionKind, status: "blocked", summary: `Blocked: ${summary}`, detail: { reason: verdict.reason } };
          messages.push({ role: "tool", content: JSON.stringify({ denied: true, reason: verdict.reason }), toolCallId: call.id });
          continue;
        }
      }

      // Confirm-gated tools (delete): resolve the spec (no mutation) and STAGE it — the user
      // must click Confirm in the UI, which calls /api/assistant/execute to actually run it.
      if (tool.confirm) {
        try {
          const spec = await tool.run(call.arguments, { userId, view });
          yield { t: "action", id: call.id, kind: tool.actionKind, status: "confirm", summary, detail: spec };
          messages.push({ role: "tool", content: JSON.stringify({ staged: true, awaiting_user_confirmation: true, spec }), toolCallId: call.id });
        } catch (e) {
          const msg = errMsg(e);
          yield { t: "action", id: call.id, kind: tool.actionKind, status: "error", summary, detail: { error: msg } };
          messages.push({ role: "tool", content: JSON.stringify({ error: msg }), toolCallId: call.id });
        }
        continue;
      }

      try {
        const out = await tool.run(call.arguments, { userId, view });
        if (!tool.readOnly) console.log(`[asst] OK ${call.name}`);
        yield { t: "action", id: call.id, kind: tool.actionKind, status: "done", summary, detail: out };
        if (!tool.readOnly && out) yield { t: "calendar_changed", items: [out] };
        if (tool.actionKind === "set_view" && out) yield { t: "view_change", view: out as Partial<ViewContext> };
        messages.push({ role: "tool", content: JSON.stringify(out), toolCallId: call.id });
      } catch (e) {
        const msg = errMsg(e);
        console.log(`[asst] ERROR ${call.name}: ${msg}`);
        yield { t: "action", id: call.id, kind: tool.actionKind, status: "error", summary, detail: { error: msg } };
        messages.push({ role: "tool", content: JSON.stringify({ error: msg }), toolCallId: call.id });
      }
    }
  }

  yield { t: "text", delta: "⚠️ I stopped after several steps without finishing — this task may be too large for one turn. Tap **Retry**, or break it into smaller requests." };
  yield { t: "done" };
}
