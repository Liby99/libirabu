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
// Weekly/monthly notes live in the SAME persisted notes map under prefixed keys — the storage,
// backup, and sync layers treat keys as opaque, so scope notes ride the daily-note pipeline.
const weekNoteKey = (sunIso: string) => `week:${sunIso}`;       // sunIso = the week's Sunday
const monthNoteKey = (ym: string) => `month:${ym}`;             // ym = "YYYY-MM"
function monthEndIso(ym: string): string {
  const [y, m] = ym.split("-").map(Number);
  return `${ym}-${String(new Date(Date.UTC(y, m, 0)).getUTCDate()).padStart(2, "0")}`;
}
// A scope note's `- [ ]` lines join the global TODO index like daily-note lines do — parsed
// against the range START (so relative `due:` tokens resolve inside the range), then re-anchored:
// the soft-link key becomes the scope note's storage key (toggling rewrites the right note), and
// undated items default their due date to the range END ("finish within the week/month").
function scopeNoteTodos(key: string, anchorIso: string, endIso: string, title: string, text: string): ParsedTodo[] {
  const ts = parseDailyNoteTodos(anchorIso, text, today);
  for (const t of ts) {
    t.dailyDate = key;
    t.eventTitle = title;
    if (t.dueSource !== "line") t.due = endIso;
  }
  return ts;
}
function ensureTodos() {
  if (!todosDirty) return;
  allTodos = [...indexTodos(events, today)];
  for (const [key, text] of Object.entries(notes)) {
    if (key.startsWith("week:")) {
      const sun = key.slice(5);
      allTodos.push(...scopeNoteTodos(key, sun, addDays(sun, 6), `Weekly note · ${sun}`, text));
    } else if (key.startsWith("month:")) {
      const ym = key.slice(6);
      allTodos.push(...scopeNoteTodos(key, `${ym}-01`, monthEndIso(ym), `Monthly note · ${ym}`, text));
    } else {
      allTodos.push(...parseDailyNoteTodos(key, text, today));
    }
  }
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
                        mKeyA: "", mKeyB: "",   // month machine keys "YYYY-MM" (notes + filters)
                        wFrom: "", wTo: "", wP: 0,
                        wKeyA: "", wKeyB: "",   // week machine keys: the Sunday "YYYY-MM-DD"
                        // Per-panel scope geometry from Swift's dashScopePanels (frame-local px):
                        // the mask (clip) region + each panel's own left/width/opacity.
                        maskX: 0, maskW: 0,
                        aName: "", aX: 0, aW: 0, aOp: 0,
                        bName: "", bX: 0, bW: 0, bOp: 0,
                        shift: 0 };   // drawer canvas-shift: content rides the canvas slide (week/month)
let last = { ...TICK_DEFAULTS };

const root = document.getElementById("dash")!;                 // reveal wrapper (zoom slide + fade)
const panelsEl = document.getElementById("panels")!;           // carousel content (todo OR note preview)
const noteLive = document.getElementById("note-live")!;        // live editor overlay (rest + note only)

// ── Zoom-scope layers (weekly / monthly) ────────────────────────────────────────────────────────
// The WEEK layer holds two side-by-side sub-panels that carousel HORIZONTALLY during a week turn
// (Swift ticks wKeyA/wKeyB/wP from the continuous week scroll); the MONTH layer's pair carousels
// VERTICALLY with month page-turns. The DAY layer is the existing #panels (+ note editor); all
// three are siblings that slide/fade with the same math. Content: renderScopePanel below.
function makeScopeLayer(id: string): { layer: HTMLElement; a: HTMLElement; b: HTMLElement } {
  const layer = document.createElement("div");
  layer.className = "cc-dd-panel"; layer.id = id;
  root.appendChild(layer);
  const sub = () => {
    const el = document.createElement("div");
    el.className = "cc-dd-panel";         // absolute-fill inside the layer
    layer.appendChild(el);
    return el;
  };
  return { layer, a: sub(), b: sub() };
}
const W = makeScopeLayer("scope-week"), M = makeScopeLayer("scope-month");
const weekLayer = W.layer, monthLayer = M.layer;
// Role panels are IDENTITY-KEYED by machine key (mirroring the day panels' isoOf): when the
// pager/scroll re-bases mid-turn (from/to swap), each panel KEEPS its week/month — positions
// stay continuous across the flip instead of two panels teleport-swapping contents.
let wpA = W.a, wpB = W.b, mpA = M.a, mpB = M.b;
const scopeKeyOf = new Map<HTMLElement, string>();   // sub-panel → machine key (role identity)
const scopeSig = new Map<HTMLElement, string>();     // sub-panel → rendered signature (render cache)
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
let tab: "todo" | "note" | "proj" = "todo";
let noteMode: "edit" | "preview" = "edit";
let notes: Record<string, string> = {};
let liveIso = "";                                      // the note KEY the live editor currently holds
let liveText = "";                                     // the note value currently in the editor (detects external changes)
let liveScope: "day" | "week" | "month" = "day";       // which scope the live editor is anchored to
const SCOPE_WORD = { day: "daily", week: "weekly", month: "monthly" } as const;
// Empty-note preview: an invitation with a link into the markdown editor (see the root click
// delegation — `.cc-dd-note-write` switches to edit mode). Used by the LIVE preview and the
// static carousel previews alike.
function emptyNoteHTML(scope: "day" | "week" | "month"): string {
  return `<div class="cc-dd-note-empty">Empty ${SCOPE_WORD[scope]} note. <a class="cc-dd-note-write" role="button">Write something</a></div>`;
}
const noteEd = createNoteEditor({
  editorEl: document.getElementById("note-editor")!,
  previewEl: document.getElementById("note-preview")!,
  placeholder: "Daily Note (Markdown)…",
  onChange: (value) => { notes[liveIso] = value; liveText = value; todosDirty = true; projectsDirty = true; entityDirty = true; post({ type: "noteChange", date: liveIso, value }); },
  // ⌘S → preview, and (if we were keyboard-focused via Tab) hand focus back to the calendar's NOTE ring.
  onPreview: () => { noteModeUser("preview"); post({ type: "navNoteExit" }); },
  onExit: () => post({ type: "navNoteExit" }),             // Escape in the editor → back to the NOTE ring
  onOpenLink: (url) => post({ type: "openLink", url }),
  onEditAt: (line) => { noteModeUser("edit"); noteEd.setCursorLine(line); },   // ⌘-click a preview block
  emptyPreview: () => emptyNoteHTML(liveScope),
  completionIndex, // @project:/@person:/#tag completions from the live entity index
  // due: context anchor — a DAILY note offers "this day time" (its own date). Week/month notes
  // have a range, not a moment → no anchor there.
  dueAnchor: () => (liveScope === "day" && liveIso && !liveIso.includes(":")
    ? { label: "this day time", value: liveIso.slice(0, 10) } : null),
});

// ── Keyboard nav from the calendar (Tab into the dashboard TODO / NOTE stops) ──────────────────────
// The calendar's key system stays in control and drives these via CK.nav*; the focused row / note gets
// the SAME dashed red ring as the calendar's cursors. `navStop` is which stop is focused (null = none),
// `todoCursor` the focused TODO row, `editingNote` true once the note editor is focused (ring hidden).
let navStop: "todo" | "note" | null = null;
let todoCursor = 0;
let editingNote = false;
let editingRing = false;   // ⌘E from keyboard mode: keep the dashed ring visible WHILE editing
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
  // The NOTE ring shows on the focused-but-not-editing stop, AND while editing when the entry
  // came from keyboard mode (⌘E with a ring already showing — focus visibly moved here).
  noteLive.classList.toggle("cc-nav-on", navStop === "note" && (!editingNote || editingRing));
  applyTodoCursor();
}
function applyTab(t: "todo" | "note" | "proj") { tab = t; isoOf.delete(p0); isoOf.delete(p1); scopeSig.clear(); apply(); }
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
interface Section { key: string; title: string; items: ParsedTodo[]; done?: boolean; }
// A fully deterministic identity for a todo, so items that tie on the primary sort keys keep a STABLE
// order across renders. `allTodos` is re-derived from the events list + the notes map, whose iteration
// order can shift between rebuilds — without a total tiebreak, tied items visibly swap places.
// Order by the soft-link anchor (source/event/occurrence/date) then LINE NUMBER, so tied items from
// the SAME note keep their source order — nested sub-tasks stay under their parents. (The raw line
// must NOT lead this key: children's leading indentation sorted before unindented parents, showing
// scope-note lists — where undated items all tie on the range-end due date — upside down.)
const tieKey = (t: ParsedTodo) =>
  `${t.source}\0${t.eventId}\0${t.occurrenceKey ?? ""}\0${t.dailyDate ?? ""}\0${String(t.line).padStart(6, "0")}\0${t.raw}`;
const cmpTie = (a: ParsedTodo, b: ParsedTodo) => (tieKey(a) < tieKey(b) ? -1 : tieKey(a) > tieKey(b) ? 1 : 0);
// ── Layering prefs (pushed from Swift via CK.setTodoPrefs; keys sync with DashTodoPrefs.swift) ──
// Per dashboard scope: which SOURCES feed the list, which COLLECTIONS render, deadlines on/off.
// Defaults mirror the Swift side (each scope collects down to its own granularity) so a fresh
// webview renders sensibly before the first push lands.
interface TodoPrefs { deadlines: boolean; sections: string[]; sources: string[] }
let todoPrefs: Record<"day" | "week" | "month", TodoPrefs> = {
  day:   { deadlines: true, sections: ["dueDay", "overdue", "followup", "highSoon", "dueSoon", "done"], sources: ["event", "daily"] },
  week:  { deadlines: true, sections: ["open", "done"], sources: ["event", "daily", "weekly"] },
  month: { deadlines: true, sections: ["open", "done"], sources: ["event", "daily", "weekly", "monthly"] },
};
/** Which layer a todo came from: event notes, or the note kind its dailyDate key encodes. */
function todoLayer(t: ParsedTodo): string {
  if (t.source === "event") return "event";
  const d = t.dailyDate ?? "";
  return d.startsWith("week:") ? "weekly" : d.startsWith("month:") ? "monthly" : "daily";
}
// Empty list: distinguish "nothing due" from "you filtered every source away".
const emptyListHTML = (p: TodoPrefs) =>
  `<div class="cc-dtodo-empty">${p.sources.length
    ? "Nothing on the list — you’re clear."
    : "All sources hidden — pick some in the ⚙ menu."}</div>`;

function sectionsForDay(todos: ParsedTodo[], viewIso: string): Section[] {
  const isToday = viewIso === today;
  const p = todoPrefs.day;
  todos = todos.filter((t) => p.sources.includes(todoLayer(t)));
  // NESTED todos: only ROOT items are sectioned/sorted. Each root then renders with its full
  // subtree beneath it — done and not-done children alike — so a child never appears as its own
  // top-level row (see renderPanel + subtree()).
  const roots = todos.filter((t) => t.parentLine == null);
  const shown = roots.filter((t) => !t.done && (!t.start || t.start <= viewIso));
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
  const completed = roots
    .filter((t) => t.done && t.doneDate && t.doneDate.slice(0, 10) >= recentStart && t.doneDate.slice(0, 10) <= viewIso)
    .sort((a, b) => { const d = a.doneDate! < b.doneDate! ? 1 : a.doneDate! > b.doneDate! ? -1 : 0; return d !== 0 ? d : cmpTie(a, b); }).slice(0, 12);
  return [
    { key: "dueDay", title: isToday ? "Today’s Items" : "Due This Day", items: dueThisDay },
    { key: "overdue", title: "Overdue", items: overdue },
    { key: "followup", title: "Remember to Followup", items: followups },
    { key: "highSoon", title: "High Priority · Due Soon", items: highSoon },
    { key: "dueSoon", title: "Due Soon", items: lowSoon },
    { key: "done", title: "Recently Completed", items: completed, done: true },
  ].filter((s) => s.items.length > 0 && p.sections.includes(s.key));
}

// ── Nesting: group children under their parent via the (note-scope, parentLine) soft link ────────
// Todos from DIFFERENT notes can share line numbers, so the child index is keyed by the full note
// scope (source + event/occurrence or daily date) plus the parent's line.
const scopeKey = (t: ParsedTodo) => `${t.source}\0${t.eventId}\0${t.occurrenceKey ?? ""}\0${t.dailyDate ?? ""}`;
function childrenIndex(todos: ParsedTodo[]): Map<string, ParsedTodo[]> {
  const idx = new Map<string, ParsedTodo[]>();
  for (const t of todos) {
    if (t.parentLine == null) continue;
    const k = `${scopeKey(t)}\0${t.parentLine}`;
    const list = idx.get(k);
    if (list) list.push(t);
    else idx.set(k, [t]);
  }
  for (const list of idx.values()) list.sort((a, b) => a.line - b.line);
  return idx;
}
/** A root and all its descendants, in source order (parent first, then each child's subtree). */
function subtree(t: ParsedTodo, kids: Map<string, ParsedTodo[]>, out: ParsedTodo[] = []): ParsedTodo[] {
  out.push(t);
  for (const c of kids.get(`${scopeKey(t)}\0${t.line}`) ?? []) subtree(c, kids, out);
  return out;
}

// ── Folding: any row WITH children gets a disclosure chevron; everything starts expanded ─────────
// `collapsed` holds the folded parents (so the default for a never-touched row is open), keyed by
// the same (note-scope, line) soft link as the child index. Session-lived, like the scroll memory —
// editing a note can renumber lines, in which case a stale key just no-ops.
const collapsed = new Set<string>();
const foldKey = (t: ParsedTodo) => `${scopeKey(t)}\0${t.line}`;
function setFolded(t: ParsedTodo, folded: boolean) {
  if (folded) collapsed.add(foldKey(t));
  else collapsed.delete(foldKey(t));
}

// ── Fold/unfold with motion ─────────────────────────────────────────────────────────────────────
// The chevron rotates; revealed sub-rows DROP IN (height grows + fade + slight rise, staggered top
// to bottom so the drop cascades); collapsing runs the same in reverse (bottom rows retract first)
// before the fold is committed. Expand re-renders FIRST (the rows must exist to animate in — the
// fresh chevron is then spun from its folded pose); collapse animates the live rows OUT and only
// re-renders once they're gone. Row height/padding animate through layout, so the rows below glide
// instead of teleporting. `folding` guards a parent whose collapse is still in flight.
const FOLD_MS = 170;
const folding = new Set<string>();
/** The currently-VISIBLE rows of `t`'s subtree (excluding `t` itself) inside `panel`. */
function rowsOfSubtree(panel: HTMLElement, t: ParsedTodo): HTMLElement[] {
  const flat = flatOf.get(panel) ?? [];
  const inSub = new Set(subtree(t, childrenIndex(allTodos)).slice(1));
  return Array.from(panel.querySelectorAll<HTMLElement>(".cc-dtodo"))
    .filter((r) => inSub.has(flat[Number(r.dataset.idx ?? -1)]));
}
/** One row's drop-in / retract keyframes. `.cc-dtodo` is content-box with 3px vertical padding,
 *  so the content height and the paddings animate as separate properties. */
function foldFrames(r: HTMLElement) {
  const ch = Math.max(0, r.offsetHeight - 6);
  return [
    { height: "0px", paddingTop: "0px", paddingBottom: "0px", opacity: 0, transform: "translateY(-8px)" },
    { height: `${ch}px`, paddingTop: "3px", paddingBottom: "3px", opacity: 1, transform: "translateY(0px)" },
  ];
}
function toggleFold(panel: HTMLElement, t: ParsedTodo, open: boolean) {
  const k = foldKey(t);
  const iso = isoOf.get(panel);
  if (folding.has(k) || !iso) return;
  if (open) {
    setFolded(t, false);
    renderPanel(panel, iso);
    applyNav();
    const flat = flatOf.get(panel) ?? [];
    const btn = panel.querySelector(`.cc-dtodo-fold[data-fold="${flat.indexOf(t)}"]`);
    btn?.animate([{ transform: "rotate(0deg)" }, { transform: "rotate(90deg)" }], { duration: FOLD_MS, easing: "ease" });
    rowsOfSubtree(panel, t).forEach((r, i) => {
      r.style.overflow = "hidden";
      const a = r.animate(foldFrames(r), {
        duration: FOLD_MS, delay: Math.min(i * 26, 130), easing: "ease-out", fill: "backwards",
      });
      a.onfinish = () => { r.style.overflow = ""; };
    });
  } else {
    const rows = rowsOfSubtree(panel, t);
    // Spin the still-live chevron via its CSS transition; the post-render one is statically folded.
    const flat = flatOf.get(panel) ?? [];
    panel.querySelector(`.cc-dtodo-fold[data-fold="${flat.indexOf(t)}"]`)?.setAttribute("aria-expanded", "false");
    const finish = () => { folding.delete(k); setFolded(t, true); renderPanel(panel, iso); applyNav(); };
    if (!rows.length) { finish(); return; }
    folding.add(k);
    let pending = rows.length;
    rows.forEach((r, i) => {
      r.style.overflow = "hidden";
      const a = r.animate(foldFrames(r).slice().reverse(), {
        duration: FOLD_MS, delay: Math.min((rows.length - 1 - i) * 26, 130), easing: "ease-in", fill: "forwards",
      });
      a.onfinish = () => { if (--pending === 0) finish(); };
    });
  }
}

// ── Rendering ───────────────────────────────────────────────────────────────────────────────────
interface RowFold { foldable: boolean; folded: boolean; hidden: number; }
function rowHTML(t: ParsedTodo, idx: number, viewIso: string, fold?: RowFold): string {
  const date = opDate(t), overdue = date < viewIso;
  // A child row sits under its parent, which already carries the provenance prefix.
  const prefix = t.parentLine == null && t.eventTitle && !(t.source === "daily" && t.dailyDate === viewIso) ? `<span class="cc-dtodo-event">${esc(t.eventTitle)} · </span>` : "";
  const text = t.text ? esc(t.text) : "<em>(untitled)</em>";
  let meta = "";
  if (t.done) {
    meta = `<span class="cc-dtodo-fin">✓ ${t.doneDate ? esc(finishedLabel(viewIso, t.doneDate)) : "done"}</span>`;
  } else {
    if (t.priority) meta += `<span class="cc-dtodo-prio" data-level="${t.priority}">${"!".repeat(t.priority)}</span>`;
    meta += t.followup
      ? `<span class="cc-dtodo-followup${overdue ? " cc-dtodo-due-over" : ""}">↪ follow up ${esc(relDue(viewIso, t.followup))}</span>`
      : `<span class="cc-dtodo-due${overdue ? " cc-dtodo-due-over" : ""}">${esc(relDue(viewIso, date))}</span>`;
    meta += t.projects.slice(0, 2).map((p) => `<span class="cc-dtodo-proj">${esc(p)}</span>`).join("");
    meta += t.tags.slice(0, 3).map((tag) => `<span class="cc-dtodo-tag">#${esc(tag)}</span>`).join("");
  }
  // A folded parent shows how many sub-items it's hiding.
  if (fold?.folded && fold.hidden > 0) meta += `<span class="cc-dtodo-foldn">+${fold.hidden} sub</span>`;
  const chevron = fold?.foldable
    ? `<button class="cc-dtodo-fold" data-fold="${idx}" aria-expanded="${!fold.folded}" title="Fold / unfold sub-items"><svg viewBox="0 0 24 24" width="14" height="14"><path d="M6.75 1.5 L17.25 12 L6.75 22.5" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/></svg></button>`
    : "";
  // data-idx on the row itself: with folding, the visible rows are a SUBSET of the flat list, so
  // keyboard nav resolves a row → todo through this instead of assuming row order == flat order.
  // The fold chevron is the LAST flex item — it rides the right edge of the row.
  return `<li class="cc-dtodo${t.done ? " cc-dtodo-is-done" : ""}" style="--nest:${Math.min(t.indent ?? 0, 6)}" data-idx="${idx}">
    <input type="checkbox" class="cc-dtodo-check" data-idx="${idx}"${t.done ? " checked" : ""}>
    <span class="cc-dtodo-main" data-open="${idx}" role="button" tabindex="0" title="Go to event">
      <span class="cc-dtodo-text${t.done ? " cc-struck" : ""}">${prefix}${text}</span>
      <span class="cc-dtodo-meta">${meta}</span>
    </span>${chevron}</li>`;
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

// ── PROJ tab: per-project gantt charts ─────────────────────────────────────────────────────────
// Membership is PER TODO ITEM: a TOP-LEVEL todo line carrying an inline `@project:<key>` token
// (already parsed by the shared tokenizer into ParsedTodo.projects, stripped from the text)
// charts as a row — from any source: event/deadline/daily/scope notes. Sub-tasks never chart.
// Separately, a DEADLINE whose note contains a bare `@project:<key>` line becomes the project's
// MILESTONE (a vertical rule). Rows: created → done segments, open rows run to now in gray, the
// post-due portion hatched; axis = relative days + month boundaries, extended into the future.
interface ProjTask {
  t: ParsedTodo;
  start: string; // day iso: created:, else the source item's day
  end: string | null; // done day; null = open (extends to now)
  due: string | null;
  color: string; // the source event's color
}
interface Project {
  key: string;
  tasks: ProjTask[];
  deadlines: DL[];
  lastActivity: string; // max(done ?? created ?? due) — panel sort order
}
let projects: Project[] = [];
let projectsDirty = true; // set alongside todosDirty (same data feeds both)

// ── Autocomplete entity index (non-persistent; derived from the live todo index) ────────────────
// Projects / people / tags seen anywhere in the database, for the note editor's @project: /
// @person: / #tag completions. Rebuilt lazily on the same dirty cadence as the todo index.
let entityDirty = true;
let entityIdx = { projects: [] as string[], people: [] as string[], tags: [] as string[] };
function completionIndex() {
  ensureProjects(); // ensures todos too; `projects` adds deadline bare-line keys
  if (entityDirty) {
    const ps = new Set<string>(), pe = new Set<string>(), tg = new Set<string>();
    for (const t of allTodos) {
      for (const k of t.projects) ps.add(k);
      for (const k of t.people) pe.add(k);
      for (const k of t.tags) tg.add(k);
    }
    for (const p of projects) ps.add(p.key);
    entityIdx = { projects: [...ps].sort(), people: [...pe].sort(), tags: [...tg].sort() };
    entityDirty = false;
  }
  return entityIdx;
}
function noteProjectKeys(text: string | null | undefined): string[] {
  if (!text || !text.includes("@project:")) return [];
  const out: string[] = [];
  for (const line of text.split("\n")) {
    const m = line.trim().match(/^@project:(.+)$/);
    if (m) {
      const k = m[1].trim();
      if (k && !out.includes(k)) out.push(k);
    }
  }
  return out;
}
function ensureProjects() {
  ensureTodos();
  if (!projectsDirty) return;
  const map = new Map<string, Project>();
  const get = (k: string): Project => {
    let p = map.get(k);
    if (!p) { p = { key: k, tasks: [], deadlines: [], lastActivity: "" }; map.set(k, p); }
    return p;
  };
  // Rows: every TOP-LEVEL todo tagged @project:<key>, from any note source.
  const evById = new Map(events.map((e) => [e.id, e]));
  for (const t of allTodos) {
    if (t.indent !== 0 || !t.projects.length) continue;
    // created: absent → the source item's own day (event/deadline date; daily note's date;
    // scope notes anchor at their range start).
    let fallback = today, color = "blue";
    if (t.source === "event") {
      const ev = evById.get(t.eventId);
      if (ev) { fallback = ev.start.slice(0, 10); color = ev.color || "blue"; }
    } else if (t.dailyDate) {
      const d = t.dailyDate;
      fallback = d.startsWith("week:") ? d.slice(5)
        : d.startsWith("month:") ? `${d.slice(6)}-01` : d;
    }
    const start = (t.created ?? "").slice(0, 10) || fallback;
    const task: ProjTask = {
      t, start,
      end: t.done ? ((t.doneDate ?? "").slice(0, 10) || start) : null,
      // Only an EXPLICIT `due:` token is a deadline here. A todo without one INHERITS its source
      // item's date as `due` (dueSource "event" — the TODO list's sectioning semantics), which
      // would falsely hatch any task finished after its note's day as "overdue".
      due: t.dueSource === "line" ? dueDate(t) || null : null,
      color,
    };
    for (const k of t.projects) get(k).tasks.push(task);
  }
  // Milestones: a DEADLINE whose note carries a bare `@project:<key>` line (its own todos
  // already chart as rows via the generic path above).
  for (const ev of events) {
    if (ev.kind !== "deadline") continue;
    const keys = noteProjectKeys(ev.notes);
    if (!keys.length) continue;
    const dl = deadlines.find((d) => d.id === ev.id);
    if (dl) for (const k of keys) get(k).deadlines.push(dl);
  }
  for (const p of map.values()) {
    p.lastActivity = p.tasks.reduce((a, x) => {
      const d = x.end ?? x.start;
      return d > a ? d : a;
    }, "");
  }
  projects = [...map.values()].sort((a, b) => (a.lastActivity < b.lastActivity ? 1 : -1));
  projectsDirty = false;
}

// Relevance ranking inside a project: open state, priority, activity recency, near/overdue due.
// Transparent + additive so the weights are tunable in one place. Top 8 rows per project.
const PROJ_MAX_ROWS = 8;
function projScore(x: ProjTask): number {
  let s = 0;
  if (!x.t.done) s += 4;
  s += x.t.priority ?? 0;
  const anchor = x.end ?? x.start;
  if (anchor && today) s += 3 * Math.exp(-Math.abs(daysBetween(anchor, today)) / 30);
  if (x.due && today) {
    const dd = daysBetween(today, x.due);
    if (dd >= -30 && dd <= 14) s += 2;
  }
  return s;
}

/// The PROJ panel for a scope range [rs, re] (day: viewIso..viewIso). A project is shown iff it
/// was ACTIVE during the range: some todo with start ≤ re and (open, or done on/after rs).
/// Returns the html AND the flat todo list in render order — the caller registers it in flatOf,
/// so the rows are FULLY interactive TODO items (checkbox toggling + title-click open) through
/// the exact same delegation paths as the TODO tab, just formatted as a gantt.
function projHTML(rs: string, re: string): { html: string; flat: ParsedTodo[] } {
  if (!today) return { html: "", flat: [] }; // pre-data tick — nothing to chart yet
  ensureProjects();
  const shown = projects.filter((p) =>
    p.tasks.some((x) => x.start <= re && (!x.end || x.end >= rs)));
  const flat: ParsedTodo[] = [];
  if (!shown.length) {
    return { html: `<div class="cc-proj-ph">PROJECTS</div>
      <div class="cc-dd-free">No projects active in this range. Tag a top-level TODO with @project:name (a bare @project:name line in a deadline's note marks it as that project's milestone).</div>`, flat };
  }
  return { html: `<div class="cc-proj-ph">PROJECTS</div>`
    + shown.map((p) => projChartHTML(p, flat)).join(""), flat };
}

const MO_SHORT = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
function projChartHTML(p: Project, flat: ParsedTodo[]): string {
  const tasks = [...p.tasks].sort((a, b) => projScore(b) - projScore(a)).slice(0, PROJ_MAX_ROWS)
    .sort((a, b) => (a.start < b.start ? -1 : 1)); // chart order: chronological
  const hiddenN = p.tasks.length - tasks.length;
  const dlIsos = p.deadlines.map((d) => `${d.year}-${pad(d.month + 1)}-${pad(d.day)}`);
  // Time range: earliest visible start → max(now, latest deadline). "Show the future" — a CFP
  // next month extends the chart past the now-line.
  let lo = today, hi = today;
  for (const x of tasks) {
    if (x.start < lo) lo = x.start;
    const e = x.end ?? today;
    if (e > hi) hi = e;
    if (x.due && x.due > hi) hi = x.due; // an uncrossed due renders as a tick — keep it in range
  }
  for (const iso of dlIsos) {
    if (iso < lo) lo = iso;
    if (iso > hi) hi = iso;
  }
  // Visual breathing room: a day on the left, a few days past the last due/deadline/now.
  lo = addDays(lo, -1);
  hi = addDays(hi, 3);
  const span = Math.max(1, daysBetween(lo, hi));
  const x = (iso: string) => Math.max(0, Math.min(100, (daysBetween(lo, iso) / span) * 100));
  // Bar colors ride the house `.cc-ev-<color>` classes (they define --ev-color; unknown names
  // fall to cc-ev-default). NOT the --event-*-border vars — those are never actually defined.
  const EV_COLORS = new Set(["red", "blue", "green", "yellow", "purple", "orange", "cyan",
                             "darkgreen", "indigo"]);
  const evc = (c: string) => `cc-ev-${EV_COLORS.has(c) ? c : "default"}`;
  const seg = (a: string, b: string, cls: string, color: string) => {
    const l = x(a), w = Math.max(0.8, x(b) - x(a));
    return `<span class="cc-proj-bar ${cls} ${evc(color)}" style="left:${l.toFixed(2)}%;width:${w.toFixed(2)}%"></span>`;
  };
  const rows = tasks.map((t) => {
    // The bar taxonomy (created/due/done):
    //   · created only            → one bar, created → now
    //   · created+due, not crossed→ one bar to now/done; the due renders as a small vertical
    //     TICK at its (possibly future) date — for open rows and finished-early rows alike
    //   · due crossed (end > due) → two segments: created → due solid, due → end hatched
    //     (started-after-due degenerates to one fully-hatched segment)
    const end = t.end ?? today;
    const kind = t.end ? "cc-proj-donebar" : "cc-proj-openbar";
    let bars = "";
    if (t.due && end > t.due) {
      bars = t.start < t.due
        ? seg(t.start, t.due, kind, t.color) + seg(t.due, end, kind + " cc-proj-over", t.color)
        : seg(t.start, end, kind + " cc-proj-over", t.color);
    } else {
      bars = seg(t.start, end, kind, t.color);
      if (t.due && t.due > end) {
        bars += `<span class="cc-proj-due ${evc(t.color)}" style="left:${x(t.due).toFixed(2)}%"></span>`;
      }
    }
    // A REAL todo row, gantt-formatted: the same checkbox as the TODO list (same class → the
    // shared change-delegation toggles the source line, done:-stamp and all) and a clickable
    // title (data-open → open the event drawer / jump to the source note).
    const idx = flat.length;
    flat.push(t.t);
    return `<div class="cc-proj-lrow${t.end ? " cc-proj-lrow-done" : ""}"><input type="checkbox" class="cc-dtodo-check" data-idx="${idx}"${t.end ? " checked" : ""}><span class="cc-proj-ltext" data-open="${idx}" role="button" tabindex="0" title="${esc(t.t.text)}">${esc(t.t.text)}</span></div>|||<div class="cc-proj-track">${bars}</div>`;
  });
  // Deadline rules + the now-line span the row area; deadline titles sit in the top strip.
  const vlines = p.deadlines.map((d, i) => {
    const iso = dlIsos[i], l = x(iso);
    return `<div class="cc-proj-vline" style="left:${l.toFixed(2)}%"></div>
      <div class="cc-proj-vlabel" style="left:${l.toFixed(2)}%" title="${esc(d.title)}">◆ ${esc(d.title)}</div>`;
  }).join("");
  const nowLine = `<div class="cc-proj-vline cc-proj-nowline" style="left:${x(today).toFixed(2)}%"></div>`;
  // Axis 1: relative days from now (past "Nd ago", future "in Nd"), step scaled to the span —
  // short projects tick weekly so a two-week chart isn't a bare "now".
  const step = span <= 42 ? 7 : span <= 100 ? 30 : span <= 240 ? 60 : 90;
  let ticks = "";
  for (let k = Math.ceil(-daysBetween(lo, today) / step) * step; ; k += step) {
    const iso = addDays(today, k);
    if (iso > hi) break;
    if (iso < lo) continue;
    const label = k === 0 ? "now" : k < 0 ? `${-k}d ago` : `in ${k}d`;
    ticks += `<span class="cc-proj-tick" style="left:${x(iso).toFixed(2)}%">${label}</span>`;
  }
  // Axis 2: calendar boundaries — months, or WEEK boundaries (Sundays, "Jul 6") when the span
  // is short enough that a month row would be sparse or empty.
  let months = "";
  if (span <= 60) {
    const [y0, m0, d0] = lo.split("-").map(Number);
    const dow = new Date(Date.UTC(y0, m0 - 1, d0)).getUTCDay();
    for (let iso = addDays(lo, (7 - dow) % 7); iso <= hi; iso = addDays(iso, 7)) {
      const [, mm, dd] = iso.split("-").map(Number);
      months += `<span class="cc-proj-tick" style="left:${x(iso).toFixed(2)}%">${MO_SHORT[mm - 1]} ${dd}</span>`;
    }
  } else {
    let [y, m] = lo.split("-").map(Number);
    m += 1; if (m > 12) { m = 1; y += 1; }
    for (;;) {
      const iso = `${y}-${pad(m)}-01`;
      if (iso > hi) break;
      months += `<span class="cc-proj-tick" style="left:${x(iso).toFixed(2)}%">${MO_SHORT[m - 1]}${m === 1 ? ` ’${String(y % 100).padStart(2, "0")}` : ""}</span>`;
      m += 1; if (m > 12) { m = 1; y += 1; }
    }
  }
  return `
    <section class="cc-dd-sec cc-proj">
      <div class="cc-dd-sec-head"><span class="cc-dd-sec-title">${esc(p.key)}</span><span class="cc-dd-sec-count">${p.tasks.length}</span>${hiddenN > 0 ? `<span class="cc-proj-more">+${hiddenN} more</span>` : ""}</div>
      <div class="cc-proj-chart${p.deadlines.length ? " cc-proj-hasdls" : ""}">
        <div class="cc-proj-labels">${rows.map((r) => r.split("|||")[0]).join("")}</div>
        <div class="cc-proj-plot">
          <div class="cc-proj-plotarea">
            ${vlines}${nowLine}
            ${rows.map((r) => r.split("|||")[1]).join("")}
          </div>
          <div class="cc-proj-axis">${ticks}</div>
          <div class="cc-proj-axis cc-proj-months">${months}</div>
        </div>
      </div>
    </section>`;
}

// Render one day's content into a panel's inner scroller. TODO → the grouped list; NOTE → a static
// markdown preview of that day's note (so the note carousels per-day like the list).
function renderPanel(el: HTMLElement, viewIso: string) {
  const scroll = scrollOf.get(el) ?? el;
  isoOf.set(el, viewIso);
  if (tab === "proj") {
    const r = projHTML(viewIso.slice(0, 10), viewIso.slice(0, 10));
    scroll.innerHTML = r.html;
    scroll.scrollTop = scrollByIso[viewIso] ?? 0;
    flatOf.set(el, r.flat); // gantt rows ARE todo rows — checkbox/open delegation resolves here
    return;
  }
  if (tab === "note") {
    // Content-based: a note with content shows its rendered preview; an empty day shows the editor
    // placeholder — the SAME representation the settled panel uses, so scrolling never flips modes.
    const text = notes[viewIso] || "";
    scroll.innerHTML = text.trim()
      ? `<div class="cc-dw-md cc-dd-note-md">${renderMarkdown(text)}</div>`
      : emptyNoteHTML("day");
    scroll.scrollTop = scrollByIso[viewIso] ?? 0;   // restore THIS day's own scroll (see the todo branch)
    flatOf.delete(el);
    return;
  }
  ensureTodos();                                       // lazy: rebuild only if data changed since last view
  const sections = sectionsForDay(allTodos, viewIso);  // sections hold ROOT todos only
  const kids = childrenIndex(allTodos);
  // Flatten each root's full subtree in render order. `flat` always holds EVERY todo — including
  // ones hidden inside a folded parent — so data-idx values are stable regardless of fold state;
  // only the emitted rows change. Checkbox toggles and keyboard nav resolve rows via data-idx.
  const flat: ParsedTodo[] = [];
  const renderTree = (t: ParsedTodo, visible: boolean, out: string[]) => {
    flat.push(t);
    const idx = flat.length - 1;
    const children = kids.get(`${scopeKey(t)}\0${t.line}`) ?? [];
    const folded = children.length > 0 && collapsed.has(foldKey(t));
    if (visible) {
      const fold: RowFold = { foldable: children.length > 0, folded, hidden: folded ? subtree(t, kids).length - 1 : 0 };
      out.push(rowHTML(t, idx, viewIso, fold));
    }
    for (const c of children) renderTree(c, visible && !folded, out);
  };
  const secHTML = sections.map((s) => {
    const out: string[] = [];
    for (const t of s.items) renderTree(t, true, out);
    return `<section class="cc-dtodo-sec"><div class="cc-dtodo-sec-head"><span class="cc-dtodo-sec-title">${esc(s.title)}</span><span class="cc-dtodo-sec-count">${s.items.length}</span></div><ul class="cc-dtodo-list">${out.join("")}</ul></section>`;
  }).join("");
  flatOf.set(el, flat);
  const body = sections.length ? secHTML : emptyListHTML(todoPrefs.day);
  scroll.innerHTML = (todoPrefs.day.deadlines ? deadlineHTML(viewIso) : "") + body;
  // The two panels are RECYCLED across days and `daily.dom` advances mid-swipe (setDayProgress), so a
  // panel is re-rendered for a new day WHILE it's on screen. Restore THIS day's own remembered scroll
  // (0 for a day we haven't scrolled) — keyed by iso, so it never inherits the other panel's offset and
  // re-rendering the day you're on lands exactly where you already are (no teleport).
  scroll.scrollTop = scrollByIso[viewIso] ?? 0;
}

// ── Weekly / monthly panel content ──────────────────────────────────────────────────────────────
// Same template as the daily panel, scoped to a date range: "Deadlines in this week/month" (all
// deadlines inside the range), "TODOs this week/month" (open todos whose operative date falls in
// the range), "Completed this week/month", and — on the NOTE tab — the scope's own persisted note.
function rangeDeadlineHTML(title: string, startIso: string, endIso: string): string {
  const list = deadlines
    .map((d) => ({ d, iso: `${d.year}-${pad(d.month + 1)}-${pad(d.day)}` }))
    .filter((x) => x.iso >= startIso && x.iso <= endIso)
    .sort((a, b) => (a.iso < b.iso ? -1 : a.iso > b.iso ? 1 : a.d.hour - b.d.hour) || (a.d.id < b.d.id ? -1 : a.d.id > b.d.id ? 1 : 0));
  const head = `<div class="cc-dd-sec-head"><span class="cc-dd-sec-title">${esc(title)}</span>${list.length ? `<span class="cc-dd-sec-count">${list.length}</span>` : ""}</div>`;
  const body = list.length
    ? `<ul class="cc-dd-ddl-list">${list.map(({ d, iso }) =>
        `<li class="cc-dd-ddl cc-ev-${esc(d.color)}" data-ddl="${esc(d.id)}" role="button" tabindex="0" title="Go to deadline">
          <span class="cc-dd-ddl-dot"></span>
          <span class="cc-dd-ddl-title">${d.title ? esc(d.title) : "<em>(untitled)</em>"}</span>
          <span class="cc-dd-ddl-when">${esc(relDue(today, iso))} · ${hhmm(d.hour)}</span></li>`).join("")}</ul>`
    : `<div class="cc-dd-free">No deadlines in this range.</div>`;
  return `<section class="cc-dd-sec">${head}${body}</section>`;
}
function rangeTodoSections(startIso: string, endIso: string, word: string, scope: "week" | "month"): Section[] {
  ensureTodos();
  const p = todoPrefs[scope];
  const pool = allTodos.filter((t) => p.sources.includes(todoLayer(t)));   // layering: enabled sources only
  const inR = (d: string) => d >= startIso && d <= endIso;
  const byOp = (a: ParsedTodo, b: ParsedTodo) => {
    const d = opDate(a) < opDate(b) ? -1 : opDate(a) > opDate(b) ? 1 : (b.priority ?? 0) - (a.priority ?? 0);
    return d !== 0 ? d : cmpTie(a, b);
  };
  // NESTING: a qualifying SUB-item never shows alone — it PROMOTES its root, and the section
  // lists ROOTS only (renderScopePanel renders each root's full subtree, same "sublists in
  // full" rule as the daily view). Roots order by their earliest-due qualifying member.
  const byLine = new Map(pool.map((t) => [`${scopeKey(t)}\0${t.line}`, t] as const));
  const rootOf = (t: ParsedTodo): ParsedTodo => {
    let cur = t;
    while (cur.parentLine != null) {
      const up = byLine.get(`${scopeKey(cur)}\0${cur.parentLine}`);
      if (!up) break;
      cur = up;
    }
    return cur;
  };
  const openBest = new Map<ParsedTodo, ParsedTodo>(); // root → earliest qualifying member
  for (const h of pool.filter((t) => !t.done && inR(opDate(t))).sort(byOp)) {
    const r = rootOf(h);
    if (!openBest.has(r)) openBest.set(r, h);
  }
  const open = [...openBest.keys()]; // insertion order == byOp order of each root's best member
  const openSet = new Set(open);
  // Completed: done ROOTS finished in range — skipping any root already shown under TODOs
  // (a done parent with an open in-range child shows there, struck, with its subtree).
  const completed = pool
    .filter((t) => t.done && t.parentLine == null && t.doneDate && inR(t.doneDate.slice(0, 10)) && !openSet.has(t))
    .sort((a, b) => { const d = a.doneDate! < b.doneDate! ? 1 : a.doneDate! > b.doneDate! ? -1 : 0; return d !== 0 ? d : cmpTie(a, b); });
  return [
    { key: "open", title: `TODOs ${word}`, items: open },
    { key: "done", title: `Completed ${word}`, items: completed, done: true },
  ].filter((s) => s.items.length > 0 && p.sections.includes(s.key));
}
// Render one scope sub-panel for its machine key (week: the Sunday iso; month: "YYYY-MM").
// Signature-cached; callers bust via scopeSig.clear() on data / tab changes.
function renderScopePanel(el: HTMLElement, scope: "week" | "month", key: string) {
  const sig = `${scope}|${key}|${tab}`;
  if (scopeSig.get(el) === sig) return;
  scopeSig.set(el, sig);
  let scroll = el.firstElementChild as HTMLElement | null;
  if (!scroll || !scroll.classList.contains("cc-dd-scroll")) {
    el.innerHTML = `<div class="cc-dd-scroll"></div>`;
    scroll = el.firstElementChild as HTMLElement;
  }
  const noteKey = scope === "week" ? weekNoteKey(key) : monthNoteKey(key);
  const start = scope === "week" ? key : `${key}-01`;
  const end = scope === "week" ? addDays(key, 6) : monthEndIso(key);
  if (tab === "proj") {
    const r = projHTML(start, end);
    scroll.innerHTML = r.html;
    flatOf.set(el, r.flat); // gantt rows ARE todo rows — checkbox/open delegation resolves here
    return;
  }
  if (tab === "note") {
    const text = notes[noteKey] || "";
    scroll.innerHTML = text.trim()
      ? `<div class="cc-dw-md cc-dd-note-md">${renderMarkdown(text)}</div>`
      : emptyNoteHTML(scope);
    flatOf.delete(el);
    return;
  }
  const word = scope === "week" ? "this week" : "this month";
  // The scope note's OWN todos drop their "Weekly/Monthly note · …" prefix inside their own
  // panel (shallow clones — the soft-link fields still point at the right note line).
  const sections = rangeTodoSections(start, end, word, scope).map((s) => ({
    ...s, items: s.items.map((t) => t.dailyDate === noteKey ? { ...t, eventTitle: "" } : t),
  }));
  // Sections hold ROOTS; render each root's full subtree. `flat` must match data-idx exactly
  // (checkbox toggles resolve rows through it), so hidden==none here: every subtree row lists.
  const kids = childrenIndex(allTodos);
  const flat: ParsedTodo[] = [];
  const secHTML = sections.map((s) => {
    const rows = s.items.map((t) => subtree(t, kids).map((n) => { flat.push(n); return rowHTML(n, flat.length - 1, today); }).join("")).join("");
    return `<section class="cc-dtodo-sec"><div class="cc-dtodo-sec-head"><span class="cc-dtodo-sec-title">${esc(s.title)}</span><span class="cc-dtodo-sec-count">${s.items.length}</span></div><ul class="cc-dtodo-list">${rows}</ul></section>`;
  }).join("");
  flatOf.set(el, flat);
  const pr = todoPrefs[scope];
  scroll.innerHTML =
    (pr.deadlines
      ? rangeDeadlineHTML(scope === "week" ? "Deadlines in this week" : "Deadlines in this month", start, end)
      : "") +
    (sections.length ? secHTML : emptyListHTML(pr));
}

let liveShown = false, liveMode = "";
// Apply the current tick: the zoom reveal (whole-panel slide-in-from-right + fade) on #dash, then
// position + fade the two day panels within it like SceneRenderer.drawPanel; then place the live note
// editor over the centered panel at rest.
let dayViewShown = false;   // true once the dashboard is revealed (day view); reset when hidden
// A panel render must NEVER kill the tick pipeline: an uncaught throw mid-apply() left the
// function half-run — panels stale AND the live note editor permanently unmounted (the visible
// symptom: the native toggle says Editor, only the static preview shows, Enter/⌘-click do
// nothing, and — since identical ticks are deduped Swift-side — nothing ever retries). Contain
// each render and report it to Swift (Coordinator logs to the Xcode console) so the underlying
// bug is visible instead of wedging the dashboard.
function guarded(what: string, fn: () => void) {
  try { fn(); } catch (e) {
    post({ type: "err", where: what, message: String((e as Error)?.stack ?? e) });
  }
}
function apply() {
  const { from, to, dir, p, reveal, slide, scopeA, scopeB, scopeT, dy, mFrom, mTo, mDy0, mDy1, mP,
          mKeyA, mKeyB, wFrom, wTo, wP, wKeyA, wKeyB,
          maskX, maskW, aName, aX, aW, aOp, bName, bX, bW, bOp, shift } = last;
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
  // `shift` = the drawer canvas-shift (engine.drawerShift). The scene slides left by the same
  // amount (.offset(-drawerShift)), so carrying it here keeps the pinned week/month panel moving
  // WITH the canvas while the drawer opens. 0 at day level (the dashboard owns the right there).
  root.style.transform = `translate(${(-shift).toFixed(1)}px, ${dy.toFixed(1)}px)`;
  root.style.pointerEvents = reveal > 0.999 ? "auto" : "none";
  // ── Zoom-scope carousel: each panel is placed at its OWN target width and absolute position
  // (dashScopePanels' numbers, frame-local → mask-local by subtracting maskX) — exactly the
  // geometry the Canvas header draws with, so the two align by construction and stay continuous
  // in z (nothing keys on the rounded level; no z=1.5 snap).
  const layers: Record<string, HTMLElement> = { day: panelsEl, week: weekLayer, month: monthLayer };
  const t = scopeT;
  const scopeName = t > 0.5 ? scopeB : scopeA;
  let liveL = 0, liveW = 0; // the active scope panel's own geometry → sizes the live editor
  for (const [name, el] of Object.entries(layers)) {
    let x = 0, w = 0, op = 0;
    if (name === aName) { x = aX; w = aW; op = aOp; }
    else if (name === bName) { x = bX; w = bW; op = bOp; }
    el.style.left = `${(x - maskX).toFixed(1)}px`;
    el.style.width = `${Math.max(0, w).toFixed(1)}px`;
    el.style.transform = "none";
    el.style.opacity = op.toFixed(3);
    el.style.pointerEvents = op > 0.999 ? "auto" : "none";
    if (name === scopeName) { liveL = x - maskX; liveW = Math.max(0, w); }
  }
  // The live editor rides the ACTIVE panel's own (stable) width, NOT the mask: resizing with the
  // mask reflowed CodeMirror against transient — even zero — widths while hidden, and it came
  // back laid out without its left gutter. The panel's target width only changes on a real
  // split-handle drag, so the editor's layout is steady across every open/close/zoom.
  if (liveW > 1) {
    noteLive.style.left = `${liveL.toFixed(1)}px`;
    noteLive.style.width = `${liveW.toFixed(1)}px`;
  }
  // Month page-turn: the sub-panels ride their bands' frames in PIXELS (mDy0/mDy1 are the
  // band-frame deltas Swift computes — same staggered easing, same asymmetric travel as the
  // Canvas header) and fade by TURN PROGRESS (the day-carousel house rule).
  // Identity first: if the "from" month currently lives in panel B (the pager re-based and
  // from/to swapped), swap the ROLES so each panel keeps its month — continuous positions.
  if (mKeyA && scopeKeyOf.get(mpB) === mKeyA) {
    const t2 = mpA; mpA = mpB; mpB = t2;
  }
  if (mKeyA) {
    guarded(`month:${mKeyA}`, () => renderScopePanel(mpA, "month", mKeyA)); scopeKeyOf.set(mpA, mKeyA);
    mpA.style.transform = `translateY(${mDy0.toFixed(1)}px)`;
    mpA.style.opacity = (1 - mP).toFixed(3);
    // Interactive only at rest — a faded sub-panel sits ON TOP of its sibling in DOM order and
    // would otherwise eat every click (checkboxes, deadline rows) meant for the resting panel.
    mpA.style.pointerEvents = mP < 0.001 ? "auto" : "none";
  }
  if (mKeyA && mKeyB && mP > 0.001) {
    guarded(`month:${mKeyB}`, () => renderScopePanel(mpB, "month", mKeyB)); scopeKeyOf.set(mpB, mKeyB);
    mpB.style.transform = `translateY(${mDy1.toFixed(1)}px)`;
    mpB.style.opacity = mP.toFixed(3);
    mpB.style.pointerEvents = "none";
  } else {
    mpB.style.opacity = "0";
    mpB.style.pointerEvents = "none";
  }
  // Week turn: the sub-panels carousel HORIZONTALLY, driven by the continuous week scroll
  // (wP ramps while the viewport's left border sweeps the turn band; rests at BOTH 0 and 1).
  // Same identity-keying + fade-by-progress rules as the month pair above.
  if (wKeyA && scopeKeyOf.get(wpB) === wKeyA) {
    const t3 = wpA; wpA = wpB; wpB = t3;
  }
  if (wKeyA) {
    guarded(`week:${wKeyA}`, () => renderScopePanel(wpA, "week", wKeyA)); scopeKeyOf.set(wpA, wKeyA);
    wpA.style.transform = `translateX(${(-wP * 100).toFixed(3)}%)`;
    wpA.style.opacity = (1 - wP).toFixed(3);
    // Same at-rest gate as the month pair; the week turn rests at BOTH ends (wP 0 or 1).
    wpA.style.pointerEvents = wP < 0.001 ? "auto" : "none";
  }
  if (wKeyA && wKeyB && wP > 0.001) {
    guarded(`week:${wKeyB}`, () => renderScopePanel(wpB, "week", wKeyB)); scopeKeyOf.set(wpB, wKeyB);
    wpB.style.transform = `translateX(${((1 - wP) * 100).toFixed(3)}%)`;
    wpB.style.opacity = wP.toFixed(3);
    wpB.style.pointerEvents = wP > 0.999 ? "auto" : "none";
  } else {
    wpB.style.opacity = "0";
    wpB.style.pointerEvents = "none";
  }
  if (isoOf.get(p0) !== from) guarded(`day:${from}`, () => renderPanel(p0, from));
  const atRest = !to || p <= 0.0001;
  if (atRest) {                                   // single centered panel
    p0.style.transform = "translateX(0)"; p0.style.opacity = "1"; p0.style.pointerEvents = "auto";
    p1.style.opacity = "0"; p1.style.pointerEvents = "none";
  } else {
    if (isoOf.get(p1) !== to) guarded(`day:${to}`, () => renderPanel(p1, to));
    // current slides out by -dir·p, fades to 1−p; incoming enters from dir·(1−p), fades to p.
    p0.style.transform = `translateX(${(-dir * p * 100).toFixed(3)}%)`; p0.style.opacity = (1 - p).toFixed(3);
    p1.style.transform = `translateX(${(dir * (1 - p) * 100).toFixed(3)}%)`; p1.style.opacity = p.toFixed(3);
    p0.style.pointerEvents = "none"; p1.style.pointerEvents = "none";
  }
  // Live editor: NOTE tab, fully open, at rest → overlay the resting panel (which is hidden so its
  // static preview doesn't peek through). During a swipe/zoom the panels' note previews carousel.
  // Scope-aware: the day scope edits the day's note, week/month edit THEIR scope note (same
  // persisted store, prefixed keys) — the editor re-anchors via liveIso whenever the key changes.
  let liveKey = "", hideEl: HTMLElement | null = null;
  if (scopeName === "day") {
    liveKey = from; hideEl = p0;
  } else if (scopeName === "week" && (wP <= 0.001 || wP >= 0.999)) {
    const k = wP < 0.5 ? wKeyA : wKeyB;
    if (k) { liveKey = weekNoteKey(k); hideEl = wP < 0.5 ? wpA : wpB; }
  } else if (scopeName === "month" && mP <= 0.001 && mKeyA) {
    liveKey = monthNoteKey(mKeyA); hideEl = mpA;
  }
  // Scope-rest is TOLERANT (t within epsilon of an integer), like every other rest gate here —
  // `t % 1 === 0` wedged the live editor when an interrupted zoom left z a hair off its level.
  const scopeAtRest = t < 0.001 || t > 0.999;
  const showLive = tab === "note" && atRest && reveal > 0.999 && scopeAtRest && !!liveKey;
  noteLive.style.display = showLive ? "" : "none";
  for (const el of [p0, wpA, wpB, mpA, mpB]) el.style.visibility = "";
  if (showLive && hideEl) hideEl.style.visibility = "hidden";
  if (showLive) {
    const text = notes[liveKey] || "";
    if (liveIso !== liveKey) {
      liveIso = liveKey;
      liveScope = scopeName as "day" | "week" | "month";
      // The empty-note hint names the scope we're editing (matches the static previews).
      noteEd.setPlaceholder(scopeName === "day" ? "Daily Note (Markdown)…"
        : scopeName === "week" ? "Weekly Note (Markdown)…" : "Monthly Note (Markdown)…");
      // Content-based default for the note we landed on; tell Swift so the native toggle reflects it.
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
  if (ok) { todosDirty = true; projectsDirty = true; entityDirty = true; selfEditAt = performance.now(); }   // suppress the setData echo's re-sort
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
  const panel = panelOf(e);
  // Disclosure chevron → animated fold/unfold of that row's subtree (see toggleFold).
  const foldEl = (e.target as HTMLElement).closest("[data-fold]") as HTMLElement | null;
  if (foldEl && panel) {
    const t = (flatOf.get(panel) ?? [])[Number(foldEl.dataset.fold)];
    if (t) toggleFold(panel, t, collapsed.has(foldKey(t)));
    return;
  }
  const openEl = (e.target as HTMLElement).closest("[data-open]") as HTMLElement | null;
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
  // "Write something" in an empty-note preview (live overlay or static panel) → the editor.
  if ((e.target as HTMLElement).closest(".cc-dd-note-write")) {
    e.preventDefault();
    noteModeUser("edit");
    queueMicrotask(() => { noteEd.setMode("edit"); noteEd.focus(); });
    return;
  }
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
    todosDirty = true; projectsDirty = true; entityDirty = true; // re-aggregate todos + the project index on next render
    if (!last.from) last.from = d.viewIso || today;
    // If this data push is just the echo of a checkbox WE just toggled, update the data but leave the
    // panels in place — the checked row stays put (mid-animation) and only migrates to "Recently
    // Completed" on a real re-render (day swipe / zoom out+in). External changes still re-render.
    if (performance.now() - selfEditAt < SELF_ECHO_MS) return;
    isoOf.delete(p0); isoOf.delete(p1);   // force a re-render with the new data
    scopeSig.clear();                     // scope panels too (identity keys stay — no position jump)
    apply();
  },
  tick(t: Partial<typeof TICK_DEFAULTS>) {
    last = { ...TICK_DEFAULTS, ...t, to: t.to || "" };
    apply();
  },
  // Swift drives the tab. Idempotent: the un-adopted echo push (see the coordinator's noteMode/tab
  // handling) re-sends the current value — a full re-render for a no-op change would be wasteful.
  // A no-change push still re-runs apply() (cheap — every render is cache-guarded): the native
  // toggles double as a manual repair path if the tick pipeline ever wedges with stale state.
  setTab(t: "todo" | "note" | "proj") { if (t !== tab) applyTab(t); else apply(); },
  setNoteMode(m: "edit" | "preview") {                       // native edit/preview toggle (no echo back)
    noteMode = m; liveMode = ""; apply();
  },
  setInactive(on: boolean) { scrim.classList.toggle("on", on); },   // drawer open → blur + block the dashboard
  setTheme(vars: Record<string, string>) { const s = document.documentElement.style; for (const k in vars) s.setProperty(k, vars[k]); },
  // Per-scope layering (sources / collections / deadlines) from the native cog + context menu.
  // Merged over the in-page defaults, then a full re-render (todo lists AND scope panels).
  setTodoPrefs(json: string) {
    try { todoPrefs = { ...todoPrefs, ...JSON.parse(json) }; } catch { return; }
    isoOf.delete(p0); isoOf.delete(p1);
    scopeSig.clear();
    apply();
  },
  // ── Keyboard nav bridge (driven by the calendar's key system) ──
  navSet(stop: "todo" | "note" | "none") {   // Tab focus in/out of the dashboard stops
    navStop = stop === "none" ? null : stop;
    editingNote = false;
    editingRing = false;
    if (navStop === "todo") todoCursor = 0;   // land on the first row
    applyNav();
  },
  navMove(delta: number) { if (navStop === "todo") { todoCursor += delta; applyTodoCursor(); } },   // ↑/↓ rows
  navActivate() {                              // Space on the TODO stop → toggle the focused row (in place)
    if (navStop !== "todo") return;
    const row = todoRows()[todoCursor];
    if (row) toggle(p0, Number(row.dataset.idx ?? -1));   // rows are a subset of flat when folded
  },
  navOpen() {                                  // Enter on the TODO stop → open the focused row
    if (navStop !== "todo") return;
    const row = todoRows()[todoCursor];
    const t = row ? (flatOf.get(p0) ?? [])[Number(row.dataset.idx ?? -1)] : undefined;
    if (!t) return;
    if (t.source === "daily") post({ type: "jumpDay", date: t.dailyDate });
    else post({ type: "open", eventId: t.eventId, occKey: t.occurrenceKey });
  },
  navFold(open: boolean) {                     // ←/→ on the TODO stop → fold/unfold the focused row's subtree
    if (navStop !== "todo") return;
    const row = todoRows()[todoCursor];
    if (!row || !row.querySelector("[data-fold]")) return;   // a leaf row has nothing to fold
    const t = (flatOf.get(p0) ?? [])[Number(row.dataset.idx ?? -1)];
    if (!t || collapsed.has(foldKey(t)) === !open) return;   // already there (held key auto-repeats)
    toggleFold(p0, t, open);   // same animated path as the chevron click
  },
  noteEdit(ring = false) {                     // Enter on the NOTE stop / ⌘E → focus the live editor
    editingNote = true; editingRing = ring; applyNav();
    noteModeUser("edit");
    // The live overlay may not be visible YET: ⌘E can arrive before the tab switch
    // (CK.setTab) and the next tick reveal it — retry across a few frames until apply()
    // has shown it, so the caret reliably lands (a hidden CodeMirror ignores focus()).
    const tryFocus = (left: number) => {
      if (noteLive.style.display !== "none") {
        noteEd.setMode("edit"); noteEd.focus();
      } else if (left > 0) {
        requestAnimationFrame(() => tryFocus(left - 1));
      } else {
        // Gave up — the live overlay never mounted (the "toggle says Editor but only the
        // preview shows" wedge). Dump every input of the showLive gate to the Swift log so
        // the failing condition is identifiable from the Xcode console.
        post({ type: "err", where: "noteEdit-stuck", message: JSON.stringify({
          tab, noteMode, liveMode, liveShown, liveIso,
          display: noteLive.style.display, last,
        }) });
      }
    };
    queueMicrotask(() => tryFocus(30));
  },
};
post({ type: "ready" });
