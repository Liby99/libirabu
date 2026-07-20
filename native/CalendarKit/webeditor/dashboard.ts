// Daily dashboard for the native day-view, in a transparent WKWebView. Reuses the web's TODO index
// (`todos.ts` tokenizer — single source of truth) and mirrors DailyDashboard.tsx's day-relative
// sectioning + row rendering, without React. Swift pushes the data; toggles/opens post back.
//
// CAROUSEL: the day pager (finger-following) drives a continuous animation. Swift ticks us every
// frame with {fromIso, toIso, dir, p}; we render two panels and slide + cross-fade them exactly like
// the Canvas title bars (SceneRenderer.drawPanel): the current day slides out by -dir·p and fades to
// 1−p, the incoming day slides in from dir·(1−p) and fades to p. At rest (no toIso) a single panel is
// centered and interactive. Since sectionsForDay only needs a viewIso + the day-independent event
// list, any day renders from the same data.
//
// Bridge: Swift → CK.setData(json) / CK.tick(from,to,dir,p) / CK.setTheme(vars); JS → messageHandlers.ck.

import { indexTodos, parseDailyNoteTodos, toggleTodoLine, type ParsedTodo, type TodoEventContext } from "../../../src/lib/assistant/tools/todos";
import { createNoteEditor, renderMarkdown } from "./noteEditor";

interface DL { id: string; year: number; month: number; day: number; hour: number; title: string; color: string; }

let events: TodoEventContext[] = [];
let deadlines: DL[] = [];
let today = "";
// The aggregated TODO index — soft-linked pointers into event notes AND daily notes (matching the
// web's GET /api/calendar/todos). Rebuilt in-memory when the data map changes (setData), NOT scanned
// per render. Everything's already in memory here, so this is a cheap flatMap over a few hundred notes.
let allTodos: ParsedTodo[] = [];
let todosDirty = true;                     // set on any note/event change; rebuilt lazily when shown
function ensureTodos() {
  if (!todosDirty) return;
  allTodos = [
    ...indexTodos(events, today),
    ...Object.entries(notes).flatMap(([date, text]) => parseDailyNoteTodos(date, text, today)),
  ];
  todosDirty = false;
}
// The last tick, re-applied after a data change so the visible panels refresh in place.
// `reveal` (0 week → 1 day) drives the fade; `slide` (0 open → 1 fully-off-right, a fraction of the
// panel width) drives the horizontal position. Both come from Swift so the panel's left edge tracks
// the Canvas `dashboardLeftAnimated` EXACTLY (which also depends on the growing day-column width, not
// reveal alone). `reveal` starts at 0 (hidden) so a freshly-mounted web view stays invisible until
// the first real tick — else setData would paint it fully opaque for a frame at week level (a flash).
// One tick = one object merged over these defaults — a missing/new field can never arrive as
// undefined (the positional-arity version once blanked the whole webview that way).
const TICK_DEFAULTS = { from: "", to: "", dir: 0, p: 0, reveal: 0, slide: 1,
                        scopeA: "day", scopeB: "day", scopeT: 1,
                        dy: 0, mFrom: "", mTo: "", mDy0: 0, mDy1: 0, mP: 0,
                        wFrom: "", wTo: "", wP: 0,
                        // Per-panel scope geometry from Swift's dashScopePanels (frame-local px):
                        // the mask (clip) region + each panel's own left/width/opacity.
                        maskX: 0, maskW: 0,
                        aName: "", aX: 0, aW: 0, aOp: 0,
                        bName: "", bX: 0, bW: 0, bOp: 0 };
let last = { ...TICK_DEFAULTS };

const root = document.getElementById("dash")!;                 // reveal wrapper (zoom slide + fade)
const panelsEl = document.getElementById("panels")!;           // carousel content (todo OR note preview)
const noteLive = document.getElementById("note-live")!;        // live editor overlay (rest + note only)

// ── Zoom-scope layers (weekly / monthly) ────────────────────────────────────────────────────────
// PHASE-1 PLACEHOLDERS: unmistakably labeled content per scope, so the month↔week↔day zoom
// carousel (Swift ticks scopeA/scopeB/scopeT) can be tuned visually before the real weekly/monthly
// dashboards land. The DAY layer is the existing #panels (+ note editor); these two are siblings
// that slide/fade with the same math.
function makeScopeLayer(id: string, title: string, items: string[]): HTMLElement {
  const el = document.createElement("div");
  el.className = "cc-dd-panel";
  el.id = id;
  const scroll = document.createElement("div");
  scroll.className = "cc-dd-scroll";
  scroll.innerHTML =
    `<div style="opacity:.55;font-size:11px;letter-spacing:1.5px;margin:4px 0 10px">${title} · PLACEHOLDER</div>` +
    items.map((t, i) =>
      `<div style="display:flex;gap:8px;align-items:center;padding:7px 4px;border-bottom:1px solid rgba(128,128,128,.18)">
         <span style="width:14px;height:14px;border:1.5px solid rgba(128,128,128,.55);border-radius:4px;flex:none"></span>
         <span>${t} ${i + 1}</span>
       </div>`).join("") +
    `<div style="margin-top:14px;opacity:.5;font-size:12px">${title.toLowerCase()} note — placeholder text.
      Lorem calendar sit amet, styling and animation tuning only.</div>`;
  el.appendChild(scroll);
  root.appendChild(el);
  return el;
}
// The WEEK layer holds TWO side-by-side sub-panels that carousel HORIZONTALLY during a
// week-to-week turn (Swift ticks wFrom/wTo/wP from the continuous week scroll) — labeled by
// date range so the motion is unmistakable while tuning.
const weekLayer = document.createElement("div");
weekLayer.className = "cc-dd-panel"; weekLayer.id = "scope-week";
root.appendChild(weekLayer);
function weekPH(): HTMLElement {
  const el = document.createElement("div");
  el.className = "cc-dd-panel";           // absolute-fill inside the week layer
  weekLayer.appendChild(el);
  return el;
}
// Identity-keyed by week label (same rule as the month panels): when the week base advances
// and from/to re-base, each panel KEEPS its week — positions stay continuous across the flip.
let wpA = weekPH(), wpB = weekPH();
const wpLabel = new Map<HTMLElement, string>();
function renderWeekPH(el: HTMLElement, label: string) {
  if (wpLabel.get(el) === label) return;
  wpLabel.set(el, label);
  el.innerHTML = `<div class="cc-dd-scroll">` +
    `<div style="opacity:.55;font-size:11px;letter-spacing:1.5px;margin:4px 0 10px">WEEKLY · ${label.toUpperCase()} · PLACEHOLDER</div>` +
    [1, 2, 3, 4].map(i =>
      `<div style="display:flex;gap:8px;align-items:center;padding:7px 4px;border-bottom:1px solid rgba(128,128,128,.18)">
         <span style="width:14px;height:14px;border:1.5px solid rgba(128,128,128,.55);border-radius:4px;flex:none"></span>
         <span>${label} item ${i}</span>
       </div>`).join("") +
    `<div style="margin-top:14px;opacity:.5;font-size:12px">${label} note — placeholder text.</div></div>`;
}
// The MONTH layer holds TWO stacked sub-panels that carousel VERTICALLY during a month page-turn
// (jan→feb), mirroring the calendar's vertical month paging — labeled by month name so the motion
// is unmistakable while tuning.
const monthLayer = document.createElement("div");
monthLayer.className = "cc-dd-panel"; monthLayer.id = "scope-month";
root.appendChild(monthLayer);
function monthPH(): HTMLElement {
  const el = document.createElement("div");
  el.className = "cc-dd-panel";           // absolute-fill inside the month layer
  monthLayer.appendChild(el);
  return el;
}
// Role panels are IDENTITY-KEYED by month label (mirroring the day panels' isoOf): when the
// pager re-bases mid-turn (focus flips, from/to swap), each panel KEEPS its month — positions
// stay continuous across the flip instead of two panels teleport-swapping contents.
let mpA = monthPH(), mpB = monthPH();
const mpLabel = new Map<HTMLElement, string>();
function renderMonthPH(el: HTMLElement, label: string) {
  if (mpLabel.get(el) === label) return;
  mpLabel.set(el, label);
  el.innerHTML = `<div class="cc-dd-scroll">` +
    `<div style="opacity:.55;font-size:11px;letter-spacing:1.5px;margin:4px 0 10px">MONTHLY · ${label.toUpperCase()} · PLACEHOLDER</div>` +
    [1, 2, 3].map(i =>
      `<div style="display:flex;gap:8px;align-items:center;padding:7px 4px;border-bottom:1px solid rgba(128,128,128,.18)">
         <span style="width:14px;height:14px;border:1.5px solid rgba(128,128,128,.55);border-radius:4px;flex:none"></span>
         <span>${label} item ${i}</span>
       </div>`).join("") +
    `<div style="margin-top:14px;opacity:.5;font-size:12px">${label} note — placeholder text.</div></div>`;
}
function post(m: any) { (window as any).webkit?.messageHandlers?.ck?.postMessage(m); }

// The WKWebView is a separate compositing layer, so the app's SwiftUI blur/scrim can't touch it and
// its CSS :hover keeps firing while the drawer is open. This in-page scrim blurs the dashboard and
// intercepts pointer events itself; a click on it closes the drawer (parity with the SwiftUI scrim).
const scrim = document.createElement("div"); scrim.id = "scrim";
document.body.appendChild(scrim);
scrim.addEventListener("click", () => post({ type: "closeDrawer" }));

// Each panel is a carousel/zoom transform layer with a PLAIN inner scroller. The scroller carries no
// transform/will-change so WebKit gives it native rubber-band overscroll (a transformed scroller is
// composited and scrolls without the elastic bounce).
function makePanel(): { panel: HTMLElement; scroll: HTMLElement } {
  const panel = document.createElement("div"); panel.className = "cc-dd-panel";
  const scroll = document.createElement("div"); scroll.className = "cc-dd-scroll";
  panel.append(scroll); return { panel, scroll };
}
const P0 = makePanel(), P1 = makePanel();
const p0 = P0.panel, p1 = P1.panel;                 // "from"/centered and "to"/incoming transform layers
const scrollOf = new WeakMap<Element, HTMLElement>([[p0, P0.scroll], [p1, P1.scroll]]);
panelsEl.append(p0, p1);
const flatOf = new WeakMap<Element, ParsedTodo[]>();   // per-panel flat todo list (matches data-idx)
const isoOf = new WeakMap<Element, string>();          // panel → currently-rendered iso (tab-qualified)

// Per-DAY scroll memory (keyed by iso, NOT by the recycled p0/p1 panels). Each day owns its scrollTop:
// a day we haven't scrolled sits at 0, and revisiting a scrolled day restores it — independent per day.
// Saved live below as the user scrolls the centered panel; cleared when we leave day view (see apply()).
let scrollByIso: Record<string, number> = {};
for (const P of [P0, P1]) {
  P.scroll.addEventListener("scroll", () => {
    const iso = isoOf.get(P.panel);
    if (iso) scrollByIso[iso] = P.scroll.scrollTop;   // remember where THIS day is scrolled to
  }, { passive: true });
}

// ── NOTE: per-day notes ──────────────────────────────────────────────────────────────────────────
// Each day owns a note. The carousel panels render a STATIC preview of the day's note (so paging
// slides the old note out + the new one in, like the TODO list). The live CodeMirror editor overlays
// the centered panel only at rest, for editing. Notes for all days come from Swift via setData.
let tab: "todo" | "note" = "todo";
let noteMode: "edit" | "preview" = "edit";
let notes: Record<string, string> = {};
let liveIso = "";                                      // the day the live editor currently holds
let liveText = "";                                     // the note value currently in the editor (detects external changes)
const noteEd = createNoteEditor({
  editorEl: document.getElementById("note-editor")!,
  previewEl: document.getElementById("note-preview")!,
  placeholder: "Daily Note",
  onChange: (value) => { notes[liveIso] = value; liveText = value; todosDirty = true; post({ type: "noteChange", date: liveIso, value }); },
  // ⌘S → preview, and (if we were keyboard-focused via Tab) hand focus back to the calendar's NOTE ring.
  onPreview: () => { noteModeUser("preview"); post({ type: "navNoteExit" }); },
  onExit: () => post({ type: "navNoteExit" }),             // Escape in the editor → back to the NOTE ring
  onOpenLink: (url) => post({ type: "openLink", url }),
  onEditAt: (line) => { noteModeUser("edit"); noteEd.setCursorLine(line); },   // ⌘-click a preview block
});

// ── Keyboard nav from the calendar (Tab into the dashboard TODO / NOTE stops) ──────────────────────
// The calendar's key system stays in control and drives these via CK.nav*; the focused row / note gets
// the SAME dashed red ring as the calendar's cursors. `navStop` is which stop is focused (null = none),
// `todoCursor` the focused TODO row, `editingNote` true once the note editor is focused (ring hidden).
let navStop: "todo" | "note" | null = null;
let todoCursor = 0;
let editingNote = false;
function todoRows(): HTMLElement[] { return Array.from(P0.scroll.querySelectorAll<HTMLElement>(".cc-dtodo")); }
function applyTodoCursor() {
  const rows = todoRows();
  rows.forEach((r) => r.classList.remove("cc-nav-cur"));
  // Empty list → there's no row to put the cursor on, so ring the whole TODO region instead (same
  // full-region dashed ring the NOTE editor uses). Otherwise the ring lives on the focused row.
  panelsEl.classList.toggle("cc-nav-on", navStop === "todo" && rows.length === 0);
  if (navStop !== "todo" || !rows.length) return;
  todoCursor = Math.max(0, Math.min(rows.length - 1, todoCursor));
  rows[todoCursor].classList.add("cc-nav-cur");
  // Smoothly glide the focused row into view (scroll-padding on .cc-dd-scroll keeps the ring off the edge).
  rows[todoCursor].scrollIntoView({ block: "nearest", behavior: "smooth" });
}
function applyNav() {
  noteLive.classList.toggle("cc-nav-on", navStop === "note" && !editingNote);
  applyTodoCursor();
}
function applyTab(t: "todo" | "note") { tab = t; isoOf.delete(p0); isoOf.delete(p1); apply(); }
// A user action IN the webview (⌘S / ⌘-click) → change mode + tell Swift so the native toggle updates.
function noteModeUser(m: "edit" | "preview") {
  if (noteMode === m) return;
  noteMode = m; liveMode = ""; post({ type: "noteMode", mode: m }); apply();
}

const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

// Horizontal scroll INSIDE an overflow-x element (a code block with a long line) must stay LOCAL — the
// PassThroughWebView otherwise forwards horizontal wheels to the calendar (day paging). We can't
// preventDefault (the native view forwards the wheel before JS ever sees it), so instead we tell Swift
// when the pointer sits over such an element; it keeps that gesture in the web view. Pointer-move driven
// (trackpad scrolls don't move the pointer, so the last known position is what matters at scroll time).
let hLocalOn = false;
function hScrollableUnder(x: number, y: number): boolean {
  let el = document.elementFromPoint(x, y) as HTMLElement | null;
  for (let depth = 0; el && el !== document.body && depth < 8; el = el.parentElement, depth++) {
    const ox = getComputedStyle(el).overflowX;
    if ((ox === "auto" || ox === "scroll") && el.scrollWidth > el.clientWidth + 1) return true;
  }
  return false;
}
document.addEventListener("pointermove", (e) => {
  const on = hScrollableUnder(e.clientX, e.clientY);
  if (on !== hLocalOn) { hLocalOn = on; post({ type: "hlocal", on }); }
}, { passive: true });

// The dashboard web view must NEVER do native Tab focus (blue rings cycling <a> links / rows). When the
// web view holds focus (after a click) but the caret isn't in the note editor, Tab belongs to the APP's
// keyboard navigation — forward it and let Swift drop the web view's focus. Inside CodeMirror, Tab stays
// local (indentation). Capture phase so we beat the browser's focus move and CodeMirror's own handler.
document.addEventListener("keydown", (e) => {
  if (e.key !== "Tab") return;
  if ((e.target as HTMLElement)?.closest?.(".cm-editor")) return;   // editing the note → Tab indents
  e.preventDefault();
  e.stopPropagation();
  post({ type: "navTab", shift: e.shiftKey });
}, true);

// ── Date helpers (ported from DailyDashboard.tsx) ───────────────────────────────────────────────
const pad = (n: number) => String(n).padStart(2, "0");
const dueDate = (t: ParsedTodo) => (t.due ?? "").slice(0, 10);
const opDate = (t: ParsedTodo) => t.followup ?? dueDate(t);
function addDays(iso: string, n: number): string {
  const [y, m, d] = iso.split("-").map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d + n));
  return `${dt.getUTCFullYear()}-${pad(dt.getUTCMonth() + 1)}-${pad(dt.getUTCDate())}`;
}
function daysBetween(a: string, b: string): number {
  const [ay, am, ad] = a.split("-").map(Number), [by, bm, bd] = b.split("-").map(Number);
  return Math.round((Date.UTC(by, bm - 1, bd) - Date.UTC(ay, am - 1, ad)) / 86_400_000);
}
function relDue(viewIso: string, due: string): string {
  const n = daysBetween(viewIso, due.slice(0, 10));
  if (n === 0) return "today"; if (n === -1) return "yesterday"; if (n === 1) return "tomorrow";
  return n < 0 ? `${-n}d ago` : `in ${n}d`;
}
function hhmm(hour: number): string { let h = Math.floor(hour), m = Math.round((hour - h) * 60); if (m === 60) { m = 0; h++; } return `${pad(h)}:${pad(m)}`; }
function finishedLabel(viewIso: string, stamp: string): string {
  const rel = relDue(viewIso, stamp.slice(0, 10));
  const time = stamp.length > 10 ? ` · ${hhmm(Number(stamp.slice(11, 13)) + Number(stamp.slice(14, 16)) / 60)}` : "";
  return `${rel}${time}`;
}

// ── Day-relative grouping (ported) ──────────────────────────────────────────────────────────────
const HIGH_PRIORITY = 3, SOON_DAYS = 7, FOLLOWUP_WINDOW = 7, RECENT_DONE_DAYS = 7;
interface Section { title: string; items: ParsedTodo[]; done?: boolean; }
// A fully deterministic identity for a todo, so items that tie on the primary sort keys keep a STABLE
// order across renders. `allTodos` is re-derived from the events list + the notes map, whose iteration
// order can shift between rebuilds — without a total tiebreak, tied items visibly swap places. Order by
// the verbatim source line, then its exact soft-link anchor (source/event/occurrence/date/line).
const tieKey = (t: ParsedTodo) =>
  `${t.raw}\0${t.source}\0${t.eventId}\0${t.occurrenceKey ?? ""}\0${t.dailyDate ?? ""}\0${String(t.line).padStart(6, "0")}`;
const cmpTie = (a: ParsedTodo, b: ParsedTodo) => (tieKey(a) < tieKey(b) ? -1 : tieKey(a) > tieKey(b) ? 1 : 0);
function sectionsForDay(todos: ParsedTodo[], viewIso: string): Section[] {
  const isToday = viewIso === today;
  const shown = todos.filter((t) => !t.done && (!t.start || t.start <= viewIso));
  const soonEnd = addDays(viewIso, SOON_DAYS), followEnd = addDays(viewIso, FOLLOWUP_WINDOW);
  const byOp = (a: ParsedTodo, b: ParsedTodo) => {
    const d = opDate(a) < opDate(b) ? -1 : opDate(a) > opDate(b) ? 1 : (b.priority ?? 0) - (a.priority ?? 0);
    return d !== 0 ? d : cmpTie(a, b);
  };
  const overdue = shown.filter((t) => opDate(t) < viewIso).sort(byOp);
  const followups = shown.filter((t) => t.followup && t.followup >= viewIso && t.followup <= followEnd).sort(byOp);
  const plain = shown.filter((t) => !t.followup);
  const dueThisDay = plain.filter((t) => dueDate(t) === viewIso).sort(byOp);
  const highSoon = plain.filter((t) => (t.priority ?? 0) >= HIGH_PRIORITY && dueDate(t) > viewIso && dueDate(t) <= soonEnd).sort(byOp);
  // Everything else due within the soon window (priority below HIGH) — a low-key catch-all so an
  // upcoming task doesn't vanish just because it isn't p:!!!.
  const lowSoon = plain.filter((t) => (t.priority ?? 0) < HIGH_PRIORITY && dueDate(t) > viewIso && dueDate(t) <= soonEnd).sort(byOp);
  const recentStart = addDays(viewIso, -RECENT_DONE_DAYS);
  const completed = todos
    .filter((t) => t.done && t.doneDate && t.doneDate.slice(0, 10) >= recentStart && t.doneDate.slice(0, 10) <= viewIso)
    .sort((a, b) => { const d = a.doneDate! < b.doneDate! ? 1 : a.doneDate! > b.doneDate! ? -1 : 0; return d !== 0 ? d : cmpTie(a, b); }).slice(0, 12);
  return [
    { title: isToday ? "Today’s Items" : "Due This Day", items: dueThisDay },
    { title: "Overdue", items: overdue },
    { title: "Remember to Followup", items: followups },
    { title: "High Priority · Due Soon", items: highSoon },
    { title: "Due Soon", items: lowSoon },
    { title: "Recently Completed", items: completed, done: true },
  ].filter((s) => s.items.length > 0);
}

// ── Rendering ───────────────────────────────────────────────────────────────────────────────────
function rowHTML(t: ParsedTodo, idx: number, viewIso: string): string {
  const date = opDate(t), overdue = date < viewIso;
  const prefix = t.eventTitle && !(t.source === "daily" && t.dailyDate === viewIso) ? `<span class="cc-dtodo-event">${esc(t.eventTitle)} · </span>` : "";
  const text = t.text ? esc(t.text) : "<em>(untitled)</em>";
  let meta = "";
  if (t.done) {
    meta = `<span class="cc-dtodo-fin">✓ ${t.doneDate ? esc(finishedLabel(viewIso, t.doneDate)) : "done"}</span>`;
  } else {
    if (t.priority) meta += `<span class="cc-dtodo-prio" data-level="${t.priority}">${"!".repeat(t.priority)}</span>`;
    meta += t.followup
      ? `<span class="cc-dtodo-followup${overdue ? " cc-dtodo-due-over" : ""}">↪ follow up ${esc(relDue(viewIso, t.followup))}</span>`
      : `<span class="cc-dtodo-due${overdue ? " cc-dtodo-due-over" : ""}">${esc(relDue(viewIso, date))}</span>`;
    meta += t.tags.slice(0, 3).map((tag) => `<span class="cc-dtodo-tag">#${esc(tag)}</span>`).join("");
  }
  return `<li class="cc-dtodo${t.done ? " cc-dtodo-is-done" : ""}">
    <input type="checkbox" class="cc-dtodo-check" data-idx="${idx}"${t.done ? " checked" : ""}>
    <span class="cc-dtodo-main" data-open="${idx}" role="button" tabindex="0" title="Go to event">
      <span class="cc-dtodo-text${t.done ? " cc-struck" : ""}">${prefix}${text}</span>
      <span class="cc-dtodo-meta">${meta}</span>
    </span></li>`;
}

// Upcoming-deadlines time window — a small dropdown in that section's header. Default: next 30 days.
// Deadlines beyond the selected window aren't shown.
type DeadlineRange = "week" | "month" | "d30" | "m3" | "m6";
let deadlineRange: DeadlineRange = "d30";
const DEADLINE_OPTS: { v: DeadlineRange; label: string }[] = [
  { v: "week", label: "This week" },
  { v: "month", label: "This month" },
  { v: "d30", label: "30 days" },
  { v: "m3", label: "3 months" },
  { v: "m6", label: "6 months" },
];
function addMonthsIso(iso: string, n: number): string {
  const [y, m, d] = iso.split("-").map(Number);
  const dt = new Date(Date.UTC(y, m - 1 + n, d));
  return `${dt.getUTCFullYear()}-${pad(dt.getUTCMonth() + 1)}-${pad(dt.getUTCDate())}`;
}
// The last day (inclusive) to show deadlines through, for the selected window (measured from viewIso).
function deadlineWindowEnd(viewIso: string): string {
  const [y, m, d] = viewIso.split("-").map(Number);
  switch (deadlineRange) {
    case "week":  return addDays(viewIso, 6 - new Date(Date.UTC(y, m - 1, d)).getUTCDay());   // through Saturday
    case "month": return `${y}-${pad(m)}-${pad(new Date(Date.UTC(y, m, 0)).getUTCDate())}`;   // through month end
    case "m3":    return addMonthsIso(viewIso, 3);
    case "m6":    return addMonthsIso(viewIso, 6);
    default:      return addDays(viewIso, 30);   // d30
  }
}

function deadlineHTML(viewIso: string): string {
  const end = deadlineWindowEnd(viewIso);
  const upcoming = deadlines
    .map((d) => ({ d, iso: `${d.year}-${pad(d.month + 1)}-${pad(d.day)}` }))
    .filter((x) => x.iso >= viewIso && x.iso <= end)
    .sort((a, b) => (a.iso < b.iso ? -1 : a.iso > b.iso ? 1 : a.d.hour - b.d.hour) || (a.d.id < b.d.id ? -1 : a.d.id > b.d.id ? 1 : 0))
    .slice(0, 10);
  const opts = DEADLINE_OPTS.map((o) => `<option value="${o.v}"${o.v === deadlineRange ? " selected" : ""}>${o.label}</option>`).join("");
  const select = `<select class="cc-dd-range" title="Deadline window">${opts}</select>`;
  const head = `<div class="cc-dd-sec-head"><span class="cc-dd-sec-title">Upcoming Deadlines</span>${upcoming.length ? `<span class="cc-dd-sec-count">${upcoming.length}</span>` : ""}${select}</div>`;
  const body = upcoming.length
    ? `<ul class="cc-dd-ddl-list">${upcoming.map(({ d, iso }) =>
        `<li class="cc-dd-ddl cc-ev-${esc(d.color)}" data-ddl="${esc(d.id)}" role="button" tabindex="0" title="Go to deadline">
          <span class="cc-dd-ddl-dot"></span>
          <span class="cc-dd-ddl-title">${d.title ? esc(d.title) : "<em>(untitled)</em>"}</span>
          <span class="cc-dd-ddl-when">${esc(relDue(viewIso, iso))} · ${hhmm(d.hour)}</span></li>`).join("")}</ul>`
    : `<div class="cc-dd-free">No deadlines in this window.</div>`;
  // `cc-dd-ddl-sec` + `data-iso` let the range dropdown re-render just this section (keeping todos in place).
  return `<section class="cc-dd-sec cc-dd-ddl-sec" data-iso="${viewIso}">${head}${body}</section>`;
}

// Render one day's content into a panel's inner scroller. TODO → the grouped list; NOTE → a static
// markdown preview of that day's note (so the note carousels per-day like the list).
function renderPanel(el: HTMLElement, viewIso: string) {
  const scroll = scrollOf.get(el) ?? el;
  isoOf.set(el, viewIso);
  if (tab === "note") {
    // Content-based: a note with content shows its rendered preview; an empty day shows the editor
    // placeholder — the SAME representation the settled panel uses, so scrolling never flips modes.
    const text = notes[viewIso] || "";
    scroll.innerHTML = text.trim()
      ? `<div class="cc-dw-md cc-dd-note-md">${renderMarkdown(text)}</div>`
      : `<div class="cc-dd-note-empty">Daily Note</div>`;
    scroll.scrollTop = scrollByIso[viewIso] ?? 0;   // restore THIS day's own scroll (see the todo branch)
    flatOf.delete(el);
    return;
  }
  ensureTodos();                                       // lazy: rebuild only if data changed since last view
  const sections = sectionsForDay(allTodos, viewIso);
  const flat = sections.flatMap((s) => s.items);
  flatOf.set(el, flat);
  let i = -1;
  const secHTML = sections.map((s) =>
    `<section class="cc-dtodo-sec"><div class="cc-dtodo-sec-head"><span class="cc-dtodo-sec-title">${esc(s.title)}</span><span class="cc-dtodo-sec-count">${s.items.length}</span></div><ul class="cc-dtodo-list">${s.items.map((t) => rowHTML(t, ++i, viewIso)).join("")}</ul></section>`).join("");
  const body = sections.length ? secHTML : `<div class="cc-dtodo-empty">Nothing on the list — you’re clear.</div>`;
  scroll.innerHTML = deadlineHTML(viewIso) + body;
  // The two panels are RECYCLED across days and `daily.dom` advances mid-swipe (setDayProgress), so a
  // panel is re-rendered for a new day WHILE it's on screen. Restore THIS day's own remembered scroll
  // (0 for a day we haven't scrolled) — keyed by iso, so it never inherits the other panel's offset and
  // re-rendering the day you're on lands exactly where you already are (no teleport).
  scroll.scrollTop = scrollByIso[viewIso] ?? 0;
}

let liveShown = false, liveMode = "";
// Apply the current tick: the zoom reveal (whole-panel slide-in-from-right + fade) on #dash, then
// position + fade the two day panels within it like SceneRenderer.drawPanel; then place the live note
// editor over the centered panel at rest.
let dayViewShown = false;   // true once the dashboard is revealed (day view); reset when hidden
function apply() {
  const { from, to, dir, p, reveal, slide, scopeA, scopeB, scopeT, dy, mFrom, mTo, mDy0, mDy1, mP,
          wFrom, wTo, wP, maskX, maskW, aName, aX, aW, aOp, bName, bX, bW, bOp } = last;
  // Leaving day view (reveal fell to hidden) forgets every day's scroll, so re-entering day view always
  // starts at the top — the scroll doesn't carry across a trip out to week/month view. The reset on
  // re-entry restores from the (now-empty) map, i.e. 0, without re-rendering the unchanged panels.
  if (reveal < 0.02) {
    if (dayViewShown) { dayViewShown = false; scrollByIso = {}; }
  } else if (!dayViewShown) {
    dayViewShown = true;
    // Re-entering day view is a FULL re-render: drop the cached day so the TODO list re-sorts — items
    // checked-in-place last time now settle into "Recently Completed" — and start at the top.
    isoOf.delete(p0); isoOf.delete(p1);
    P0.scroll.scrollTop = 0; P1.scroll.scrollTop = 0;
  }
  // #dash IS the mask: positioned + sized to the live clip region (frame-local px from Swift's
  // dashScopePanels — the SAME numbers the Canvas header clips with). The accordion dy rides as
  // a transform; the reveal FADE is native (view alphaValue — see setPanelAlpha).
  root.style.left = `${maskX.toFixed(1)}px`;
  root.style.width = `${Math.max(0, maskW).toFixed(1)}px`;
  root.style.transform = `translateY(${dy.toFixed(1)}px)`;
  root.style.pointerEvents = reveal > 0.999 ? "auto" : "none";
  // ── Zoom-scope carousel: each panel is placed at its OWN target width and absolute position
  // (dashScopePanels' numbers, frame-local → mask-local by subtracting maskX) — exactly the
  // geometry the Canvas header draws with, so the two align by construction and stay continuous
  // in z (nothing keys on the rounded level; no z=1.5 snap).
  const layers: Record<string, HTMLElement> = { day: panelsEl, week: weekLayer, month: monthLayer };
  const t = scopeT;
  for (const [name, el] of Object.entries(layers)) {
    let x = 0, w = 0, op = 0;
    if (name === aName) { x = aX; w = aW; op = aOp; }
    else if (name === bName) { x = bX; w = bW; op = bOp; }
    el.style.left = `${(x - maskX).toFixed(1)}px`;
    el.style.width = `${Math.max(0, w).toFixed(1)}px`;
    el.style.transform = "none";
    el.style.opacity = op.toFixed(3);
    el.style.pointerEvents = op > 0.999 ? "auto" : "none";
  }
  const scopeIsDay = (t > 0.5 ? scopeB : scopeA) === "day";
  // Month page-turn: the sub-panels ride their bands' frames in PIXELS (mDy0/mDy1 are the
  // band-frame deltas Swift computes — same staggered easing, same asymmetric travel as the
  // Canvas header) and FADE with displacement, the day-paging carousel's 1 − |offset|/size rule.
  // Identity first: if the "from" month currently lives in panel B (the pager re-based and
  // from/to swapped), swap the ROLES so each panel keeps its month — continuous positions.
  const fromLabel = mFrom || "Month";
  if (mpLabel.get(mpB) === fromLabel) {
    const t2 = mpA; mpA = mpB; mpB = t2;
  }
  // Fade by TURN PROGRESS (1−p / p — the day-carousel house rule), not by displacement: the
  // band-frame travel (~350px) is well short of the panel height, so a distance-based fade only
  // reached ~50% and the exit read as clipping/occlusion instead of a fade.
  renderMonthPH(mpA, fromLabel);
  mpA.style.transform = `translateY(${mDy0.toFixed(1)}px)`;
  mpA.style.opacity = (1 - mP).toFixed(3);
  if (mTo) {
    renderMonthPH(mpB, mTo);
    mpB.style.transform = `translateY(${mDy1.toFixed(1)}px)`;
    mpB.style.opacity = mP.toFixed(3);
  } else {
    mpB.style.opacity = "0";
  }
  // Week turn: the sub-panels carousel HORIZONTALLY, driven by the continuous week scroll
  // (wP ramps while the viewport's left border sweeps the turn band; rests at BOTH 0 and 1).
  // Same identity-keying + fade-by-progress rules as the month pair above.
  const wFromLabel = wFrom || "Week";
  if (wpLabel.get(wpB) === wFromLabel) {
    const t3 = wpA; wpA = wpB; wpB = t3;
  }
  renderWeekPH(wpA, wFromLabel);
  wpA.style.transform = `translateX(${(-wP * 100).toFixed(3)}%)`;
  wpA.style.opacity = (1 - wP).toFixed(3);
  if (wTo && wP > 0.001) {
    renderWeekPH(wpB, wTo);
    wpB.style.transform = `translateX(${((1 - wP) * 100).toFixed(3)}%)`;
    wpB.style.opacity = wP.toFixed(3);
  } else {
    wpB.style.opacity = "0";
  }
  if (isoOf.get(p0) !== from) renderPanel(p0, from);
  const atRest = !to || p <= 0.0001;
  if (atRest) {                                   // single centered panel
    p0.style.transform = "translateX(0)"; p0.style.opacity = "1"; p0.style.pointerEvents = "auto";
    p1.style.opacity = "0"; p1.style.pointerEvents = "none";
  } else {
    if (isoOf.get(p1) !== to) renderPanel(p1, to);
    // current slides out by -dir·p, fades to 1−p; incoming enters from dir·(1−p), fades to p.
    p0.style.transform = `translateX(${(-dir * p * 100).toFixed(3)}%)`; p0.style.opacity = (1 - p).toFixed(3);
    p1.style.transform = `translateX(${(dir * (1 - p) * 100).toFixed(3)}%)`; p1.style.opacity = p.toFixed(3);
    p0.style.pointerEvents = "none"; p1.style.pointerEvents = "none";
  }
  // Live editor: NOTE tab, fully open, at rest → overlay the centered panel (which is hidden so its
  // static preview doesn't peek through). During a swipe/zoom the panels' note previews carousel.
  const showLive = tab === "note" && atRest && reveal > 0.999 && scopeIsDay && t % 1 === 0;
  noteLive.style.display = showLive ? "" : "none";
  p0.style.visibility = showLive ? "hidden" : "";
  if (showLive) {
    const text = notes[from] || "";
    if (liveIso !== from) {
      liveIso = from;
      // Content-based default for the day we landed on; tell Swift so the native toggle reflects it.
      const m = text.trim() ? "preview" : "edit";
      if (m !== noteMode) { noteMode = m; liveMode = ""; post({ type: "noteMode", mode: m }); }
    }
    // Sync the editor to THIS day's note. Re-set whenever it changed underneath us — e.g. a checkbox
    // toggled in the TODO tab rewrote this same day's note (adding `[x]` + a `done:` stamp) — so the
    // preview never keeps showing the stale, pre-toggle text. (setValue is a no-op when unchanged, and
    // matches the editor doc while the user types, so this won't fight live editing.)
    if (text !== liveText) { liveText = text; noteEd.setValue(text); }
    if (!liveShown || liveMode !== noteMode) { liveMode = noteMode; noteEd.setMode(noteMode); }
  }
  liveShown = showLive;
  applyNav();   // keep the keyboard-nav ring on the (possibly re-rendered) focused row / note
}

// ── Toggle a checkbox → rewrite the source note line via its soft-link, post the new note ────────
// Mirrors the web's `toggleTodoLine`: the (source, line) anchor locates one line; the markdown stays
// the source of truth. Works for event notes (series / per-occurrence) AND daily notes.
//
// The row is toggled IN PLACE — the strike-through animates and the item stays put; it only migrates to
// "Recently Completed" on the next FULL render (day swipe / zoom out+in / data reload), NOT instantly.
function setRowDone(row: HTMLElement, done: boolean) {
  const cb = row.querySelector<HTMLInputElement>(".cc-dtodo-check");
  if (cb) cb.checked = done;
  row.classList.toggle("cc-dtodo-is-done", done);   // color fade (CSS transition)
  const textEl = row.querySelector<HTMLElement>(".cc-dtodo-text");
  if (textEl) animateStrike(textEl, done);           // strike-through draws / retracts (wraps across lines)
}

// Character-progressive strike-through: wrap a growing (done) / shrinking (undone) PREFIX of the text in
// <span class="cc-strike"> so real line-through is drawn — which wraps naturally across multiple lines,
// unlike a single CSS line. At the rest states it hands back to the static `.cc-struck` class (also real
// line-through) with the original markup (the grey event-title prefix span) intact.
type StrikeSt = { raf: number; frac: number; clean: string; full: string };
const strikeState = new WeakMap<HTMLElement, StrikeSt>();
function paintStrike(el: HTMLElement, s: StrikeSt) {
  const n = Math.round(s.full.length * s.frac);
  if (n <= 0) { el.innerHTML = s.clean; el.classList.remove("cc-struck"); return; }        // fully unstruck
  if (n >= s.full.length) { el.innerHTML = s.clean; el.classList.add("cc-struck"); return; } // fully struck (wraps)
  el.classList.remove("cc-struck");
  el.innerHTML = `<span class="cc-strike">${esc(s.full.slice(0, n))}</span>${esc(s.full.slice(n))}`;
}
function animateStrike(el: HTMLElement, done: boolean) {
  let s = strikeState.get(el);
  if (s) cancelAnimationFrame(s.raf);
  // First toggle of this row: the markup is clean (strike lives in the class), so capture it as the
  // structured original + its plain text. On a rapid re-toggle we reuse the stored copies.
  else s = { raf: 0, frac: done ? 0 : 1, clean: el.innerHTML, full: el.textContent ?? "" };
  strikeState.set(el, s);
  const from = s.frac, target = done ? 1 : 0, t0 = performance.now(), DUR = 260;
  const step = (now: number) => {
    const p = Math.min(1, (now - t0) / DUR);
    s!.frac = from + (target - from) * p;
    paintStrike(el, s!);
    if (p < 1) { s!.raf = requestAnimationFrame(step); }
    else { s!.frac = target; paintStrike(el, s!); if (target === 0) strikeState.delete(el); }
  };
  s.raf = requestAnimationFrame(step);
}
// Checking a box posts the note change to Swift, which persists it and echoes the whole data map back
// via CK.setData. That echo must NOT re-sort the list (the checked row stays in place, animating) — so
// we note WHEN we made an edit and treat any setData in the next window as our own echo (see setData).
let selfEditAt = -1e9;
const SELF_ECHO_MS = 500;
// The completion stamp: the app's day + the real wall-clock time to the SECOND, so "Recently Completed"
// sorts by precise finish time (not just the date). Kept on the app's `today` so the item lands in the
// completed window for today regardless of a simulated clock.
function doneStamp(): string {
  const d = new Date();
  const p2 = (n: number) => String(n).padStart(2, "0");
  return `${today}T${p2(d.getHours())}:${p2(d.getMinutes())}:${p2(d.getSeconds())}`;
}
function toggle(panel: HTMLElement, idx: number) {
  const t = (flatOf.get(panel) ?? [])[idx];
  if (!t) return;
  const row = panel.querySelector<HTMLElement>(`.cc-dtodo-check[data-idx="${idx}"]`)?.closest(".cc-dtodo") as HTMLElement | null;
  const wasDone = row?.classList.contains("cc-dtodo-is-done") ?? t.done;
  const stamp = doneStamp();
  let ok = false;
  if (t.source === "daily") {
    const date = t.dailyDate ?? "";
    const next = toggleTodoLine(notes[date] ?? "", t.line, undefined, stamp);
    if (next != null && next !== notes[date]) { notes[date] = next; post({ type: "noteChange", date, value: next }); ok = true; }
  } else {
    const ev = events.find((e) => e.id === t.eventId);
    if (ev) {
      const isOcc = !!t.occurrenceKey;
      const src = isOcc ? (ev.occurrenceNotes?.[t.occurrenceKey!] ?? "") : (ev.notes ?? "");
      const next = toggleTodoLine(src, t.line, undefined, stamp);
      if (next != null && next !== src) {
        if (isOcc) ev.occurrenceNotes = { ...(ev.occurrenceNotes ?? {}), [t.occurrenceKey!]: next };
        else ev.notes = next;
        post({ type: "toggle", eventId: t.eventId, occKey: isOcc ? t.occurrenceKey : null, value: next });
        ok = true;
      }
    }
  }
  if (ok) { todosDirty = true; selfEditAt = performance.now(); }   // suppress the setData echo's re-sort
  if (row) setRowDone(row, ok ? !wasDone : wasDone);               // animate in place (revert native flip if unchanged)
}

// Event delegation — resolve which panel the target belongs to, then its cached flat list.
function panelOf(e: Event): HTMLElement | null { return (e.target as HTMLElement).closest(".cc-dd-panel"); }
root.addEventListener("change", (e) => {
  const el = e.target as HTMLElement;
  if (el.classList.contains("cc-dd-range")) {   // the Upcoming-Deadlines window dropdown
    deadlineRange = (el as HTMLSelectElement).value as DeadlineRange;
    const sec = el.closest(".cc-dd-ddl-sec") as HTMLElement | null;
    if (sec) sec.outerHTML = deadlineHTML(sec.dataset.iso ?? last.from);   // re-render just this section
    return;
  }
  if (!el.classList.contains("cc-dtodo-check")) return;
  const panel = panelOf(e); if (!panel) return;
  toggle(panel, Number((el as HTMLInputElement).dataset.idx));
});
root.addEventListener("click", (e) => {
  const openEl = (e.target as HTMLElement).closest("[data-open]") as HTMLElement | null;
  const panel = panelOf(e);
  if (openEl && panel) {
    const todo = (flatOf.get(panel) ?? [])[Number(openEl.dataset.open)];
    if (todo) {
      // A daily-note todo isn't an event → don't open the drawer; fly to that day + open the NOTE tab.
      if (todo.source === "daily") post({ type: "jumpDay", date: todo.dailyDate });
      else post({ type: "open", eventId: todo.eventId, occKey: todo.occurrenceKey });
    }
    return;
  }
  const ddl = (e.target as HTMLElement).closest("[data-ddl]") as HTMLElement | null;
  if (ddl) { post({ type: "open", eventId: ddl.dataset.ddl }); return; }
  // A click on genuinely empty dashboard space (not a todo row, deadline, checkbox, tab, or editor)
  // deselects the current event — parity with clicking empty calendar space.
  if ((e.target as HTMLElement).closest("input,button,a,textarea,select,[contenteditable='true'],[data-open],[data-ddl],#note-live,.cm-editor")) return;
  post({ type: "deselect" });
});

(window as any).CK = {
  setData(json: string) {
    const d = JSON.parse(json);
    events = d.events || []; deadlines = d.deadlines || []; today = d.today || "";
    notes = d.dailyNotes || {};
    todosDirty = true;                    // re-aggregate event + daily-note todos on next todo render
    if (!last.from) last.from = d.viewIso || today;
    // If this data push is just the echo of a checkbox WE just toggled, update the data but leave the
    // panels in place — the checked row stays put (mid-animation) and only migrates to "Recently
    // Completed" on a real re-render (day swipe / zoom out+in). External changes still re-render.
    if (performance.now() - selfEditAt < SELF_ECHO_MS) return;
    isoOf.delete(p0); isoOf.delete(p1);   // force a re-render with the new data
    apply();
  },
  tick(t: Partial<typeof TICK_DEFAULTS>) {
    last = { ...TICK_DEFAULTS, ...t, to: t.to || "" };
    apply();
  },
  setTab(t: "todo" | "note") { applyTab(t); },               // Swift (native tabs) drives the tab
  setNoteMode(m: "edit" | "preview") {                       // native edit/preview toggle (no echo back)
    if (noteMode !== m) { noteMode = m; liveMode = ""; apply(); }
  },
  setInactive(on: boolean) { scrim.classList.toggle("on", on); },   // drawer open → blur + block the dashboard
  setTheme(vars: Record<string, string>) { const s = document.documentElement.style; for (const k in vars) s.setProperty(k, vars[k]); },
  // ── Keyboard nav bridge (driven by the calendar's key system) ──
  navSet(stop: "todo" | "note" | "none") {   // Tab focus in/out of the dashboard stops
    navStop = stop === "none" ? null : stop;
    editingNote = false;
    if (navStop === "todo") todoCursor = 0;   // land on the first row
    applyNav();
  },
  navMove(delta: number) { if (navStop === "todo") { todoCursor += delta; applyTodoCursor(); } },   // ↑/↓ rows
  navActivate() {                              // Space on the TODO stop → toggle the focused row (in place)
    if (navStop === "todo") toggle(p0, todoCursor);
  },
  navOpen() {                                  // Enter on the TODO stop → open the focused row
    if (navStop !== "todo") return;
    const t = (flatOf.get(p0) ?? [])[todoCursor];
    if (!t) return;
    if (t.source === "daily") post({ type: "jumpDay", date: t.dailyDate });
    else post({ type: "open", eventId: t.eventId, occKey: t.occurrenceKey });
  },
  noteEdit() {                                 // Enter on the NOTE stop → focus the live editor
    editingNote = true; applyNav();
    noteModeUser("edit");
    queueMicrotask(() => { noteEd.setMode("edit"); noteEd.focus(); });
  },
};
post({ type: "ready" });
