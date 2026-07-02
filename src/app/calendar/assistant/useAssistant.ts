"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import type { ModelChoice } from "@/lib/assistant/models";

export interface ConversationMeta { id: string; title: string; updatedAt: string }
export interface AssistantSettings { model: string; models: ModelChoice[] }

// Client transcript types (mirror the server's ServerEvent stream).
export interface ActionBlock {
  type: "action";
  id: string;
  kind: string;
  status: "running" | "done" | "error" | "blocked" | "confirm" | "cancelled";
  summary: string;
  detail?: unknown;
}
export interface TextBlock { type: "text"; text: string }
export interface ThinkingBlock { type: "thinking"; content: string } // reasoning-model "thinking" (collapsed)
export type Block = TextBlock | ThinkingBlock | ActionBlock;

export interface UploadedAttachment { filename: string; text: string; bytes?: number }

export type Message =
  | { role: "user"; text: string; attachments?: { filename: string }[] }
  | { role: "assistant"; blocks: Block[] };

interface ViewContext {
  year: number;
  zoom: "year" | "month" | "week";
  focusedMonth: number;
  focusedWeekStart?: string;
}

// The calendar persists the view to the URL (?y=YYYY&m=1-12&w=1-based). Read it
// so the assistant knows what the user is looking at, without coupling to the canvas.
function readView(): ViewContext {
  const sp = new URLSearchParams(typeof window !== "undefined" ? window.location.search : "");
  const year = Number(sp.get("y")) || new Date().getFullYear();
  const mRaw = sp.get("m");
  const wRaw = sp.get("w");
  const zoom: ViewContext["zoom"] = wRaw ? "week" : mRaw ? "month" : "year";
  return { year, zoom, focusedMonth: mRaw ? Math.max(0, Math.min(11, Number(mRaw) - 1)) : 0 };
}

// Compact text-only history of finalized turns, for conversational continuity across turns.
function historyOf(base: Message[]) {
  return base.map((m) =>
    m.role === "user"
      ? { role: "user" as const, content: m.text }
      : { role: "assistant" as const, content: m.blocks.filter((b): b is TextBlock => b.type === "text").map((b) => b.text).join("\n") },
  ).filter((m) => m.content.trim().length > 0);
}

// A short human phrase describing an allowed action's result (fed to the resumed agent).
function describeResult(r: unknown): string {
  const o = r && typeof r === "object" ? (r as Record<string, unknown>) : {};
  if (o.title && o.kind) return `${o.kind} "${o.title}"`;
  if (o.mode) return `deleted ${o.mode === "occurrence" ? "an occurrence" : "the series"}`;
  return "";
}

export function useAssistant() {
  const [messages, setMessages] = useState<Message[]>([]);
  const [busy, setBusy] = useState(false);
  const messagesRef = useRef<Message[]>([]);
  messagesRef.current = messages;
  const abortRef = useRef<AbortController | null>(null);
  const convIdRef = useRef<string | null>(null); // id of the conversation being persisted/resumed
  const prevBusyRef = useRef(false);

  // Mutate the last (assistant) message in place as events stream in.
  const patchAssistant = useCallback((fn: (blocks: Block[]) => Block[]) =>
    setMessages((prev) => {
      const next = prev.slice();
      const last = next[next.length - 1];
      if (last && last.role === "assistant") next[next.length - 1] = { role: "assistant", blocks: fn(last.blocks) };
      return next;
    }), []);

  const apply = useCallback((ev: { t: string } & Record<string, unknown>) => {
      if (ev.t === "text") {
        patchAssistant((blocks) => {
          const copy = blocks.slice();
          const last = copy[copy.length - 1];
          if (last && last.type === "text") copy[copy.length - 1] = { type: "text", text: last.text + (last.text ? "\n\n" : "") + String(ev.delta) };
          else copy.push({ type: "text", text: String(ev.delta) });
          return copy;
        });
      } else if (ev.t === "thinking") {
        patchAssistant((blocks) => {
          const copy = blocks.slice();
          const last = copy[copy.length - 1];
          if (last && last.type === "thinking") copy[copy.length - 1] = { type: "thinking", content: last.content + "\n" + String(ev.content) };
          else copy.push({ type: "thinking", content: String(ev.content) });
          return copy;
        });
      } else if (ev.t === "action") {
        patchAssistant((blocks) => {
          const copy = blocks.slice();
          const idx = copy.findIndex((b) => b.type === "action" && b.id === ev.id);
          const block: ActionBlock = { type: "action", id: String(ev.id), kind: String(ev.kind), status: ev.status as ActionBlock["status"], summary: String(ev.summary), detail: ev.detail };
          if (idx >= 0) copy[idx] = block;
          else copy.push(block);
          return copy;
        });
      } else if (ev.t === "calendar_changed") {
        // Tell the calendar stores to refetch so the canvas reflects the assistant's write.
        if (typeof window !== "undefined") window.dispatchEvent(new CustomEvent("calendar:changed"));
      } else if (ev.t === "view_change") {
        // Ask the canvas to navigate (year/month/zoom).
        if (typeof window !== "undefined") window.dispatchEvent(new CustomEvent("calendar:setview", { detail: ev.view }));
      } else if (ev.t === "navigate") {
        // Follow the agent to the event it just touched (and open its drawer for edits).
        if (typeof window !== "undefined") window.dispatchEvent(new CustomEvent("calendar:navigate", { detail: ev }));
      } else if (ev.t === "error") {
        patchAssistant((blocks) => [...blocks, { type: "text", text: `⚠️ ${String(ev.message)}` }]);
      }
    }, [patchAssistant]);

  // Stream one agent turn into the LAST (assistant) message. The caller is responsible for having
  // added that placeholder and set busy; this handles the fetch, SSE parse, and teardown.
  const streamTurn = useCallback(async (body: { message: string; history: ReturnType<typeof historyOf>; attachments?: { filename: string; text: string }[] }) => {
    const controller = new AbortController();
    abortRef.current = controller;
    try {
      const res = await fetch("/api/assistant/chat", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ message: body.message, view: readView(), history: body.history, attachments: body.attachments ?? [] }),
        signal: controller.signal,
      });
      if (!res.ok || !res.body) {
        apply({ t: "error", message: `Request failed (${res.status})` });
        return;
      }
      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buf = "";
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        buf += decoder.decode(value, { stream: true });
        const parts = buf.split("\n\n");
        buf = parts.pop() ?? "";
        for (const part of parts) {
          const line = part.trim();
          if (!line.startsWith("data:")) continue;
          try {
            apply(JSON.parse(line.slice(5).trim()));
          } catch {
            /* ignore malformed frame */
          }
        }
      }
    } catch (e) {
      // A user-initiated Stop aborts the fetch — that's not an error, just end quietly.
      if ((e as Error)?.name !== "AbortError") apply({ t: "error", message: e instanceof Error ? e.message : "Network error" });
    } finally {
      abortRef.current = null;
      setBusy(false);
    }
  }, [apply]);

  const send = useCallback(async (text: string, attachments: UploadedAttachment[] = [], baseMessages?: Message[]) => {
    const trimmed = text.trim();
    if (!trimmed || busy) return;
    // `baseMessages` lets Retry re-run a prompt against the transcript BEFORE the failed turn.
    const base = baseMessages ?? messagesRef.current;
    const history = historyOf(base);
    setMessages([...base, { role: "user", text: trimmed, attachments: attachments.map((a) => ({ filename: a.filename })) }, { role: "assistant", blocks: [] }]);
    setBusy(true);
    await streamTurn({ message: trimmed, history, attachments: attachments.map((a) => ({ filename: a.filename, text: a.text })) });
  }, [busy, streamTurn]);

  // Stop the in-flight turn: aborting the fetch tears down the SSE stream and (via the request's
  // signal on the server) halts the agent loop. Any still-"running" action card → "cancelled".
  const stop = useCallback(() => {
    abortRef.current?.abort();
    setMessages((prev) => prev.map((m) =>
      m.role === "assistant"
        ? { role: "assistant", blocks: m.blocks.map((b) => (b.type === "action" && b.status === "running" ? { ...b, status: "cancelled" as const } : b)) }
        : m,
    ));
  }, []);

  // Re-run the most recent user prompt (resurrect a turn that errored / dropped / hit a limit).
  // Re-sends against the transcript before that prompt, replacing the failed assistant turn.
  const retry = useCallback(() => {
    if (busy) return;
    const msgs = messagesRef.current;
    let i = -1;
    for (let k = msgs.length - 1; k >= 0; k--) { if (msgs[k].role === "user") { i = k; break; } }
    if (i < 0) return;
    const u = msgs[i] as { role: "user"; text: string };
    send(u.text, [], msgs.slice(0, i));
  }, [busy, send]);

  // ── Persistent conversations (AIConversation/AIMessage) ──
  // Save the full transcript after each turn completes (busy → false). We keep an action's `detail`
  // when it's small (event/delete/view payloads → the expandable card survives a reload), but drop
  // bulky ones (web-page text/search results) to keep rows lean.
  const saveConversation = useCallback(async () => {
    const msgs = messagesRef.current;
    if (!msgs.length) return;
    const keepDetail = (detail: unknown) => detail != null && JSON.stringify(detail).length < 4000;
    const payload = msgs.map((m) =>
      m.role === "user"
        ? { role: "user", text: m.text, attachments: m.attachments ?? [] }
        : { role: "assistant", blocks: m.blocks.filter((b) => b.type !== "thinking").map((b) => (b.type === "action" ? { type: "action", id: b.id, kind: b.kind, status: b.status, summary: b.summary, ...(keepDetail(b.detail) ? { detail: b.detail } : {}) } : b)) },
    );
    try {
      const res = await fetch("/api/assistant/conversations", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ id: convIdRef.current, messages: payload }) });
      if (res.ok) convIdRef.current = (await res.json()).id;
    } catch { /* best-effort persistence */ }
  }, []);

  useEffect(() => {
    if (prevBusyRef.current && !busy) void saveConversation();
    prevBusyRef.current = busy;
  }, [busy, saveConversation]);

  const newConversation = useCallback(() => { setMessages([]); convIdRef.current = null; }, []);

  const listConversations = useCallback(async (): Promise<ConversationMeta[]> => {
    try { const res = await fetch("/api/assistant/conversations"); return res.ok ? (await res.json()).conversations : []; } catch { return []; }
  }, []);

  const loadConversation = useCallback(async (id: string) => {
    try {
      const res = await fetch(`/api/assistant/conversations/${id}`);
      if (!res.ok) return;
      const data = await res.json();
      // Stale interactive states (a half-finished confirm/running card) → cancelled on reload.
      const msgs = (data.messages as Message[]).map((m) =>
        m.role === "assistant"
          ? { role: "assistant" as const, blocks: m.blocks.map((b) => (b.type === "action" && (b.status === "running" || b.status === "confirm") ? { ...b, status: "cancelled" as const } : b)) }
          : m,
      );
      setMessages(msgs);
      convIdRef.current = id;
    } catch { /* ignore */ }
  }, []);

  const deleteConversation = useCallback(async (id: string) => {
    try { await fetch(`/api/assistant/conversations/${id}`, { method: "DELETE" }); } catch { /* ignore */ }
    if (convIdRef.current === id) newConversation();
  }, [newConversation]);

  const getSettings = useCallback(async (): Promise<AssistantSettings> => {
    try { const res = await fetch("/api/assistant/settings"); return res.ok ? await res.json() : { model: "", models: [] }; } catch { return { model: "", models: [] }; }
  }, []);
  const setModel = useCallback(async (model: string) => {
    try { await fetch("/api/assistant/settings", { method: "PUT", headers: { "content-type": "application/json" }, body: JSON.stringify({ model }) }); } catch { /* ignore */ }
  }, []);

  // "Clear" now means "new chat": the previous conversation is already saved and browsable.
  const clear = useCallback(() => newConversation(), [newConversation]);

  const updateBlock = useCallback((blockId: string, patch: Partial<ActionBlock>) => {
    setMessages((prev) => prev.map((m) =>
      m.role === "assistant"
        ? { role: "assistant", blocks: m.blocks.map((b) => (b.type === "action" && b.id === blockId ? { ...b, ...patch } : b)) }
        : m,
    ));
  }, []);

  // Human-in-the-loop for confirm-gated actions (delete): on Confirm, actually execute via
  // /api/assistant/execute; on Cancel, just mark the card cancelled.
  const resolveDelete = useCallback(async (blockId: string, confirmed: boolean) => {
    let detail: unknown;
    for (const m of messagesRef.current) {
      if (m.role !== "assistant") continue;
      const b = m.blocks.find((x) => x.type === "action" && x.id === blockId);
      if (b) { detail = (b as ActionBlock).detail; break; }
    }
    if (!confirmed) { updateBlock(blockId, { status: "cancelled", summary: "Deletion cancelled" }); return; }
    const d = detail as { id?: string; occurrenceDate?: string | null; title?: string } | undefined;
    if (!d?.id) { updateBlock(blockId, { status: "error", summary: "Couldn't resolve the event" }); return; }
    updateBlock(blockId, { status: "running" });
    try {
      const res = await fetch("/api/assistant/execute", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ action: "delete", id: d.id, ...(d.occurrenceDate ? { occurrenceDate: d.occurrenceDate } : {}) }),
      });
      if (!res.ok) { updateBlock(blockId, { status: "error", summary: "Delete failed" }); return; }
      updateBlock(blockId, { status: "done", summary: d.occurrenceDate ? "Removed this occurrence" : `Deleted "${d.title ?? "event"}"` });
      if (typeof window !== "undefined") window.dispatchEvent(new CustomEvent("calendar:changed"));
    } catch {
      updateBlock(blockId, { status: "error", summary: "Delete failed" });
    }
  }, [updateBlock]);

  // Override an auditor-blocked action ("Allow"): re-run the exact tool call with the auditor
  // bypassed via /api/assistant/allow, then RESUME the agent so it continues the task.
  const allowAction = useCallback(async (blockId: string) => {
    if (busy) return; // don't override mid-turn
    let detail: unknown;
    for (const m of messagesRef.current) {
      if (m.role !== "assistant") continue;
      const b = m.blocks.find((x) => x.type === "action" && x.id === blockId);
      if (b) { detail = (b as ActionBlock).detail; break; }
    }
    const d = detail as { name?: string; arguments?: Record<string, unknown> } | undefined;
    if (!d?.name) { updateBlock(blockId, { status: "error", summary: "Can't override this action" }); return; }
    updateBlock(blockId, { status: "running", summary: "Applying (overridden)…" });
    let result: unknown;
    try {
      const res = await fetch("/api/assistant/allow", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ name: d.name, arguments: d.arguments ?? {} }),
      });
      if (!res.ok) { updateBlock(blockId, { status: "error", summary: "Override failed" }); return; }
      result = (await res.json()).result;
    } catch {
      updateBlock(blockId, { status: "error", summary: "Override failed" });
      return;
    }
    if (typeof window !== "undefined") window.dispatchEvent(new CustomEvent("calendar:changed"));
    // In ONE update: flip the card to done AND append a fresh assistant placeholder (no user
    // bubble), then resume the agent so it continues the original task from where it was blocked.
    const done = messagesRef.current.map((m) =>
      m.role === "assistant"
        ? { role: "assistant" as const, blocks: m.blocks.map((b) => (b.type === "action" && b.id === blockId ? { ...b, status: "done" as const, summary: "Applied — you allowed it", detail: result } : b)) }
        : m,
    );
    setMessages([...done, { role: "assistant", blocks: [] }]);
    setBusy(true);
    const brief = describeResult(result);
    await streamTurn({
      message: `The action you proposed was approved by the user and has now been completed${brief ? ` (${brief})` : ""}. It is done — do NOT repeat it. Continue with any remaining steps of the original request; if nothing remains, briefly confirm what's done.`,
      history: historyOf(done),
    });
  }, [busy, updateBlock, streamTurn]);

  return { messages, busy, send, stop, retry, clear, resolveDelete, allowAction, listConversations, loadConversation, deleteConversation, getSettings, setModel };
}
