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

import { useCallback, useEffect, useRef, useState } from "react";
import { Pencil, Eye } from "lucide-react";
import type { ParsedTodo } from "@/lib/assistant/tools/todos";
import { fetchTodos, setTodoChecked, todoCheckRef, fetchDailyNote, putDailyNote } from "./apiClient";
import { Deadline } from "./deadlineTypes";
import { hhmm } from "./deadlineFormat";
import NotesEditor from "./NotesEditor";
import NotesPreview from "./NotesPreview";

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
  onOpenDeadline: (d: Deadline) => void; // click a deadline row → jump to it + open the drawer
  noteEdit: { date: string; line: number } | null; // request to open the NOTE tab at a line (daily-note todo click)
  onNoteEditConsumed: () => void;
}

type DashTab = "todo" | "note";

// A stable key for one todo's soft-link anchor (used to track in-flight completion animations).
function todoKey(t: ParsedTodo): string {
  return `${t.source}|${t.eventId}|${t.dailyDate ?? ""}|${t.occurrenceKey ?? ""}|${t.line}`;
}

// Completion timing — the ~420ms left-to-right strike sweep lives in CSS (@keyframes cc-dtodo-strike);
// after the total hold below the item moves to "Recently Completed".
const COMPLETE_HOLD_MS = 1000;

// ── TODO index hook: load once on mount, refresh on calendar changes ───────────────────────────
function useTodoIndex() {
  const [todos, setTodos] = useState<ParsedTodo[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [completing, setCompleting] = useState<Set<string>>(new Set()); // keys mid strike-through animation
  const timers = useRef<Map<string, ReturnType<typeof setTimeout>>>(new Map());

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
  useEffect(() => () => { for (const id of timers.current.values()) clearTimeout(id); }, []); // cancel on unmount

  // Optimistic flip (+ local finish-stamp) → soft-link PATCH (server re-stamps in main tz) → broadcast.
  const persist = useCallback(async (t: ParsedTodo, next: boolean) => {
    setTodos((prev) => prev.map((x) => (x === t ? { ...x, done: next, doneDate: next ? nowLocalMinute() : undefined } : x)));
    try {
      await setTodoChecked(todoCheckRef(t), next);
      window.dispatchEvent(new Event("calendar:changed")); // notes changed → other layers refetch (also reloads us)
    } catch {
      void reload();
    }
  }, [reload]);

  const toggle = useCallback((t: ParsedTodo) => {
    const key = todoKey(t);
    // Clicking again mid-animation cancels the completion (un-checks).
    if (timers.current.has(key)) {
      clearTimeout(timers.current.get(key)!);
      timers.current.delete(key);
      setCompleting((s) => { const n = new Set(s); n.delete(key); return n; });
      return;
    }
    if (t.done) { void persist(t, false); return; } // un-check is immediate (back to active)
    // Check → strike through in place, hold, THEN move to Recently Completed.
    setCompleting((s) => { const n = new Set(s); n.add(key); return n; });
    const id = setTimeout(() => {
      timers.current.delete(key);
      setCompleting((s) => { const n = new Set(s); n.delete(key); return n; });
      void persist(t, true);
    }, COMPLETE_HOLD_MS);
    timers.current.set(key, id);
  }, [persist]);

  return { todos, loaded, toggle, completing };
}

// ── Per-day note hook: load on date change, debounce-save, broadcast so the index repopulates ──
function useDailyNote(date: string) {
  const [notes, setNotesState] = useState("");
  const [loaded, setLoaded] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const pending = useRef<string | null>(null); // latest value not yet persisted

  const save = useCallback((v: string) => {
    pending.current = null;
    putDailyNote(date, v)
      .then(() => window.dispatchEvent(new Event("calendar:changed"))) // checkboxes here feed the index
      .catch(() => {});
  }, [date]);
  const flush = useCallback(() => {
    if (timer.current) { clearTimeout(timer.current); timer.current = null; }
    if (pending.current != null) save(pending.current);
  }, [save]);

  useEffect(() => {
    let alive = true;
    setLoaded(false);
    fetchDailyNote(date)
      .then((n) => { if (alive) { setNotesState(n); setLoaded(true); } })
      .catch(() => { if (alive) setLoaded(true); });
    return () => { alive = false; flush(); }; // persist any pending edit when the date changes / unmounts
  }, [date, flush]);

  const setNotes = useCallback((v: string) => {
    setNotesState(v);
    pending.current = v;
    if (timer.current) clearTimeout(timer.current);
    timer.current = setTimeout(() => { timer.current = null; save(v); }, 500);
  }, [save]);

  return { notes, setNotes, loaded };
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
function TodoRow({ t, viewIso, onToggle, onOpen, completing }: { t: ParsedTodo; viewIso: string; onToggle: (t: ParsedTodo) => void; onOpen: (t: ParsedTodo) => void; completing?: boolean }) {
  const date = opDate(t);
  const overdue = date < viewIso;
  return (
    <li className={`cc-dtodo${t.done ? " cc-dtodo-is-done" : ""}${completing ? " cc-dtodo-completing" : ""}`}>
      <input type="checkbox" className="cc-dtodo-check" checked={t.done || !!completing} onChange={() => onToggle(t)} />
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
          {/* a daily-note todo on its OWN day needs no "Daily note · date" prefix — the day is implied */}
          {t.eventTitle && !(t.source === "daily" && t.dailyDate === viewIso) && <span className="cc-dtodo-event">{t.eventTitle} · </span>}
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

function DayBody({ todos, loaded, viewIso, isToday, onToggle, onOpen, completing }: {
  todos: ParsedTodo[]; loaded: boolean; viewIso: string; isToday: boolean; onToggle: (t: ParsedTodo) => void; onOpen: (t: ParsedTodo) => void; completing: Set<string>;
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
              <TodoRow key={todoKey(t)} t={t} viewIso={viewIso} onToggle={onToggle} onOpen={onOpen} completing={completing.has(todoKey(t))} />
            ))}
          </ul>
        </section>
      ))}
    </>
  );
}

// Upcoming deadlines as of the viewed day — calendar deadline events due on/after it, soonest first.
function DeadlineSection({ deadlines, viewIso, onOpen }: { deadlines: Deadline[]; viewIso: string; onOpen: (d: Deadline) => void }) {
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
            <li
              key={d.id}
              className={`cc-dd-ddl cc-ev-${d.color}`}
              role="button"
              tabIndex={0}
              title="Go to deadline"
              onClick={() => onOpen(d)}
              onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); onOpen(d); } }}
            >
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

// The NOTE tab: a per-day markdown note, reusing the drawer's editor/preview + edit/preview toggle.
// `view` is shared across the carousel (dashboard-wide), the note content is per-day.
function DailyNotePanel({ date, view, setView, cursorLine }: { date: string; view: "edit" | "preview"; setView: (v: "edit" | "preview") => void; cursorLine?: number | null }) {
  const { notes, setNotes } = useDailyNote(date);
  return (
    <div className="cc-dd-note">
      <div className="cc-dd-note-body">
        {view === "edit"
          ? <NotesEditor value={notes} onChange={setNotes} cursorLine={cursorLine} onPreview={() => setView("preview")} placeholder="Daily Note" />
          : <NotesPreview value={notes} onChange={setNotes} onEditAt={() => setView("edit")} />}
      </div>
      <div className="cc-dd-note-foot">
        <div className="cc-seg cc-dw-view" role="group" aria-label="Note view">
          <button type="button" className={`cc-seg-btn${view === "edit" ? " sel" : ""}`} title="Edit (⌘⇧V to toggle)" aria-label="Edit note" onClick={() => setView("edit")}><Pencil size={13} /></button>
          <button type="button" className={`cc-seg-btn${view === "preview" ? " sel" : ""}`} title="Preview (⌘⇧V)" aria-label="Preview note" onClick={() => setView("preview")}><Eye size={13} /></button>
        </div>
      </div>
    </div>
  );
}

export default function DailyDashboard({ left, top, bandH, bottom, right, opacity, dir, p, days, today, deadlines, onOpenTodo, onOpenDeadline, noteEdit, onNoteEditConsumed }: Props) {
  const width = Math.max(1, right - left);
  const { todos, loaded, toggle, completing } = useTodoIndex();
  const [tab, setTab] = useState<DashTab>("todo");
  const [noteView, setNoteView] = useState<"edit" | "preview">("edit"); // the daily note is mostly for writing

  // A daily-note todo was clicked → open the NOTE tab in edit mode (the matching day-panel receives
  // `cursorLine` below and its editor places the caret on mount). Cleared once consumed.
  useEffect(() => {
    if (!noteEdit) return;
    setTab("note");
    setNoteView("edit");
    const t = setTimeout(onNoteEditConsumed, 800); // give the panel time to mount + place the caret
    return () => clearTimeout(t);
  }, [noteEdit, onNoteEditConsumed]);

  // ⌘⇧V toggles the note's edit/preview while the NOTE tab is open (the in-editor direction is
  // handled inside CodeMirror; this covers preview→edit from outside an editable field).
  useEffect(() => {
    if (tab !== "note") return;
    const onKey = (e: KeyboardEvent) => {
      const el = e.target as HTMLElement | null;
      if ((e.metaKey || e.ctrlKey) && e.shiftKey && (e.key === "v" || e.key === "V") &&
          !el?.closest(".cm-editor, input, textarea, [contenteditable='true']")) {
        e.preventDefault();
        setNoteView((v) => (v === "edit" ? "preview" : "edit"));
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [tab]);

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
            {/* title zone — title bottom-left, the TODO/NOTE tabs bottom-right. */}
            <div className="cc-dd-titlezone" style={{ height: Math.max(0, bandH - 1) }}>
              <div className="cc-dd-titlemain">
                <div className="cc-dd-name">DAILY DASHBOARD</div>
                <div className="cc-dd-date">{d.label}{special && <span className="cc-dd-special"> ({special})</span>}</div>
              </div>
              <div className="cc-seg cc-dd-tabs" role="group" aria-label="Dashboard section">
                <button type="button" className={`cc-seg-btn${tab === "todo" ? " sel" : ""}`} onClick={() => setTab("todo")}>TODO</button>
                <button type="button" className={`cc-seg-btn${tab === "note" ? " sel" : ""}`} onClick={() => setTab("note")}>NOTE</button>
              </div>
            </div>
            {/* bottom bar — matches the track band's bottom divider */}
            <div className="cc-dd-bar" />
            <div className={`cc-dd-content${tab === "note" ? " cc-dd-content-note" : ""}`}>
              {tab === "todo" ? (
                <>
                  <DeadlineSection deadlines={deadlines} viewIso={d.iso} onOpen={onOpenDeadline} />
                  <DayBody todos={todos} loaded={loaded} viewIso={d.iso} isToday={d.iso === today} onToggle={toggle} onOpen={onOpenTodo} completing={completing} />
                </>
              ) : (
                <DailyNotePanel date={d.iso} view={noteView} setView={setNoteView} cursorLine={noteEdit && noteEdit.date === d.iso ? noteEdit.line : null} />
              )}
            </div>
          </div>
        );
      })}
    </div>
  );
}
