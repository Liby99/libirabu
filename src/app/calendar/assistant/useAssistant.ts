"use client";

import { useCallback, useRef, useState } from "react";

// Client transcript types (mirror the server's ServerEvent stream).
export interface ActionBlock {
  type: "action";
  id: string;
  kind: string;
  status: "running" | "done" | "error" | "blocked";
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

  const send = useCallback(async (text: string, attachments: UploadedAttachment[] = []) => {
    const trimmed = text.trim();
    if (!trimmed || busy) return;

    // Compact history of finalized turns (text only) for conversational continuity.
    const history = messagesRef.current.map((m) =>
      m.role === "user"
        ? { role: "user" as const, content: m.text }
        : { role: "assistant" as const, content: m.blocks.filter((b): b is TextBlock => b.type === "text").map((b) => b.text).join("\n") },
    ).filter((m) => m.content.trim().length > 0);

    setMessages((prev) => [...prev, { role: "user", text: trimmed, attachments: attachments.map((a) => ({ filename: a.filename })) }, { role: "assistant", blocks: [] }]);
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

    try {
      const res = await fetch("/api/assistant/chat", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ message: trimmed, view: readView(), history, attachments: attachments.map((a) => ({ filename: a.filename, text: a.text })) }),
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
      apply({ t: "error", message: e instanceof Error ? e.message : "Network error" });
    } finally {
      setBusy(false);
    }
  }, [busy]);

  const clear = useCallback(() => setMessages([]), []);

  return { messages, busy, send, clear };
}
