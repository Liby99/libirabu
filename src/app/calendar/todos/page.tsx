"use client";

// Debug view for the TODO soft-link index (design §17.2). Not the real panel — a flat dump of
// everything `GET /api/calendar/todos` returns, so we can eyeball the parser/inheritance/anchors
// against real notes, and exercise the write-back (`PATCH`) by toggling a checkbox.

import { useCallback, useEffect, useState } from "react";
import type { ParsedTodo } from "@/lib/assistant/tools/todos";
import { fetchTodos, setTodoChecked } from "../apiClient";
import "../calendar.css"; // for the .cc-ev-<color> palette vars used in the color swatch

const stateOf = (t: ParsedTodo) => (t.done ? "done" : t.active ? "active" : "deferred");

function Chips({ items, prefix = "" }: { items: string[]; prefix?: string }) {
  if (!items.length) return <span className="text-neutral-400">—</span>;
  return (
    <span className="flex flex-wrap gap-1">
      {items.map((s, i) => (
        <span key={i} className="rounded bg-neutral-100 px-1.5 py-0.5 font-mono text-[11px] text-neutral-700">
          {prefix}{s}
        </span>
      ))}
    </span>
  );
}

export default function TodoDebugPage() {
  const [todos, setTodos] = useState<ParsedTodo[]>([]);
  const [today, setToday] = useState<string>("");
  const [status, setStatus] = useState<"loading" | "ready" | "error">("loading");
  const [error, setError] = useState<string>("");
  const [showJson, setShowJson] = useState(false);

  const load = useCallback(async () => {
    setStatus("loading");
    try {
      const { todos, today } = await fetchTodos();
      setTodos(todos);
      setToday(today);
      setStatus("ready");
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setStatus("error");
    }
  }, []);

  useEffect(() => { void load(); }, [load]);

  const toggle = async (t: ParsedTodo) => {
    // optimistic flip, then persist + reload from source of truth
    setTodos((prev) => prev.map((x) => (x === t ? { ...x, done: !x.done } : x)));
    try {
      await setTodoChecked({ eventId: t.eventId, occurrenceKey: t.occurrenceKey, line: t.line }, !t.done);
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      void load();
    }
  };

  const refs = (t: ParsedTodo) =>
    Object.entries(t.entities).flatMap(([type, slugs]) =>
      slugs.map((s) => (type === "person" ? `@${s}` : `@${type}:${s}`)),
    );

  return (
    <main className="mx-auto max-w-[1400px] p-6 text-[13px] text-neutral-800">
      <div className="mb-4 flex items-baseline gap-4">
        <h1 className="text-lg font-bold">TODO index — debug</h1>
        <span className="text-neutral-500">
          {status === "ready" ? `${todos.length} item${todos.length === 1 ? "" : "s"}` : status}
          {today && ` · today ${today}`}
        </span>
        <button onClick={() => void load()} className="rounded border px-2 py-0.5 text-xs hover:bg-neutral-50">
          Refresh
        </button>
        <button onClick={() => setShowJson((v) => !v)} className="rounded border px-2 py-0.5 text-xs hover:bg-neutral-50">
          {showJson ? "Hide" : "Show"} raw JSON
        </button>
      </div>

      {status === "error" && (
        <pre className="mb-4 whitespace-pre-wrap rounded bg-red-50 p-3 font-mono text-xs text-red-700">{error}</pre>
      )}

      {status === "ready" && todos.length === 0 && (
        <p className="text-neutral-500">
          No checkboxes found in any event notes. Add a line like{" "}
          <code className="rounded bg-neutral-100 px-1 font-mono">- [ ] submit abstract due:2026-07-01 p:!!</code> to an
          event&apos;s notes.
        </p>
      )}

      {todos.length > 0 && (
        <div className="overflow-x-auto">
          <table className="w-full border-collapse text-left align-top">
            <thead>
              <tr className="border-b text-[11px] uppercase tracking-wide text-neutral-500">
                {["", "state", "event · text", "due", "prio", "tags", "refs", "links", "color", "anchor", "raw"].map((h) => (
                  <th key={h} className="px-2 py-1.5 font-semibold">{h}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {todos.map((t, i) => (
                <tr key={`${t.eventId}:${t.occurrenceKey}:${t.line}`} className={`border-b ${i % 2 ? "bg-neutral-50/50" : ""}`}>
                  <td className="px-2 py-1.5">
                    <input type="checkbox" checked={t.done} onChange={() => void toggle(t)} />
                  </td>
                  <td className="px-2 py-1.5">
                    <span className={
                      stateOf(t) === "active" ? "text-green-700"
                      : stateOf(t) === "done" ? "text-neutral-400"
                      : "text-amber-700"
                    }>{stateOf(t)}</span>
                  </td>
                  <td className="px-2 py-1.5">
                    <span className="text-neutral-500">{t.eventTitle}</span>
                    <span className="text-neutral-400"> · </span>
                    <span className={t.done ? "text-neutral-400 line-through" : ""}>{t.text || <em className="text-neutral-400">(empty)</em>}</span>
                  </td>
                  <td className="whitespace-nowrap px-2 py-1.5 font-mono text-xs">
                    {t.due ?? "—"}
                    {t.dueTz ? <span className="text-neutral-400"> {t.dueTz}</span> : null}
                    <div className="text-[10px] text-neutral-400">{t.dueSource}{t.start ? ` · from ${t.start}` : ""}</div>
                  </td>
                  <td className="px-2 py-1.5">{t.priority ? <span className="font-mono text-red-600">{"!".repeat(t.priority)}</span> : "—"}</td>
                  <td className="px-2 py-1.5"><Chips items={t.tags} prefix="#" /></td>
                  <td className="px-2 py-1.5"><Chips items={refs(t)} /></td>
                  <td className="px-2 py-1.5">
                    {t.links.length
                      ? t.links.map((l, j) => (
                          <a key={j} href={l.url} target="_blank" rel="noreferrer" className="block max-w-[160px] truncate text-blue-600 underline">
                            {l.label ?? l.url}
                          </a>
                        ))
                      : <span className="text-neutral-400">—</span>}
                  </td>
                  <td className="px-2 py-1.5">
                    <span className="inline-flex items-center gap-1.5">
                      <span className={`cc-ev-${t.color} inline-block h-3 w-3 rounded-full border border-black/20`} style={{ background: "var(--ev-color, #ccc)" }} />
                      <span className="text-xs">{t.color}</span>
                      <span className="text-[10px] text-neutral-400">{t.colorSource}</span>
                    </span>
                  </td>
                  <td className="whitespace-nowrap px-2 py-1.5 font-mono text-[10px] text-neutral-500">
                    {t.eventId.slice(0, 6)}…{t.occurrenceKey ? ` · ${t.occurrenceKey}` : ""} · L{t.line}
                  </td>
                  <td className="px-2 py-1.5"><code className="font-mono text-[11px] text-neutral-600">{t.raw.trim()}</code></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {showJson && (
        <pre className="mt-6 max-h-[600px] overflow-auto rounded bg-neutral-900 p-4 font-mono text-[11px] text-neutral-100">
          {JSON.stringify(todos, null, 2)}
        </pre>
      )}
    </main>
  );
}
