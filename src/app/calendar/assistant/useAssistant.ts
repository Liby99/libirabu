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
export type Block = TextBlock | ActionBlock;

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

export function useAssistant() {
  const [messages, setMessages] = useState<Message[]>([]);
  const [busy, setBusy] = useState(false);
  const messagesRef = useRef<Message[]>([]);
  messagesRef.current = messages;
  const abortRef = useRef<AbortController | null>(null);
  const convIdRef = useRef<string | null>(null); // id of the conversation being persisted/resumed
  const prevBusyRef = useRef(false);

  const send = useCallback(async (text: string, attachments: UploadedAttachment[] = [], baseMessages?: Message[]) => {
    const trimmed = text.trim();
    if (!trimmed || busy) return;

    // `baseMessages` lets Retry re-run a prompt against the transcript BEFORE the failed turn.
    const base = baseMessages ?? messagesRef.current;
    // Compact history of finalized turns (text only) for conversational continuity.
    const history = base.map((m) =>
      m.role === "user"
        ? { role: "user" as const, content: m.text }
        : { role: "assistant" as const, content: m.blocks.filter((b): b is TextBlock => b.type === "text").map((b) => b.text).join("\n") },
    ).filter((m) => m.content.trim().length > 0);

    setMessages([...base, { role: "user", text: trimmed, attachments: attachments.map((a) => ({ filename: a.filename })) }, { role: "assistant", blocks: [] }]);
    setBusy(true);

    // Mutate the last (assistant) message in place as events stream in.
    const patchAssistant = (fn: (blocks: Block[]) => Block[]) =>
      setMessages((prev) => {
        const next = prev.slice();
        const last = next[next.length - 1];
        if (last && last.role === "assistant") next[next.length - 1] = { role: "assistant", blocks: fn(last.blocks) };
        return next;
      });

    const apply = (ev: { t: string } & Record<string, unknown>) => {
      if (ev.t === "text") {
        patchAssistant((blocks) => {
          const copy = blocks.slice();
          const last = copy[copy.length - 1];
          if (last && last.type === "text") copy[copy.length - 1] = { type: "text", text: last.text + (last.text ? "\n\n" : "") + String(ev.delta) };
          else copy.push({ type: "text", text: String(ev.delta) });
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
      } else if (ev.t === "error") {
        patchAssistant((blocks) => [...blocks, { type: "text", text: `⚠️ ${String(ev.message)}` }]);
      }
    };

    const controller = new AbortController();
    abortRef.current = controller;
    try {
      const res = await fetch("/api/assistant/chat", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ message: trimmed, view: readView(), history, attachments: attachments.map((a) => ({ filename: a.filename, text: a.text })) }),
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
  }, [busy]);

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
  // Save the full transcript after each turn completes (busy → false). Action `detail` is dropped
  // to keep rows small; it isn't needed to redisplay a past chat.
  const saveConversation = useCallback(async () => {
    const msgs = messagesRef.current;
    if (!msgs.length) return;
    const payload = msgs.map((m) =>
      m.role === "user"
        ? { role: "user", text: m.text, attachments: m.attachments ?? [] }
        : { role: "assistant", blocks: m.blocks.map((b) => (b.type === "action" ? { type: "action", id: b.id, kind: b.kind, status: b.status, summary: b.summary } : b)) },
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

  return { messages, busy, send, stop, retry, clear, resolveDelete, listConversations, loadConversation, deleteConversation, getSettings, setModel };
}
