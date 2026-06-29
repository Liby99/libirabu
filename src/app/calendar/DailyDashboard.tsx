"use client";

// The right-hand panel of the daily view (z=3). Two layers:
//  • cc-daily-dash — a FIXED clipping mask (opaque bg occludes the timeline sliding under it). It
//    never moves or fades during day paging; it only fades in/out with the zoom (`opacity`).
//  • cc-daily-inner-dash — the moving panels, one per day (prev / current / next). They slide and
//    cross-fade like a carousel as you page days; on commit the set re-indexes (the old "next"
//    becomes "current", a fresh "next" appears) — keyed by date so React reuses them seamlessly.
//
// The body shows a dynamic daily TODO list: the cross-event TODO index (GET /api/calendar/todos,
// design §17.2) grouped into a few day-relative topics (due-this-day / overdue / high-priority due
// soon). Checkboxes write back through the soft-link PATCH.

import { useCallback, useEffect, useState } from "react";
import type { ParsedTodo } from "@/lib/assistant/tools/todos";
import { fetchTodos, setTodoChecked } from "./apiClient";
import { Deadline } from "./deadlineTypes";
import { hhmm } from "./deadlineFormat";

interface Day { offset: number; key: string; iso: string; label: string } // offset: −1 prev, 0 current, +1 next

interface Props {
  left: number;       // mask left = the day column's resting right edge (fixed)
  top: number;        // mask top (aligned with the track band's top border)
  bandH: number;      // height of the 4-track band region (the title zone sits in it, between the bars)
  bottom: number;     // mask bottom
  right: number;      // viewport right edge
  opacity: number;    // mask opacity: 0→1 over z 2→3 (zoom only — constant during paging)
  dir: 1 | -1;        // paging direction
  p: number;          // paging progress 0→1 (0 when not paging)
  days: Day[];
  today: string;      // real today (YYYY-MM-DD, main tz) — for the (Today/Yesterday/Tomorrow) suffix
  deadlines: Deadline[];
  onOpenTodo: (t: ParsedTodo) => void; // click a row → jump the calendar to its event + open the drawer
}

// ── TODO index hook: load once on mount, refresh on calendar changes ───────────────────────────
function useTodoIndex() {
  const [todos, setTodos] = useState<ParsedTodo[]>([]);
  const [loaded, setLoaded] = useState(false);

  const reload = useCallback(async () => {
    try {
      const res = await fetchTodos();
      setTodos(res.todos);
    } catch {
      /* leave the last good list in place */
    } finally {
      setLoaded(true);
    }
  }, []);

  useEffect(() => {
    void reload();
    const onChanged = () => void reload();
    window.addEventListener("calendar:changed", onChanged);
    return () => window.removeEventListener("calendar:changed", onChanged);
  }, [reload]);

  // Optimistic check/uncheck (with a local finish-stamp so it strikes through immediately) → persist
  // via the soft-link PATCH (the server re-stamps in the main tz) → tell the rest of the app to refresh.
  const toggle = useCallback(async (t: ParsedTodo) => {
    const next = !t.done;
    setTodos((prev) => prev.map((x) => (x === t ? { ...x, done: next, doneDate: next ? nowLocalMinute() : undefined } : x)));
    try {
      await setTodoChecked({ eventId: t.eventId, occurrenceKey: t.occurrenceKey, line: t.line }, next);
      window.dispatchEvent(new Event("calendar:changed")); // notes changed → other layers refetch (also reloads us)
    } catch {
      void reload();
    }
  }, [reload]);

  return { todos, loaded, toggle };
}

// ── Day-relative grouping ──────────────────────────────────────────────────────────────────────
const HIGH_PRIORITY = 3;     // p:!!! and up
const SOON_DAYS = 7;         // "due soon" window
const FOLLOWUP_WINDOW = 7;   // how soon a followup must be to surface in "Remember to Followup"
const RECENT_DONE_DAYS = 7;  // how far back "Recently Completed" looks (relative to the viewed day)

const dueDate = (t: ParsedTodo) => (t.due ?? "").slice(0, 10); // strip any time part
const pad = (n: number) => String(n).padStart(2, "0");
// Local wall-clock to the minute, for the optimistic finish-stamp (the server re-stamps in main tz).
function nowLocalMinute(): string {
  const n = new Date();
  return `${n.getFullYear()}-${pad(n.getMonth() + 1)}-${pad(n.getDate())}T${pad(n.getHours())}:${pad(n.getMinutes())}`;
}
function addDays(iso: string, n: number): string {
  const [y, m, d] = iso.split("-").map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d + n));
  return `${dt.getUTCFullYear()}-${pad(dt.getUTCMonth() + 1)}-${pad(dt.getUTCDate())}`;
}
function daysBetween(fromIso: string, toIso: string): number {
  const [ay, am, ad] = fromIso.split("-").map(Number);
  const [by, bm, bd] = toIso.split("-").map(Number);
  return Math.round((Date.UTC(by, bm - 1, bd) - Date.UTC(ay, am - 1, ad)) / 86_400_000);
}
// Human relative-day label from the panel's day to the item's due date.
function relDue(viewIso: string, due: string): string {
  const n = daysBetween(viewIso, due);
  if (n === 0) return "today";
  if (n === -1) return "yesterday";
  if (n === 1) return "tomorrow";
  return n < 0 ? `${-n}d ago` : `in ${n}d`;
}
// "✓ finished {relative day} · {time}" from a done:YYYY-MM-DD[THH:MM] stamp.
function finishedLabel(viewIso: string, doneStamp: string): string {
  const day = doneStamp.slice(0, 10);
  const rel = relDue(viewIso, day);
  const time = doneStamp.length > 10 ? ` · ${hhmm(Number(doneStamp.slice(11, 13)) + Number(doneStamp.slice(14, 16)) / 60)}` : "";
  return `${rel}${time}`;
}

interface Section { title: string; items: ParsedTodo[]; done?: boolean }

// Operative date: a follow-up date supersedes the plain due date (it's "still a due date, presented
// the other way around"), so it drives overdue and the followup reminder.
const opDate = (t: ParsedTodo) => t.followup ?? dueDate(t);

function sectionsForDay(todos: ParsedTodo[], viewIso: string, isToday: boolean): Section[] {
  // Visible as of the viewed day: open, and not deferred past it (start: in the future).
  const shown = todos.filter((t) => !t.done && (!t.start || t.start <= viewIso));
  const soonEnd = addDays(viewIso, SOON_DAYS);
  const followEnd = addDays(viewIso, FOLLOWUP_WINDOW);
  const byOp = (a: ParsedTodo, b: ParsedTodo) =>
    opDate(a) < opDate(b) ? -1 : opDate(a) > opDate(b) ? 1 : (b.priority ?? 0) - (a.priority ?? 0);

  // Overdue: the operative date has passed — covers both plain due dates and followups.
  const overdue = shown.filter((t) => opDate(t) < viewIso).sort(byOp);
  // Remember to Followup: a followup whose date is upcoming and within the reminder window.
  const followups = shown.filter((t) => t.followup && t.followup >= viewIso && t.followup <= followEnd).sort(byOp);
  // The plain due-date buckets only consider NON-followup items (followups are handled above).
  const plain = shown.filter((t) => !t.followup);
  const dueThisDay = plain.filter((t) => dueDate(t) === viewIso).sort(byOp);
  const highSoon = plain
    .filter((t) => (t.priority ?? 0) >= HIGH_PRIORITY && dueDate(t) > viewIso && dueDate(t) <= soonEnd)
    .sort(byOp);

  // Recently completed: done items whose finish date falls in [viewIso − RECENT_DONE_DAYS, viewIso].
  // Most-recent first; only those carrying a done: stamp (so we know when).
  const recentStart = addDays(viewIso, -RECENT_DONE_DAYS);
  const completed = todos
    .filter((t) => t.done && t.doneDate && t.doneDate.slice(0, 10) >= recentStart && t.doneDate.slice(0, 10) <= viewIso)
    .sort((a, b) => (a.doneDate! < b.doneDate! ? 1 : a.doneDate! > b.doneDate! ? -1 : 0))
    .slice(0, 12);

  return [
    { title: isToday ? "Today’s Items" : "Due This Day", items: dueThisDay },
    { title: "Overdue", items: overdue },
    { title: "Remember to Followup", items: followups },
    { title: "High Priority · Due Soon", items: highSoon },
    { title: "Recently Completed", items: completed, done: true },
  ];
}

// ── Rendering ──────────────────────────────────────────────────────────────────────────────────
function TodoRow({ t, viewIso, onToggle, onOpen }: { t: ParsedTodo; viewIso: string; onToggle: (t: ParsedTodo) => void; onOpen: (t: ParsedTodo) => void }) {
  const date = opDate(t);
  const overdue = date < viewIso;
  return (
    <li className={`cc-dtodo${t.done ? " cc-dtodo-is-done" : ""}`}>
      <input type="checkbox" className="cc-dtodo-check" checked={t.done} onChange={() => onToggle(t)} />
      {/* clicking the text (not the checkbox) jumps the calendar to the source event + opens its drawer */}
      <span
        className="cc-dtodo-main"
        role="button"
        tabIndex={0}
        title="Go to event"
        onClick={() => onOpen(t)}
        onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); onOpen(t); } }}
      >
        <span className="cc-dtodo-text">
          {t.eventTitle && <span className="cc-dtodo-event">{t.eventTitle} · </span>}
          {t.text || <em>(untitled)</em>}
        </span>
        <span className="cc-dtodo-meta">
          {t.done ? (
            <span className="cc-dtodo-fin">✓ {t.doneDate ? finishedLabel(viewIso, t.doneDate) : "done"}</span>
          ) : (
            <>
              {t.priority ? <span className="cc-dtodo-prio" data-level={t.priority}>{"!".repeat(t.priority)}</span> : null}
              {t.followup ? (
                <span className={`cc-dtodo-followup${overdue ? " cc-dtodo-due-over" : ""}`}>↪ follow up {relDue(viewIso, t.followup)}</span>
              ) : (
                <span className={`cc-dtodo-due${overdue ? " cc-dtodo-due-over" : ""}`}>{relDue(viewIso, date)}</span>
              )}
              {t.tags.slice(0, 3).map((tag) => <span key={tag} className="cc-dtodo-tag">#{tag}</span>)}
            </>
          )}
        </span>
      </span>
    </li>
  );
}

function DayBody({ todos, loaded, viewIso, isToday, onToggle, onOpen }: {
  todos: ParsedTodo[]; loaded: boolean; viewIso: string; isToday: boolean; onToggle: (t: ParsedTodo) => void; onOpen: (t: ParsedTodo) => void;
}) {
  if (!loaded && todos.length === 0) return <div className="cc-dtodo-empty">Loading…</div>;
  const sections = sectionsForDay(todos, viewIso, isToday).filter((s) => s.items.length > 0);
  if (sections.length === 0) return <div className="cc-dtodo-empty">Nothing on the list — you’re clear.</div>;
  return (
    <>
      {sections.map((s) => (
        <section key={s.title} className="cc-dtodo-sec">
          <div className="cc-dtodo-sec-head">
            <span className="cc-dtodo-sec-title">{s.title}</span>
            <span className="cc-dtodo-sec-count">{s.items.length}</span>
          </div>
          <ul className="cc-dtodo-list">
            {s.items.map((t) => (
              <TodoRow key={`${t.eventId}:${t.occurrenceKey}:${t.line}`} t={t} viewIso={viewIso} onToggle={onToggle} onOpen={onOpen} />
            ))}
          </ul>
        </section>
      ))}
    </>
  );
}

// Upcoming deadlines as of the viewed day — calendar deadline events due on/after it, soonest first.
function DeadlineSection({ deadlines, viewIso }: { deadlines: Deadline[]; viewIso: string }) {
  const upcoming = deadlines
    .map((d) => ({ d, iso: `${d.year}-${pad(d.month + 1)}-${pad(d.day)}` }))
    .filter((x) => x.iso >= viewIso)
    .sort((a, b) => (a.iso < b.iso ? -1 : a.iso > b.iso ? 1 : a.d.hour - b.d.hour))
    .slice(0, 10);
  return (
    <section className="cc-dd-sec">
      <div className="cc-dd-sec-head">
        <span className="cc-dd-sec-title">Upcoming Deadlines</span>
        {upcoming.length > 0 && <span className="cc-dd-sec-count">{upcoming.length}</span>}
      </div>
      {upcoming.length === 0 ? (
        <div className="cc-dd-free">No immediate deadline! You are free!</div>
      ) : (
        <ul className="cc-dd-ddl-list">
          {upcoming.map(({ d, iso }) => (
            <li key={d.id} className={`cc-dd-ddl cc-ev-${d.color}`}>
              <span className="cc-dd-ddl-dot" />
              <span className="cc-dd-ddl-title">{d.title || <em>(untitled)</em>}</span>
              <span className="cc-dd-ddl-when">{relDue(viewIso, iso)} · {hhmm(d.hour)}</span>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

export default function DailyDashboard({ left, top, bandH, bottom, right, opacity, dir, p, days, today, deadlines, onOpenTodo }: Props) {
  const width = Math.max(1, right - left);
  const { todos, loaded, toggle } = useTodoIndex();
  return (
    <div
      className="cc-daily-dash"
      style={{ left, top, width, height: Math.max(0, bottom - top), opacity, pointerEvents: opacity > 0.9 ? "auto" : "none" }}
      onMouseDown={(e) => e.stopPropagation()}
      onClick={(e) => e.stopPropagation()}
    >
      {days.map((d) => {
        const x = d.offset * width - dir * p * width;      // carousel offset (current at 0 when idle)
        const op = Math.max(0, 1 - Math.abs(x) / width);   // fade by distance from center
        const rel = daysBetween(today, d.iso);
        const special = rel === 0 ? "Today" : rel === -1 ? "Yesterday" : rel === 1 ? "Tomorrow" : null;
        return (
          <div key={d.key} className="cc-daily-inner-dash" style={{ transform: `translateX(${x}px)`, opacity: op }}>
            {/* top bar — matches the track band's top border */}
            <div className="cc-dd-bar" />
            {/* title zone — fills the band region, title bottom-aligned toward the next bar. Height is
                bandH − 1 so the bottom bar sits 1px higher (level with the track band's bottom divider). */}
            <div className="cc-dd-titlezone" style={{ height: Math.max(0, bandH - 1) }}>
              <div className="cc-dd-name">DAILY DASHBOARD</div>
              <div className="cc-dd-date">{d.label}{special && <span className="cc-dd-special"> ({special})</span>}</div>
            </div>
            {/* bottom bar — matches the track band's bottom divider */}
            <div className="cc-dd-bar" />
            <div className="cc-dd-content">
              <DeadlineSection deadlines={deadlines} viewIso={d.iso} />
              <DayBody todos={todos} loaded={loaded} viewIso={d.iso} isToday={d.iso === today} onToggle={toggle} onOpen={onOpenTodo} />
            </div>
          </div>
        );
      })}
    </div>
  );
}
