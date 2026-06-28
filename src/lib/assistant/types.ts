// Shared types for the AI assistant (P0 — read-only skeleton).
// See docs/ai-assistant-design.md (§5 agent loop, §6 protocols, §6.3 tools).

import type { ToolDef } from "@/lib/llm";

/** Client snapshot of the calendar view, sent with each request (design §8). */
export interface ViewContext {
  year: number;
  zoom: "year" | "month" | "week";
  focusedMonth: number; // 0–11
  focusedWeekStart?: string; // "YYYY-MM-DD"
}

/** A high-level action card kind, surfaced as a bubble in the chat (design §4.3). */
export type ActionKind =
  | "get_screen_state"
  | "read_calendar"
  | "web_search"
  | "web_open"
  | "create_event"
  | "update_event"
  | "delete_event"
  | "set_view"
  | "remember";

/** Server→client SSE events (design §6.1). */
export type ServerEvent =
  | { t: "text"; delta: string }
  | { t: "action"; id: string; kind: ActionKind; status: "running" | "done" | "error" | "blocked" | "confirm"; summary: string; detail?: unknown }
  | { t: "calendar_changed"; items: unknown[] }
  | { t: "view_change"; view: Partial<ViewContext> }
  | { t: "error"; message: string }
  | { t: "done" };

/** Context handed to every tool's run(). */
export interface ToolContext {
  userId: string;
  view: ViewContext;
}

/** A tool the agent can call: its function-calling schema + an executor. */
export interface AssistantTool {
  def: ToolDef;
  /** false → mutating: gated by the auditor and emits calendar_changed (design §7). */
  readOnly: boolean;
  /** The action-card kind to surface when this tool runs. */
  actionKind: ActionKind;
  /** A short, human summary of an invocation (for the action bubble). */
  summarize: (args: Record<string, unknown>) => string;
  run: (args: Record<string, unknown>, ctx: ToolContext) => Promise<unknown>;
}
