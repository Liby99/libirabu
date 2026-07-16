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
let last = { from: "", to: "", dir: 0, p: 0, reveal: 0, slide: 1 };

const root = document.getElementById("dash")!;                 // reveal wrapper (zoom slide + fade)
const panelsEl = document.getElementById("panels")!;           // carousel content (todo OR note preview)
const noteLive = document.getElementById("note-live")!;        // live editor overlay (rest + note only)
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

// ── NOTE: per-day notes ──────────────────────────────────────────────────────────────────────────
// Each day owns a note. The carousel panels render a STATIC preview of the day's note (so paging
// slides the old note out + the new one in, like the TODO list). The live CodeMirror editor overlays
// the centered panel only at rest, for editing. Notes for all days come from Swift via setData.
let tab: "todo" | "note" = "todo";
let noteMode: "edit" | "preview" = "edit";
let notes: Record<string, string> = {};
let liveIso = "";                                      // the day the live editor currently holds
const noteEd = createNoteEditor({
  editorEl: document.getElementById("note-editor")!,
  previewEl: document.getElementById("note-preview")!,
  placeholder: "Daily Note",
  onChange: (value) => { notes[liveIso] = value; todosDirty = true; post({ type: "noteChange", date: liveIso, value }); },
  onPreview: () => noteModeUser("preview"),                 // ⌘S in the editor
  onOpenLink: (url) => post({ type: "openLink", url }),
  onEditAt: (line) => { noteModeUser("edit"); noteEd.setCursorLine(line); },   // ⌘-click a preview block
});
function applyTab(t: "todo" | "note") { tab = t; isoOf.delete(p0); isoOf.delete(p1); apply(); }
// A user action IN the webview (⌘S / ⌘-click) → change mode + tell Swift so the native toggle updates.
function noteModeUser(m: "edit" | "preview") {
  if (noteMode === m) return;
  noteMode = m; liveMode = ""; post({ type: "noteMode", mode: m }); apply();
}

const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

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
function sectionsForDay(todos: ParsedTodo[], viewIso: string): Section[] {
  const isToday = viewIso === today;
  const shown = todos.filter((t) => !t.done && (!t.start || t.start <= viewIso));
  const soonEnd = addDays(viewIso, SOON_DAYS), followEnd = addDays(viewIso, FOLLOWUP_WINDOW);
  const byOp = (a: ParsedTodo, b: ParsedTodo) => opDate(a) < opDate(b) ? -1 : opDate(a) > opDate(b) ? 1 : (b.priority ?? 0) - (a.priority ?? 0);
  const overdue = shown.filter((t) => opDate(t) < viewIso).sort(byOp);
  const followups = shown.filter((t) => t.followup && t.followup >= viewIso && t.followup <= followEnd).sort(byOp);
  const plain = shown.filter((t) => !t.followup);
  const dueThisDay = plain.filter((t) => dueDate(t) === viewIso).sort(byOp);
  const highSoon = plain.filter((t) => (t.priority ?? 0) >= HIGH_PRIORITY && dueDate(t) > viewIso && dueDate(t) <= soonEnd).sort(byOp);
  const recentStart = addDays(viewIso, -RECENT_DONE_DAYS);
  const completed = todos
    .filter((t) => t.done && t.doneDate && t.doneDate.slice(0, 10) >= recentStart && t.doneDate.slice(0, 10) <= viewIso)
    .sort((a, b) => (a.doneDate! < b.doneDate! ? 1 : a.doneDate! > b.doneDate! ? -1 : 0)).slice(0, 12);
  return [
    { title: isToday ? "Today’s Items" : "Due This Day", items: dueThisDay },
    { title: "Overdue", items: overdue },
    { title: "Remember to Followup", items: followups },
    { title: "High Priority · Due Soon", items: highSoon },
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
      <span class="cc-dtodo-text">${prefix}${text}</span>
      <span class="cc-dtodo-meta">${meta}</span>
    </span></li>`;
}

function deadlineHTML(viewIso: string): string {
  const upcoming = deadlines
    .map((d) => ({ d, iso: `${d.year}-${pad(d.month + 1)}-${pad(d.day)}` }))
    .filter((x) => x.iso >= viewIso)
    .sort((a, b) => (a.iso < b.iso ? -1 : a.iso > b.iso ? 1 : a.d.hour - b.d.hour))
    .slice(0, 10);
  const head = `<div class="cc-dd-sec-head"><span class="cc-dd-sec-title">Upcoming Deadlines</span>${upcoming.length ? `<span class="cc-dd-sec-count">${upcoming.length}</span>` : ""}</div>`;
  if (!upcoming.length) return `<section class="cc-dd-sec">${head}<div class="cc-dd-free">No immediate deadline! You are free!</div></section>`;
  const rows = upcoming.map(({ d, iso }) =>
    `<li class="cc-dd-ddl cc-ev-${esc(d.color)}" data-ddl="${esc(d.id)}" role="button" tabindex="0" title="Go to deadline">
      <span class="cc-dd-ddl-dot"></span>
      <span class="cc-dd-ddl-title">${d.title ? esc(d.title) : "<em>(untitled)</em>"}</span>
      <span class="cc-dd-ddl-when">${esc(relDue(viewIso, iso))} · ${hhmm(d.hour)}</span></li>`).join("");
  return `<section class="cc-dd-sec">${head}<ul class="cc-dd-ddl-list">${rows}</ul></section>`;
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
}

let liveShown = false, liveMode = "";
// Apply the current tick: the zoom reveal (whole-panel slide-in-from-right + fade) on #dash, then
// position + fade the two day panels within it like SceneRenderer.drawPanel; then place the live note
// editor over the centered panel at rest.
function apply() {
  const { from, to, dir, p, reveal, slide } = last;
  // Zoom reveal: `slide` positions the left edge to match the Canvas dashboardLeftAnimated exactly;
  // `reveal` fades it in. (The panel stays put when the drawer opens — the scrim dims it in place.)
  root.style.transform = `translateX(${(slide * 100).toFixed(3)}%)`;
  root.style.opacity = reveal.toFixed(3);
  root.style.pointerEvents = reveal > 0.999 ? "auto" : "none";
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
  const showLive = tab === "note" && atRest && reveal > 0.999;
  noteLive.style.display = showLive ? "" : "none";
  p0.style.visibility = showLive ? "hidden" : "";
  if (showLive) {
    if (liveIso !== from) {
      liveIso = from;
      const text = notes[from] || "";
      noteEd.setValue(text);
      // Content-based default for the day we landed on; tell Swift so the native toggle reflects it.
      const m = text.trim() ? "preview" : "edit";
      if (m !== noteMode) { noteMode = m; liveMode = ""; post({ type: "noteMode", mode: m }); }
    }
    if (!liveShown || liveMode !== noteMode) { liveMode = noteMode; noteEd.setMode(noteMode); }
  }
  liveShown = showLive;
}

// ── Toggle a checkbox → rewrite the source note line via its soft-link, post the new note ────────
// Mirrors the web's `toggleTodoLine`: the (source, line) anchor locates one line; the markdown stays
// the source of truth. Works for event notes (series / per-occurrence) AND daily notes.
function toggle(el: HTMLElement, t: ParsedTodo) {
  if (t.source === "daily") {
    const date = t.dailyDate ?? "";
    const next = toggleTodoLine(notes[date] ?? "", t.line, undefined, today);
    if (next == null || next === notes[date]) return;
    notes[date] = next;
    post({ type: "noteChange", date, value: next });   // Swift → setDailyNote(date, next)
  } else {
    const ev = events.find((e) => e.id === t.eventId);
    if (!ev) return;
    const isOcc = !!t.occurrenceKey;
    const src = isOcc ? (ev.occurrenceNotes?.[t.occurrenceKey!] ?? "") : (ev.notes ?? "");
    const next = toggleTodoLine(src, t.line, undefined, today);
    if (next == null || next === src) return;
    if (isOcc) ev.occurrenceNotes = { ...(ev.occurrenceNotes ?? {}), [t.occurrenceKey!]: next };
    else ev.notes = next;
    post({ type: "toggle", eventId: t.eventId, occKey: isOcc ? t.occurrenceKey : null, value: next });
  }
  todosDirty = true;                                    // reflect the new done state in the list
  renderPanel(el, isoOf.get(el) ?? last.from);          // refresh just this panel in place (rebuilds lazily)
}

// Event delegation — resolve which panel the target belongs to, then its cached flat list.
function panelOf(e: Event): HTMLElement | null { return (e.target as HTMLElement).closest(".cc-dd-panel"); }
root.addEventListener("change", (e) => {
  const el = e.target as HTMLInputElement;
  if (!el.classList.contains("cc-dtodo-check")) return;
  const panel = panelOf(e); if (!panel) return;
  const t = flatOf.get(panel)?.[Number(el.dataset.idx)]; if (t) toggle(panel, t);
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
  if ((e.target as HTMLElement).closest("input,button,a,textarea,[contenteditable='true'],[data-open],[data-ddl],#note-live,.cm-editor")) return;
  post({ type: "deselect" });
});

(window as any).CK = {
  setData(json: string) {
    const d = JSON.parse(json);
    events = d.events || []; deadlines = d.deadlines || []; today = d.today || "";
    notes = d.dailyNotes || {};
    todosDirty = true;                    // re-aggregate event + daily-note todos on next todo render
    if (!last.from) last.from = d.viewIso || today;
    isoOf.delete(p0); isoOf.delete(p1);   // force a re-render with the new data
    apply();
  },
  tick(from: string, to: string, dir: number, p: number, reveal: number, slide: number) {
    last = { from, to: to || "", dir, p, reveal, slide };
    apply();
  },
  setTab(t: "todo" | "note") { applyTab(t); },               // Swift (native tabs) drives the tab
  setNoteMode(m: "edit" | "preview") {                       // native edit/preview toggle (no echo back)
    if (noteMode !== m) { noteMode = m; liveMode = ""; apply(); }
  },
  setInactive(on: boolean) { scrim.classList.toggle("on", on); },   // drawer open → blur + block the dashboard
  setTheme(vars: Record<string, string>) { const s = document.documentElement.style; for (const k in vars) s.setProperty(k, vars[k]); },
};
post({ type: "ready" });
