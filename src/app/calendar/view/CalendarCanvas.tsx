"use client";

// ─────────────────────────────────────────────────────────────────────────────
// CalendarCanvas — the top-level orchestrator for the calendar view.
//
// It wires the state engine (useCalendarInteractions) and the data stores
// (useEvents / useBandEvents / useDeadlines / useCalendarSettings / useHistory) to the
// render tree, then composes the screen from Z-ordered pieces:
//   top bar (breadcrumb + Edit/View/Help menus)
//   → ItemView background scene (grid, labels, today/now)
//   → BandEventsLayer / PromotedBandLayer / EventsLayer / DeadlinesLayer
//   → TrackEditor, DailyDashboard + DailyResizeHandle (day view), TimelineScrollbar
//   → drawers (EventDrawer / BandEventDrawer / DeadlineDrawer) and EventContextMenu.
//
// Local state here is UI-glue only — selection, the open drawer/menu, inline-edit target,
// tag filter, clipboard, dim-past toggle. Geometry lives in ../geometry; view/navigation
// state lives in the interactions hook; persisted data lives in the model hooks.
// ─────────────────────────────────────────────────────────────────────────────

import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { CSSProperties } from "react";
import { buildScene } from "../geometry/scene";
import { setDaily, frameFor } from "../geometry/frames";
import DailyDashboard, { type DashHandle } from "./daily/DailyDashboard";
import DailyResizeHandle from "./daily/DailyResizeHandle";
import { fmtRange, snapHour, TimedEvent } from "../model/types/eventTypes";
import { LABEL_W, TRACK_H, BAR_H, TOP_PAD } from "../geometry/constants";
import { MONTH_LONG, weekStartDOM, weekOfDate, resolveDate } from "../util/dates";
import type { Hover } from "../geometry/types";
import { tzDeltaHours, tzAbbrev } from "../util/timezones";
import { timelineInfo, pointToSlot, eventTextLayout } from "../geometry/eventGeom";
import EventBadges from "./events/EventBadges";
import { bandSlotAtPoint } from "../geometry/bandGeom";
import { daysInMonth } from "../model/api/mock";
import { occurrenceDates, occDate, baseHidden } from "../model/occurrences";
import { setEventHidden, internalizeEvent } from "../model/api/apiClient";
import { BandEvent } from "../model/types/bandEventTypes";
import { Deadline } from "../model/types/deadlineTypes";
import TimelineScrollbar from "./daily/TimelineScrollbar";
import { useCalendarInteractions } from "../interactions/useCalendarInteractions";
import { useCalendarSettings } from "../model/hooks/useCalendarSettings";
import { useHistory } from "../model/history";
import { useEvents } from "../model/hooks/useEvents";
import { useBandEvents } from "../model/hooks/useBandEvents";
import { useDeadlines } from "../model/hooks/useDeadlines";
import { useBackgroundSync } from "../model/hooks/useBackgroundSync";
import ItemView from "./events/Item";
import TrackEditor from "./editors/TrackEditor";
import EventsLayer from "./layers/EventsLayer";
import EventDrawer from "./drawers/EventDrawer";
import BandEventDrawer from "./drawers/BandEventDrawer";
import DeadlineDrawer from "./drawers/DeadlineDrawer";
import EventContextMenu from "./menus/EventContextMenu";
import EditMenu from "./menus/EditMenu";
import ViewMenu from "./menus/ViewMenu";
import HelpMenu from "./menus/HelpMenu";
import ConnectivityMenu from "./menus/ConnectivityMenu";
import { TagRow, UNTAGGED } from "./menus/TagFilterMenu";
import BandEventsLayer from "./layers/BandEventsLayer";
import PromotedBandLayer from "./layers/PromotedBandLayer";
import DeadlinesLayer from "./layers/DeadlinesLayer";
import { deadlineTimeLabel } from "../util/deadlineFormat";
import { NO_REPEAT, Repeat } from "@/lib/calendar/api";
import type { ParsedTodo } from "@/lib/assistant/tools/todos";
import { ConfirmDialog } from "@/app/components/ui/ConfirmDialog";

// Layout constants bridged into CSS as custom properties on the .cc-wrap root, so a
// number that CSS needs lives only in TS (geometry/constants) and can't drift. The CSS
// rules carry the same value as a fallback. Static (constants), so defined once here.
const WRAP_VARS = { "--cc-bar-h": `${BAR_H}px` } as CSSProperties;

// Ordinal suffix for a day-of-month (1→st, 2→nd, 3→rd, 4→th, 11–13→th …).
function ordinal(n: number): string {
  const v = n % 100;
  if (v >= 11 && v <= 13) return "th";
  return ["th", "st", "nd", "rd"][n % 10] ?? "th";
}

export default function CalendarCanvas() {
  const { wrapRef, vp, z, focus, displayFocus, week, scrollY, tlScroll, setTlScroll, setWeekHourH, hoverMonth, hoverWeek, hover, now, year, currentYear, selectYear, goToCurrentYear, goToNow, goToToday, goToMonth, goToOccurrence, revealHour, ensureHourVisible, ensureDayVisibleInWeek, zoomToDay, zoomToWeekOfDay, zoomToMonthWithDay, rebaseFocusAndZoom, scrollToMonth, kbDay, kbActive, setKbDayFocus, blurKbFocus, tweenTo, onMove, onClick, clearHover, monthAnim, detailMul, dailyDom, dayAnim, monthEdge, dailyFrac, setDailyFrac, yearFade } =
    useCalendarInteractions();
  const { trackNames, editTrack, mainTz, mainTzSetting, altTz, setAltTz, setMainTz } = useCalendarSettings(year);
  const history = useHistory();
  const [showHidden, setShowHidden] = useState(false); // View → "Show hidden events" (soft-deleted imports)
  const { events, addEvent, updateEvent, removeEvent } = useEvents(year, history, showHidden);
  const { events: bandEvents, addEvent: addBandEvent, updateEvent: updateBandEvent, removeEvent: removeBandEvent } = useBandEvents(year, history, showHidden);
  const { deadlines, addDeadline, updateDeadline, removeDeadline } = useDeadlines(year, history, showHidden);
  useBackgroundSync(); // refetch when the periodic background sync lands new/changed events

  // Each year loads its own events; entries referencing other years would be stale.
  // Depend on the stable `clear` only — `history` identity flips when canUndo/canRedo
  // change, which must NOT re-trigger a wipe.
  const clearHistory = history.clear;
  useEffect(() => { clearHistory(); }, [year, clearHistory]);

  // The AI assistant navigates the view via this event (set_view → view_change). Week requests
  // currently land on the containing month (no external goToWeek yet).
  useEffect(() => {
    const onSetView = (e: Event) => {
      const v = (e as CustomEvent<{ year?: number; zoom?: string; focusedMonth?: number; focusedWeekStart?: string }>).detail || {};
      if (typeof v.year === "number" && v.year !== year) selectYear(v.year);
      let month = typeof v.focusedMonth === "number" ? v.focusedMonth : focus;
      if (typeof v.focusedWeekStart === "string") {
        const mm = Number(v.focusedWeekStart.slice(5, 7));
        if (mm >= 1 && mm <= 12) month = mm - 1;
      }
      if (v.zoom === "year") tweenTo(0);
      else if (v.zoom === "month" || v.zoom === "week" || typeof v.focusedMonth === "number") goToMonth(month);
    };
    window.addEventListener("calendar:setview", onSetView);
    return () => window.removeEventListener("calendar:setview", onSetView);
  }, [year, focus, selectYear, goToMonth, tweenTo]);

  const [yearMenuOpen, setYearMenuOpen] = useState(false);
  // Tag filter: keys (lowercased tag, or UNTAGGED) toggled OFF. Empty = show everything.
  const [tagHidden, setTagHidden] = useState<Set<string>>(new Set());
  const [overEvent, setOverEvent] = useState(false);
  const [drawerId, setDrawerId] = useState<string | null>(null);
  const [previewColor, setPreviewColor] = useState<string | null>(null); // hover a swatch → preview on the spotlight copy
  const [menu, setMenu] = useState<{ id: string; x: number; y: number } | null>(null);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const selectedIdRef = useRef(selectedId);
  selectedIdRef.current = selectedId;
  // One-shot trigger to start INLINE name editing on a specific event (Enter on a selection).
  // The matching event view consumes it (enters edit mode) and clears it via onEditConsumed.
  const [editingId, setEditingId] = useState<string | null>(null);
  // True when an event was selected at the moment a click began — that click only clears the
  // selection, so it must NOT also navigate (open a month/week). Snapshotted at mousedown
  // (capture phase, before the deselect listener runs) so the click handler can read it.
  const hadSelectionAtDownRef = useRef(false);
  const [focusedOcc, setFocusedOcc] = useState<string | null>(null); // the clicked occurrence date "YYYY-MM-DD" (null = the base)
  // Arrow-key navigation's "vertical focus location" — the hour anchor. Set when the mouse selects an
  // event (to that event's time) and re-set on Up/Down; Left/Right keep it fixed and pick each new
  // day's event closest to it. null until the first selection.
  const navAnchorRef = useRef<number | null>(null);
  // Daily-view "dashboard" keyboard space: drives the TODO list via an imperative handle. dashActive
  // marks it as the current nav space (only in daily view).
  const dashRef = useRef<DashHandle>(null);
  const [dashActive, setDashActive] = useState(false);
  // Yearly-view "track" space: which of a focused month's 4 track-name inputs is being edited (0–3), or
  // null. A ref (no re-render) — the visual is the native input focus; the month stays highlighted.
  const trackIdxRef = useRef<number | null>(null);
  const [confirmDeleteId, setConfirmDeleteId] = useState<string | null>(null);
  const [hideConfirmId, setHideConfirmId] = useState<string | null>(null); // "make invisible?" callout for imported events
  const [recurDelete, setRecurDelete] = useState<{ id: string; occ: string } | null>(null); // recurring delete → pick scope
  const [crossYear, setCrossYear] = useState<{ id: string; ty: number; tm: number; tw: number; lvl: number } | null>(null); // "go to first" lands in another year → confirm
  // View preference: dim events that have already happened (opacity). Persisted in localStorage
  // (a client-only view setting); read after mount to avoid an SSR/first-paint mismatch.
  const [dimPast, setDimPast] = useState(false);
  useEffect(() => { setDimPast(localStorage.getItem("cc-dim-past") === "1"); }, []);
  const toggleDimPast = () => setDimPast((v) => { const nv = !v; try { localStorage.setItem("cc-dim-past", nv ? "1" : "0"); } catch {} return nv; });
  // Clipboard for copy/cut/paste of events (snapshot, kept across the source's deletion on cut).
  const [clip, setClip] = useState<
    | { kind: "timed"; ev: TimedEvent }
    | { kind: "band"; ev: BandEvent }
    | { kind: "deadline"; ev: Deadline }
    | null
  >(null);
  // Latest cursor position over the calendar — where ⌘V / Edit▸Paste drops the event.
  const pasteAnchorRef = useRef<{ x: number; y: number } | null>(null);
  const yearWrapRef = useRef<HTMLDivElement>(null);

  // The vertical location (decimal hour) of a navigable item — a timed event's start or a deadline's
  // hour. null for anything without a timeline position (all-day band events, unknown ids). Occurrence
  // ghosts share their base's time, so the id alone is enough.
  const vlocOf = (id: string): number | null => {
    const t = events.find((x) => x.id === id);
    if (t) return t.startHour;
    const d = deadlines.find((x) => x.id === id);
    if (d) return d.hour;
    return null;
  };
  // Interactions carry which occurrence (date) was clicked, so per-occurrence actions work. A mouse
  // selection also seeds the arrow-nav vertical anchor with the picked item's time.
  const selectEvent = (id: string | null, occ?: string | null) => {
    setSelectedId(id);
    setFocusedOcc(occ ?? null);
    if (dashActive) { setDashActive(false); dashRef.current?.blur(); } // a mouse selection leaves the dashboard nav space
    trackIdxRef.current = null;
    if (id != null) { const v = vlocOf(id); if (v != null) navAnchorRef.current = v; }
  };
  // Open the drawer, first centering the clicked event in the space left of the drawer: the shell
  // shifts left so the event's center lands at the midpoint of the (X − drawerWidth) free area.
  // delta = eventCenter − (X − D)/2, capped at ≥ 0 (never shift right). The subtraction + cap live
  // in CSS (max(), 100vw, --cc-drawer-w) so a drawer resize re-solves it live; here we only publish
  // the event's UNSHIFTED viewport center as --cc-evcenter.
  const measureEventCenterX = (id: string, occ: string | null): number | null => {
    const wrap = wrapRef.current;
    if (!wrap) return null;
    const el =
      (occ ? wrap.querySelector(`[data-ev-id="${id}"][data-occ="${occ}"]`) : wrap.querySelector(`[data-ev-id="${id}"]:not([data-occ])`))
      ?? wrap.querySelector(`[data-ev-id="${id}"]`);
    if (!el) return null;
    const r = el.getBoundingClientRect();
    // If a drawer is already open the shell is mid-shift — subtract its transform for the unshifted center.
    const shell = wrap.closest(".app-shell");
    const tf = shell ? getComputedStyle(shell).transform : "none";
    const m = tf && tf !== "none" ? new DOMMatrix(tf).m41 : 0;
    return r.left + r.width / 2 - m;
  };
  const openDrawer = (id: string, occ?: string | null) => {
    // Daily view: never shift the app shell (the daily-dashboard owns the right side) — pin
    // --cc-evcenter to 0 so the CSS max() resolves the shift to 0. Otherwise center the event.
    const c = z >= 2.5 ? 0 : measureEventCenterX(id, occ ?? null);
    document.documentElement.style.setProperty("--cc-evcenter", c != null ? `${c}px` : "50vw");
    setDrawerId(id);
    setFocusedOcc(occ ?? null);
  };
  const openMenu = (id: string, x: number, y: number, occ?: string | null) => { setMenu({ id, x, y }); setFocusedOcc(occ ?? null); };
  // Drag the daily timeline's right edge → resize it. New width fraction = (cursorX − gutter) /
  // content width; the hook clamps it to [1/7, 0.6] and persists it.
  const startDailyResize = (e: React.MouseEvent) => {
    e.preventDefault();
    e.stopPropagation();
    const wrap = wrapRef.current;
    if (!wrap) return;
    const rect = wrap.getBoundingClientRect();
    document.body.classList.add("cc-col-resizing");
    const onMove = (me: MouseEvent) => setDailyFrac((me.clientX - rect.left - LABEL_W) / Math.max(1, rect.width - LABEL_W));
    const onUp = () => {
      document.body.classList.remove("cc-col-resizing");
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
    };
    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
  };
  // While a drawer is open, slide the whole app shell left (CSS) so the (body-portaled)
  // drawer doesn't cover the event being edited.
  useEffect(() => {
    document.body.classList.toggle("cc-drawer-open", drawerId != null);
    setPreviewColor(null); // reset any color preview when the drawer opens/closes
    return () => document.body.classList.remove("cc-drawer-open");
  }, [drawerId]);

  // The right-click callout is pinned to the event's position at open time; once the
  // view transforms (zoom/page/scroll) that anchor is stale, so dismiss it.
  useEffect(() => {
    setMenu(null);
  }, [z, focus, week, scrollY, tlScroll]);

  // The event currently shown in the drawer (timed, band, or deadline) + a "spotlight" copy.
  const drawerTimed = drawerId ? events.find((e) => e.id === drawerId) ?? null : null;
  const drawerBand = drawerId ? bandEvents.find((e) => e.id === drawerId) ?? null : null;
  const drawerDeadline = drawerId ? deadlines.find((e) => e.id === drawerId) ?? null : null;
  const drawerEv = drawerTimed ?? drawerBand ?? drawerDeadline;
  const drawerSig = drawerEv ? JSON.stringify(drawerEv) : "";

  // If an undo/redo (or any delete) removes the event a drawer/menu is showing, dismiss it.
  useEffect(() => { if (drawerId && !drawerEv) setDrawerId(null); }, [drawerId, drawerEv]);

  // ── Recurrence edits (work on any kind via the right store) ──
  const repeatOf = (id: string): Repeat | null =>
    events.find((e) => e.id === id)?.repeat ?? bandEvents.find((e) => e.id === id)?.repeat ?? deadlines.find((e) => e.id === id)?.repeat ?? null;
  const patchRepeat = (id: string, repeat: Repeat) => {
    if (events.some((e) => e.id === id)) updateEvent(id, { repeat });
    else if (bandEvents.some((e) => e.id === id)) updateBandEvent(id, { repeat });
    else updateDeadline(id, { repeat });
  };
  const deleteAny = (id: string) => { removeEvent(id); removeBandEvent(id); removeDeadline(id); };
  const isoMinus1 = (s: string) => {
    const [y, m, d] = s.split("-").map(Number);
    const dt = new Date(y, m - 1, d - 1);
    return `${dt.getFullYear()}-${String(dt.getMonth() + 1).padStart(2, "0")}-${String(dt.getDate()).padStart(2, "0")}`;
  };
  const deleteOccurrence = (id: string, occ: string) => patchRepeat(id, { ...(repeatOf(id) ?? NO_REPEAT), exdates: [...(repeatOf(id)?.exdates ?? []), occ] });
  const deleteFuture = (id: string, occ: string) => patchRepeat(id, { ...(repeatOf(id) ?? NO_REPEAT), until: isoMinus1(occ) });
  const isRecurring = (id: string) => { const r = repeatOf(id); return !!r && r.kind !== "none"; };
  // The event's own date "YYYY-MM-DD" — the occurrence to act on when not opened from a ghost.
  const eventDateOf = (id: string): string | null => {
    const t = events.find((e) => e.id === id); if (t) return `${t.year}-${String(t.month + 1).padStart(2, "0")}-${String(t.day).padStart(2, "0")}`;
    const b = bandEvents.find((e) => e.id === id); if (b) return `${b.year}-${String(b.month + 1).padStart(2, "0")}-${String(b.startDay).padStart(2, "0")}`;
    const d = deadlines.find((e) => e.id === id); if (d) return `${d.year}-${String(d.month + 1).padStart(2, "0")}-${String(d.day).padStart(2, "0")}`;
    return null;
  };
  // Delete request (drawer button / Delete key): a recurring event asks which scope to remove;
  // a plain event is deleted outright. `occ` is the viewed occurrence (a ghost, else the base).
  // Imported events soft-delete (hide) so re-sync won't resurrect them; manual events hard-delete.
  const anyEventById = (id: string) => events.find((e) => e.id === id) ?? bandEvents.find((e) => e.id === id) ?? deadlines.find((e) => e.id === id);
  const hideEvent = (id: string) => {
    setEventHidden(id, true).then(() => window.dispatchEvent(new CustomEvent("calendar:changed"))).catch((e) => console.error("[calendar] hide", e));
    setSelectedId(null); setDrawerId(null); setHideConfirmId(null);
  };
  const restoreEvent = (id: string) => {
    setEventHidden(id, false).then(() => window.dispatchEvent(new CustomEvent("calendar:changed"))).catch((e) => console.error("[calendar] restore", e));
    setDrawerId(null);
  };
  // Detach an imported event → an editable manual copy (server hides the original + makes the copy).
  const internalizeCopy = (id: string) => {
    internalizeEvent(id).then(() => window.dispatchEvent(new CustomEvent("calendar:changed"))).catch((e) => console.error("[calendar] internalize", e));
    setSelectedId(null); setDrawerId(null);
  };
  const requestDeleteEvent = (id: string) => {
    if (anyEventById(id)?.imported) { setHideConfirmId(id); return; } // → "make invisible?" callout
    if (isRecurring(id)) { const occ = focusedOcc ?? eventDateOf(id); if (occ) { setRecurDelete({ id, occ }); return; } }
    deleteAny(id);
    setSelectedId(null);
  };
  // "Go to first occurrence": the base event IS the series' first occurrence. Close the drawer
  // (leaving it open over a navigating calendar strands the UI), let it settle, then animate to
  // the base's date AT THE LEVEL we're currently viewing from (year/month/week) and reopen the
  // drawer there. goToOccurrence picks the shortest zoom trajectory by how far the two are apart.
  // Close the drawer, let it settle, then animate to the base's date and reopen it there.
  const runGoToFirst = (id: string, ty: number, tm: number, tw: number, lvl: number) => {
    setDrawerId(null);
    setSelectedId(id);
    setFocusedOcc(null);
    window.setTimeout(() => goToOccurrence(ty, tm, tw, lvl, () => openDrawer(id, null)), 200);
  };
  const goToFirst = () => {
    if (!drawerEv) return;
    const id = drawerEv.id;
    const ty = drawerEv.year, tm = drawerEv.month;
    const td = drawerTimed ? drawerTimed.day : drawerBand ? drawerBand.startDay : drawerDeadline ? drawerDeadline.day : 1;
    const tw = Math.floor((new Date(ty, tm, 1).getDay() + td - 1) / 7); // week-row index of the base day
    const lvl = Math.round(z);
    // Cross-year: the base lives in another year — a silent year switch is disorienting, so ask
    // first. Confirming runs the same trajectory (which switches the year as it animates).
    if (ty !== year) { setCrossYear({ id, ty, tm, tw, lvl }); return; }
    runGoToFirst(id, ty, tm, tw, lvl);
  };
  // Jump the calendar to a (year, month, day) and open the event's drawer there — the same
  // navigate-then-open trajectory as "go to first occurrence" (cross-year aware via goToOccurrence).
  const navigateAndOpenDrawer = (id: string, ty: number, tm: number, td: number, occ: string | null) => {
    if (!Number.isInteger(ty) || !Number.isInteger(tm) || !Number.isInteger(td)) return; // unparseable anchor
    const tw = Math.floor((new Date(ty, tm, 1).getDay() + td - 1) / 7);
    const lvl = Math.round(z);
    setDrawerId(null);
    setSelectedId(id);
    setFocusedOcc(occ);
    window.setTimeout(() => goToOccurrence(ty, tm, tw, lvl, () => openDrawer(id, occ)), 200);
  };

  // Follow-the-agent navigation: the assistant emits `calendar:navigate` as it acts (band → month
  // view, timed/deadline → the week; openDrawer opens edits). A ref keeps the handler's closures
  // fresh without re-subscribing the window listener each render.
  type NavDetail = { id: string; year: number; month: number; day: number; hour?: number; zoom: "month" | "week"; openDrawer?: boolean; occ?: string | null };
  const onNavigateRef = useRef<(v: NavDetail) => void>(() => {});
  onNavigateRef.current = (v: NavDetail) => {
    if (v.openDrawer) { navigateAndOpenDrawer(v.id, v.year, v.month, v.day, v.occ ?? null); return; }
    if (v.zoom === "month") {
      if (v.year !== year) selectYear(v.year);
      goToMonth(v.month);
      selectEvent(v.id, v.occ ?? null); // highlight the event we navigated to
    } else {
      const tw = Math.floor((new Date(v.year, v.month, 1).getDay() + v.day - 1) / 7);
      // week view containing the day; on arrival scroll the timeline to the event's hour + select it
      goToOccurrence(v.year, v.month, tw, 2, () => {
        if (typeof v.hour === "number") revealHour(v.hour);
        selectEvent(v.id, v.occ ?? null);
      });
    }
  };
  useEffect(() => {
    const h = (e: Event) => onNavigateRef.current((e as CustomEvent<NavDetail>).detail);
    window.addEventListener("calendar:navigate", h);
    return () => window.removeEventListener("calendar:navigate", h);
  }, []);

  // A daily-note TODO click → navigate to that day, then ask the dashboard to open its NOTE tab and
  // place the caret on that source line (consumed + cleared by DailyDashboard).
  const [noteEdit, setNoteEdit] = useState<{ date: string; line: number } | null>(null);

  // Click a TODO in the daily dashboard → jump to its source event + open its drawer. The TODO
  // carries (eventId, occurrenceKey); resolve the event's date from the loaded stores
  // (authoritative) or fall back to the occurrence/due date. A daily-note TODO instead opens the
  // NOTE tab at that line.
  const openTodo = (t: ParsedTodo) => {
    if (t.source === "daily" && t.dailyDate) {
      const date = t.dailyDate;
      const [y, m, d] = date.split("-").map(Number);
      const tw = Math.floor((new Date(y, m - 1, 1).getDay() + d - 1) / 7);
      setDrawerId(null);
      window.setTimeout(() => goToOccurrence(y, m - 1, tw, Math.round(z), () => setNoteEdit({ date, line: t.line })), 200);
      return;
    }
    const occ = t.occurrenceKey ?? null;
    const te = events.find((e) => e.id === t.eventId);
    const be = bandEvents.find((e) => e.id === t.eventId);
    const de = deadlines.find((e) => e.id === t.eventId);
    let ty: number, tm: number, td: number;
    if (occ) { const [y, m, d] = occ.split("-").map(Number); ty = y; tm = m - 1; td = d; }
    else if (te) { ty = te.year; tm = te.month; td = te.day; }
    else if (be) { ty = be.year; tm = be.month; td = be.startDay; }
    else if (de) { ty = de.year; tm = de.month; td = de.day; }
    else { const [y, m, d] = (t.due ?? "").slice(0, 10).split("-").map(Number); ty = y; tm = m - 1; td = d; }
    navigateAndOpenDrawer(t.eventId, ty, tm, td, occ);
  };

  // Click an "Upcoming Deadlines" row → jump to that deadline + open its drawer.
  const openDeadlineItem = (d: Deadline) => navigateAndOpenDrawer(d.id, d.year, d.month, d.day, null);


  // ── Copy / cut / paste (the selected event) ──
  // Copy snapshots the selected event into `clip` (a shallow copy, so a later edit of the
  // original doesn't mutate it). Cut also deletes the source — the snapshot survives.
  const doCopy = () => {
    if (!selectedId) return;
    const t = events.find((e) => e.id === selectedId);
    if (t) { setClip({ kind: "timed", ev: { ...t } }); return; }
    const b = bandEvents.find((e) => e.id === selectedId);
    if (b) { setClip({ kind: "band", ev: { ...b } }); return; }
    const d = deadlines.find((e) => e.id === selectedId);
    if (d) { setClip({ kind: "deadline", ev: { ...d } }); return; }
  };
  const doCut = () => {
    if (!selectedId) return;
    doCopy();
    deleteAny(selectedId);
    setSelectedId(null);
  };
  // Paste at the cursor. A band (all-day) event only lands on a month track lane; a timed
  // event or deadline only lands on the day timeline (week view), snapped to the nearest
  // 30 minutes. A pasted copy is always a single event (recurrence is dropped).
  const doPaste = () => {
    const wrap = wrapRef.current;
    const anchor = pasteAnchorRef.current;
    if (!clip || !wrap || !anchor) return;
    const r = wrap.getBoundingClientRect();
    const px = anchor.x - r.left, py = anchor.y - r.top;
    if (clip.kind === "band") {
      const slot = bandSlotAtPoint(px, py, z, focus, week, vp, scrollY);
      if (!slot) return;
      const len = clip.ev.endDay - clip.ev.startDay;
      const startDay = Math.max(1, Math.min(daysInMonth(slot.month) - len, slot.day));
      const created = addBandEvent({ year, month: slot.month, track: slot.track, startDay, endDay: startDay + len, title: clip.ev.title, color: clip.ev.color, notes: clip.ev.notes, tags: clip.ev.tags, repeat: NO_REPEAT });
      selectEvent(created.id);
      return;
    }
    if (z < 1.5) return; // timed/deadline paste needs the day timeline (week view)
    const ptl = timelineInfo(z, focus, week, vp, scrollY, tlScroll);
    if (ptl.hourH <= 0 || py < ptl.tlTop || py > ptl.tlBottom) return;
    const slot = pointToSlot(px, py, ptl);
    if (slot.dom == null) return;
    const date = resolveDate(focus, slot.dom);
    if (!date) return;
    if (clip.kind === "timed") {
      const dur = clip.ev.endHour - clip.ev.startHour;
      const start = Math.max(0, Math.min(24 - dur, snapHour(slot.hourFrac, 30)));
      const created = addEvent({ year, month: date.month, day: date.day, startHour: start, endHour: start + dur, title: clip.ev.title, color: clip.ev.color, notes: clip.ev.notes, tags: clip.ev.tags, repeat: NO_REPEAT });
      selectEvent(created.id);
    } else {
      const hour = Math.max(0, Math.min(23.75, snapHour(slot.hourFrac, 30)));
      const created = addDeadline({ year, month: date.month, day: date.day, hour, title: clip.ev.title, color: clip.ev.color, notes: clip.ev.notes, tags: clip.ev.tags, originTz: null, repeat: NO_REPEAT });
      selectEvent(created.id);
    }
  };
  // Measure the real rendered event (handles overlap/clip/scroll/spillover) relative to
  // .cc-wrap, so the bright duplicate can sit exactly over the dimmed original — and ride
  // along with the same left-shift. Re-measured when the event moves or the viewport resizes.
  // Measure EVERY rendered element of the drawer's event — the base plus all recurrence
  // ghosts (data-occ) — so the spotlight can lift them all above the dim. `ghost` flags the
  // recurrence copies (the base, non-ghost, keeps the "selected" style).
  // `shape` is read from each measured element's own class — so a promoted timed/deadline
  // event (which is a BAND element) is duplicated band-shaped even though its drawer is timed
  // /deadline, and is visible in year view where the original (timeline) element isn't drawn.
  type Spot = { left: number; top: number; width: number; height: number; occ: string | null; shape: "ddl" | "band" | "timed"; bandGap: string | null; caret: "l" | "r" | null };
  const [spotBoxes, setSpotBoxes] = useState<Spot[]>([]);
  const [spotLines, setSpotLines] = useState<Spot[]>([]); // deadline lines
  useLayoutEffect(() => {
    const wrap = wrapRef.current;
    if (!drawerId || !wrap) { setSpotBoxes([]); setSpotLines([]); return; }
    const wr = wrap.getBoundingClientRect();
    const rel = (el: Element): Spot => {
      const r = el.getBoundingClientRect();
      const cl = (el as HTMLElement).classList;
      const shape = cl.contains("cc-ddl-label") ? "ddl" : cl.contains("cc-tevent-band") ? "band" : "timed";
      // Bands clip their title before the next bar on the lane (--band-gap). Carry that over so
      // the duplicates clamp identically — recurrence copies don't overlap their neighbours' text.
      const bandGap = cl.contains("cc-band-clip") ? getComputedStyle(el as HTMLElement).getPropertyValue("--band-gap").trim() || null : null;
      // Which side the deadline label's caret points (its -l/-r modifier) — needed so the spotlight
      // duplicate renders the same caret (it's a ::after whose colour comes from that modifier).
      const caret = cl.contains("cc-ddl-label-l") ? "l" : cl.contains("cc-ddl-label-r") ? "r" : null;
      return { left: r.left - wr.left, top: r.top - wr.top, width: r.width, height: r.height, occ: (el as HTMLElement).getAttribute("data-occ"), shape, bandGap, caret };
    };
    setSpotBoxes([...wrap.querySelectorAll(`[data-ev-id="${drawerId}"]`)].map(rel));
    setSpotLines([...wrap.querySelectorAll(`[data-ev-line-id="${drawerId}"]`)].map(rel)); // deadline lines only (empty otherwise)
  }, [drawerId, drawerSig, vp.w, vp.h, wrapRef, focusedOcc]);
  // Snapshot, at the very start of every click (capture phase, before any stopPropagation or
  // the deselect below), whether an event was selected — so a click that merely clears the
  // selection doesn't also trigger navigation.
  useEffect(() => {
    const onDown = () => { hadSelectionAtDownRef.current = selectedIdRef.current != null; };
    document.addEventListener("mousedown", onDown, true);
    return () => document.removeEventListener("mousedown", onDown, true);
  }, []);
  // Deselect the selected event when clicking anywhere that isn't an event/drawer/menu.
  useEffect(() => {
    if (selectedId == null) return;
    const onDown = (e: MouseEvent) => {
      const t = e.target as HTMLElement;
      // The top bar is chrome (Edit menu / breadcrumb / dropdowns) — clicking it must keep
      // the selection so Edit▸Cut/Copy still act on the selected event. Its empty gaps are
      // pointer-events:none, so the target is the canvas — also spare clicks within the bar's band.
      const wrapTop = wrapRef.current?.getBoundingClientRect().top ?? 0;
      if (e.clientY - wrapTop < BAR_H) return;
      if (!t.closest(".cc-tevent, .cc-drawer, .cc-sticker, .cc-ddl-label, .cc-ddl-add, .cc-bar")) setSelectedId(null);
    };
    document.addEventListener("mousedown", onDown, true); // capture → robust to stopPropagation
    return () => document.removeEventListener("mousedown", onDown, true);
  }, [selectedId]);

  // Keyboard: Delete/Backspace on a selected event → confirm (or delete outright if it's
  // still the untouched "Event" placeholder). Enter/Esc resolve the confirm dialog.
  // Move the selected timed event / deadline earlier (−) or later (+) by `delta` hours (15 min).
  // Band events are all-day (no time) → unaffected.
  const nudgeSelected = (delta: number) => {
    if (!selectedId) return;
    const t = events.find((x) => x.id === selectedId);
    if (t) {
      const dur = t.endHour - t.startHour;
      const start = Math.max(0, Math.min(24 - dur, t.startHour + delta));
      updateEvent(selectedId, { startHour: start, endHour: start + dur });
      return;
    }
    const d = deadlines.find((x) => x.id === selectedId);
    if (d) updateDeadline(selectedId, { hour: Math.max(0, Math.min(23.75, d.hour + delta)) });
  };

  // ── Arrow-key navigation between events (weekly/daily view) ──
  // A navigable instance: an event/deadline as it lands on one concrete day, with its vertical hour.
  type NavItem = { id: string; occ: string | null; month: number; day: number; vloc: number };
  // Every timed event + deadline instance (base and recurrence ghosts) that lands on (month, day),
  // sorted top-to-bottom by time. Mirrors the render layers' base/ghost expansion so nav matches what's
  // drawn. `occurrenceDates` is memoized, so calling this per keystroke (incl. day scans) stays cheap.
  const itemsOnDay = (month: number, day: number): NavItem[] => {
    const out: NavItem[] = [];
    const collect = (id: string, base: { year: number; month: number; day: number }, repeat: Repeat | undefined, vloc: number) => {
      if (base.year === year && base.month === month && base.day === day && !baseHidden(occDate(base), repeat)) {
        out.push({ id, occ: null, month, day, vloc });
      }
      if (repeat && repeat.kind !== "none") {
        for (const o of occurrenceDates(base, repeat, year)) {
          if (o.month === month && o.day === day) out.push({ id, occ: occDate(o), month, day, vloc });
        }
      }
    };
    for (const ev of events) collect(ev.id, { year: ev.year, month: ev.month, day: ev.day }, ev.repeat, ev.startHour);
    for (const d of deadlines) collect(d.id, { year: d.year, month: d.month, day: d.day }, d.repeat, d.hour);
    out.sort((a, b) => a.vloc - b.vloc || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
    return out;
  };
  // The timed event / deadline instance overlapping the Region hour-cursor cell [hour, hour+1) on
  // (month, day), nearest to the cursor — or null if the cursor isn't over one. (Enter in Region mode.)
  const eventAtRegion = (month: number, day: number, hour: number): NavItem | null => {
    const out: NavItem[] = [];
    const collect = (id: string, base: { year: number; month: number; day: number }, repeat: Repeat | undefined, vloc: number, overlaps: boolean) => {
      if (!overlaps) return;
      if (base.year === year && base.month === month && base.day === day && !baseHidden(occDate(base), repeat)) out.push({ id, occ: null, month, day, vloc });
      if (repeat && repeat.kind !== "none") for (const o of occurrenceDates(base, repeat, year)) if (o.month === month && o.day === day) out.push({ id, occ: occDate(o), month, day, vloc });
    };
    for (const ev of events) collect(ev.id, { year: ev.year, month: ev.month, day: ev.day }, ev.repeat, ev.startHour, ev.startHour < hour + 1 && ev.endHour > hour);
    for (const d of deadlines) collect(d.id, { year: d.year, month: d.month, day: d.day }, d.repeat, d.hour, Math.floor(d.hour) === hour);
    let best: NavItem | null = null;
    for (const it of out) if (!best || Math.abs(it.vloc - hour) < Math.abs(best.vloc - hour)) best = it;
    return best;
  };
  // The concrete day the current selection sits on — from the focused occurrence date, else the base.
  const currentInstanceDay = (): { month: number; day: number } | null => {
    if (selectedId == null) return null;
    if (focusedOcc) { const p = focusedOcc.split("-"); return { month: Number(p[1]) - 1, day: Number(p[2]) }; }
    const t = events.find((x) => x.id === selectedId);
    if (t) return { month: t.month, day: t.day };
    const d = deadlines.find((x) => x.id === selectedId);
    if (d) return { month: d.month, day: d.day };
    return null;
  };
  // Move the selection to a nav item, revealing it. Up/Down carry the anchor to the new time; Left/Right
  // leave it fixed (so successive day-hops stay aligned to the original vertical position).
  const selectInstance = (it: NavItem, updateAnchor: boolean) => {
    setSelectedId(it.id);
    setFocusedOcc(it.occ);
    if (updateAnchor) navAnchorRef.current = it.vloc;
    ensureHourVisible(it.vloc);
  };
  // Up/Down: step to the previous (earlier) / next (later) event on the SAME day; stop at the ends.
  const navWithinDay = (dir: -1 | 1) => {
    if (selectedId == null || vlocOf(selectedId) == null) return; // only from a timeline item (not all-day)
    const cur = currentInstanceDay();
    if (!cur) return;
    const items = itemsOnDay(cur.month, cur.day);
    const i = items.findIndex((it) => it.id === selectedId && (it.occ ?? null) === (focusedOcc ?? null));
    if (i < 0) return;
    const ni = i + dir;
    if (ni < 0 || ni >= items.length) return; // already at the top/bottom of the day
    selectInstance(items[ni], true);
  };
  // Left/Right (week view): jump to the nearest prior/later day that HAS an event and select the one
  // closest to the vertical anchor. Skips empty days; stops at the month boundary (never crosses months).
  const navAcrossDays = (dir: -1 | 1) => {
    if (selectedId == null || vlocOf(selectedId) == null) return;
    const cur = currentInstanceDay();
    if (!cur) return;
    const anchor = navAnchorRef.current ?? vlocOf(selectedId) ?? 0;
    const dim = daysInMonth(cur.month);
    for (let day = cur.day + dir; day >= 1 && day <= dim; day += dir) {
      const items = itemsOnDay(cur.month, day);
      if (items.length === 0) continue;
      let best = items[0];
      for (const it of items) if (Math.abs(it.vloc - anchor) < Math.abs(best.vloc - anchor)) best = it;
      ensureDayVisibleInWeek(cur.month, day);
      selectInstance(best, false);
      return;
    }
  };
  // Nearest timed item (by vertical hour) to a target hour — used by Tab → Timed and closest-event picks.
  const nearestHour = (items: NavItem[], hour: number): NavItem | null => {
    let best: NavItem | null = null;
    for (const it of items) if (!best || Math.abs(it.vloc - hour) < Math.abs(best.vloc - hour)) best = it;
    return best;
  };

  // ── Month-view all-day "gear": Tab from a day-focus selects the nearest lane bar; arrows do spatial
  // grid navigation between bars; Shift+arrows move the bar itself. "Lane bars" are EVERYTHING drawn on
  // the 4 track lanes — real band events, their recurrence ghosts, AND promoted timed/deadline ghosts.
  // We read them straight from the DOM (class cc-tevent-band) so navigation matches exactly what's on
  // screen and needs no per-layer geometry re-derivation.
  type BandCell = { id: string; occ: string | null; left: number; right: number; top: number; cx: number; cy: number };
  const bandCells = (): BandCell[] => {
    const wrap = wrapRef.current;
    if (!wrap) return [];
    const out: BandCell[] = [];
    wrap.querySelectorAll<HTMLElement>(".cc-tevent-band[data-ev-id]").forEach((el) => {
      const r = el.getBoundingClientRect();
      if (r.width < 1 || r.height < 1) return; // clipped/hidden bar
      out.push({ id: el.getAttribute("data-ev-id")!, occ: el.getAttribute("data-occ"), left: r.left, right: r.right, top: r.top, cx: r.left + r.width / 2, cy: r.top + r.height / 2 });
    });
    return out;
  };
  // Is the current selection one of those lane bars? (Robust across event kinds — a promoted timed/
  // deadline bar's id lives in `events`/`deadlines`, not `bandEvents`, so we ask the DOM instead.)
  const isBandSelected = () => !!(selectedId != null && wrapRef.current?.querySelector(`.cc-tevent-band[data-ev-id="${selectedId}"]`));
  // The concrete day a selection sits on (band bar, timed, or deadline) — the occurrence's start for a
  // ghost, else the base's — used to restore a Region focus (Tab / zoom-out) where the element sits.
  const selectionDay = (): { month: number; day: number } | null => {
    if (focusedOcc) { const p = focusedOcc.split("-"); return { month: Number(p[1]) - 1, day: Number(p[2]) }; }
    const b = bandEvents.find((x) => x.id === selectedId); if (b) return { month: b.month, day: b.startDay };
    const t = events.find((x) => x.id === selectedId); if (t) return { month: t.month, day: t.day };
    const d = deadlines.find((x) => x.id === selectedId); if (d) return { month: d.month, day: d.day };
    return null;
  };
  // Arrows in band gear: directional spatial navigation across the lane grid. Every bar whose centre
  // lies to the pressed side is a candidate; the winner minimises along-axis distance plus a soft penalty
  // on the off-axis offset — so it steps to the most rational neighbour, crossing lanes/days freely.
  const navBand = (key: string) => {
    const cells = bandCells();
    const cur = cells.find((c) => c.id === selectedId && (c.occ ?? null) === (focusedOcc ?? null)) ?? cells.find((c) => c.id === selectedId);
    if (!cur || cells.length <= 1) return;
    const horizontal = key === "ArrowLeft" || key === "ArrowRight";
    const sign = key === "ArrowLeft" || key === "ArrowUp" ? -1 : 1;
    let best: BandCell | null = null, bestScore = Infinity;
    for (const c of cells) {
      if (c === cur) continue;
      const along = (horizontal ? c.cx - cur.cx : c.cy - cur.cy) * sign; // forward distance in the pressed direction
      if (along <= 0.001) continue;                                      // must lie to that side
      const off = horizontal ? Math.abs(c.cy - cur.cy) : Math.abs(c.cx - cur.cx);
      const score = along + off * 2;                                     // direction dominates; off-axis is a soft penalty
      if (score < bestScore) { bestScore = score; best = c; }
    }
    if (best) { setSelectedId(best.id); setFocusedOcc(best.occ); }
  };
  // Shift+arrows in band gear move the bar itself. Real band: Up/Down = lane (track 0–3), Left/Right =
  // ±1 day (clamped to the month). Promoted timed/deadline bar: Up/Down = its promote lane, Left/Right =
  // the underlying event's day. Always patches the base, so a recurring series moves together.
  const moveSelectedBand = (key: string) => {
    const vertical = key === "ArrowUp" || key === "ArrowDown";
    const delta = key === "ArrowUp" || key === "ArrowLeft" ? -1 : 1;
    const band = bandEvents.find((b) => b.id === selectedId);
    if (band) {
      if (vertical) { const track = Math.max(0, Math.min(3, band.track + delta)); if (track !== band.track) updateBandEvent(band.id, { track }); }
      else { const len = band.endDay - band.startDay; const start = Math.max(1, Math.min(daysInMonth(band.month) - len, band.startDay + delta)); if (start !== band.startDay) updateBandEvent(band.id, { startDay: start, endDay: start + len }); }
      return;
    }
    const t = events.find((e) => e.id === selectedId);
    if (t) {
      if (vertical) updateEvent(t.id, { promoteTrack: Math.max(0, Math.min(3, (t.promoteTrack ?? 0) + delta)) });
      else { const day = Math.max(1, Math.min(daysInMonth(t.month), t.day + delta)); if (day !== t.day) updateEvent(t.id, { day }); }
      return;
    }
    const d = deadlines.find((e) => e.id === selectedId);
    if (d) {
      if (vertical) updateDeadline(d.id, { promoteTrack: Math.max(0, Math.min(3, (d.promoteTrack ?? 0) + delta)) });
      else { const day = Math.max(1, Math.min(daysInMonth(d.month), d.day + delta)); if (day !== d.day) updateDeadline(d.id, { day }); }
    }
  };
  // Shift+arrows in the Timed space: Up/Down nudge the time (±15 min); Left/Right move the event's day.
  const moveSelectedTimed = (key: string) => {
    if (key === "ArrowUp" || key === "ArrowDown") { nudgeSelected(key === "ArrowUp" ? -0.25 : 0.25); return; }
    const delta = key === "ArrowLeft" ? -1 : 1;
    const t = events.find((x) => x.id === selectedId);
    if (t) { const day = Math.max(1, Math.min(daysInMonth(t.month), t.day + delta)); if (day !== t.day) updateEvent(t.id, { day }); return; }
    const d = deadlines.find((x) => x.id === selectedId);
    if (d) { const day = Math.max(1, Math.min(daysInMonth(d.month), d.day + delta)); if (day !== d.day) updateDeadline(d.id, { day }); }
  };

  // ── Unified keyboard navigation across all views ───────────────────────────────────────────────
  // Views year(0)/month(1)/week(2)/day(3); "spaces" region/allday/timed. Region granularity: a month in
  // year, a day in month, a (day, hour) cell in week/day. Region uses kbDay {month, day, hour}; events use
  // selectedId/focusedOcc. Tab cycles the spaces the view offers; Space drills a Region inward; Shift+=/−
  // zoom while preserving the space + element; arrows navigate; Shift+arrows move the selected element.
  const viewOf = (): "year" | "month" | "week" | "day" => (z < 0.5 ? "year" : z < 1.5 ? "month" : z < 2.5 ? "week" : "day");
  const spaceOf = (): "region" | "allday" | "timed" | "dashboard" | "track" | "none" =>
    dashActive && viewOf() === "day" ? "dashboard"
    : viewOf() === "year" && trackIdxRef.current != null && (document.activeElement as HTMLElement | null)?.classList.contains("cc-track-input") ? "track"
    : isBandSelected() ? "allday" : selectedId != null ? "timed" : kbDay != null ? "region" : "none";
  // The representative {month, day, hour} of the current focus — the anchor for "closest element" on Tab.
  const focusAnchor = (): { month: number; day: number; hour: number } => {
    const sp = spaceOf();
    if (sp === "allday") { const d = selectionDay(); return { month: d?.month ?? focus, day: d?.day ?? 1, hour: 12 }; }
    if (sp === "timed") { const d = currentInstanceDay(); return { month: d?.month ?? focus, day: d?.day ?? 1, hour: (selectedId ? vlocOf(selectedId) : null) ?? 12 }; }
    if ((sp === "region" || sp === "track") && kbDay) return { month: kbDay.month, day: kbDay.day, hour: kbDay.hour };
    return { month: focus, day: viewOf() === "day" ? dailyDom : 1, hour: 12 };
  };
  // Nearest lane bar to an anchor (2D on-screen distance) — works in year view too (crosses months).
  const nearestBandToAnchor = (a: { month: number; day: number }): { id: string; occ: string | null } | null => {
    const wrap = wrapRef.current; if (!wrap) return null;
    const cells = bandCells(); if (!cells.length) return null;
    const wr = wrap.getBoundingClientRect();
    const f = frameFor(a.month, z, focus, week, vp, scrollY);
    const ax = wr.left + f.x0 + (a.day - 0.5) * f.dayW, ay = wr.top + f.bandY + 2 * f.trackH;
    let best = cells[0], bestD = Infinity;
    for (const c of cells) { const dx = c.cx - ax, dy = c.cy - ay, dd = dx * dx + dy * dy; if (dd < bestD) { bestD = dd; best = c; } }
    return { id: best.id, occ: best.occ };
  };
  // Nearest timed/deadline instance to an anchor (day + hour), expanding outward within the month.
  const nearestTimedToAnchor = (a: { month: number; day: number; hour: number }): NavItem | null => {
    let t = nearestHour(itemsOnDay(a.month, a.day), a.hour);
    if (t) return t;
    const dim = daysInMonth(a.month);
    for (let dist = 1; dist <= dim; dist++) {
      const cand: NavItem[] = [];
      if (a.day - dist >= 1) cand.push(...itemsOnDay(a.month, a.day - dist));
      if (a.day + dist <= dim) cand.push(...itemsOnDay(a.month, a.day + dist));
      t = nearestHour(cand, a.hour);
      if (t) return t;
    }
    return null;
  };
  // Enter a space, selecting the closest element to the anchor. Returns false if the target space has no
  // element to land on (so Tab can skip past an empty space).
  // Focus one of the focused month's 4 track-name inputs (yearly "track" stop). The month stays
  // highlighted (kbDay/kbActive kept); returns false only if there's no focused month to read tracks from.
  const enterTrack = (i: number): boolean => {
    if (!kbDay) return false;
    const m = kbDay.month;
    setSelectedId(null); setFocusedOcc(null);
    trackIdxRef.current = i;
    scrollToMonth(m); // make sure the month (and its inputs) are on screen
    requestAnimationFrame(() => {
      const el = document.querySelector(`.cc-track-input[data-track-m="${m}"][data-track-i="${i}"]`) as HTMLInputElement | null;
      el?.focus(); el?.select();
    });
    return true;
  };
  const enterSpace = (target: "region" | "allday" | "timed" | "dashboard", a: { month: number; day: number; hour: number }): boolean => {
    if (target !== "dashboard" && dashActive) { setDashActive(false); dashRef.current?.blur(); } // leaving the dashboard
    if (trackIdxRef.current != null) { trackIdxRef.current = null; const ae = document.activeElement as HTMLElement | null; if (ae?.classList.contains("cc-track-input")) ae.blur(); } // leaving track edit
    if (target === "dashboard") {
      if (!dashRef.current?.focusFirst()) return false; // no todos → let Tab skip past
      setSelectedId(null); setFocusedOcc(null); blurKbFocus(); setDashActive(true);
      return true;
    }
    if (target === "region") {
      setSelectedId(null); setFocusedOcc(null);
      const inHourView = viewOf() === "week" || viewOf() === "day";
      const hour = inHourView && kbDay ? kbDay.hour : a.hour; // week/day: keep the Region's own last hour across a Tab round-trip
      setKbDayFocus(a.month, a.day, hour);
      if (inHourView) ensureHourVisible(hour);
      return true;
    }
    if (target === "allday") { const b = nearestBandToAnchor(a); if (!b) return false; setSelectedId(b.id); setFocusedOcc(b.occ); blurKbFocus(); return true; }
    const t = nearestTimedToAnchor(a); if (!t) return false;
    setSelectedId(t.id); setFocusedOcc(t.occ); navAnchorRef.current = t.vloc; blurKbFocus(); ensureHourVisible(t.vloc); return true;
  };
  const RINGS: Record<string, ("region" | "allday" | "timed" | "dashboard")[]> = {
    year: ["region", "allday"], month: ["region", "allday"], week: ["region", "allday", "timed"], day: ["timed", "allday", "region", "dashboard"],
  };
  // Tab (or Shift+Tab): advance to the prev/next space that has something to land on. Year view splices
  // the focused month's 4 track-name stops between Region and All-day.
  const doTab = (back = false) => {
    const v = viewOf(), sp = spaceOf(), a = focusAnchor(), step = back ? -1 : 1;
    if (v === "year") {
      const seq: Array<() => boolean> = [
        () => enterSpace("region", a),
        () => enterTrack(0), () => enterTrack(1), () => enterTrack(2), () => enterTrack(3),
        () => enterSpace("allday", a),
      ];
      let idx = sp === "region" ? 0 : sp === "track" ? 1 + (trackIdxRef.current ?? 0) : sp === "allday" ? 5 : -1;
      for (let n = 0; n < seq.length; n++) { idx = (idx + step + seq.length) % seq.length; if (seq[idx]()) return; }
      return;
    }
    const ring = RINGS[v];
    let idx = ring.indexOf(sp as "region" | "allday" | "timed" | "dashboard");
    for (let n = 0; n < ring.length; n++) { idx = (idx + step + ring.length) % ring.length; if (enterSpace(ring[idx], a)) return; }
  };
  // Drill a Region one level inward (Space, and Shift+= while in Region). Remembers the day/hour.
  const regionDrill = (r: { month: number; day: number; hour: number }): boolean => {
    const v = viewOf();
    if (v === "year") zoomToMonthWithDay(r.month, r.day, r.hour);
    else if (v === "month") { setKbDayFocus(r.month, r.day, r.hour); zoomToWeekOfDay(r.month, r.day); ensureDayVisibleInWeek(r.month, r.day); ensureHourVisible(r.hour); }
    else if (v === "week") { zoomToDay(r.month, r.day); setKbDayFocus(r.month, r.day, r.hour); ensureHourVisible(r.hour); }
    else return false; // day: innermost
    return true;
  };
  // Region Up/Down/Left/Right: year → months (scrolls); month → days; week → hours (↕) + days (↔); day → hours.
  const navRegion = (key: string) => {
    if (!kbDay) return;
    const v = viewOf();
    if (v === "year") {
      if (key === "ArrowUp" || key === "ArrowDown") { const m = Math.max(0, Math.min(11, kbDay.month + (key === "ArrowUp" ? -1 : 1))); if (m !== kbDay.month) { setKbDayFocus(m, Math.min(kbDay.day, daysInMonth(m)), kbDay.hour); scrollToMonth(m, true); } }
    } else if (v === "month") {
      if (key === "ArrowLeft" || key === "ArrowRight") { const d = Math.max(1, Math.min(daysInMonth(kbDay.month), kbDay.day + (key === "ArrowLeft" ? -1 : 1))); if (d !== kbDay.day) setKbDayFocus(kbDay.month, d, kbDay.hour); }
    } else {
      if (key === "ArrowUp" || key === "ArrowDown") { const h = Math.max(0, Math.min(23, kbDay.hour + (key === "ArrowUp" ? -1 : 1))); if (h !== kbDay.hour) { setKbDayFocus(kbDay.month, v === "day" ? dailyDom : kbDay.day, h); ensureHourVisible(h); } }
      else if (v === "week" && (key === "ArrowLeft" || key === "ArrowRight")) { const d = Math.max(1, Math.min(daysInMonth(kbDay.month), kbDay.day + (key === "ArrowLeft" ? -1 : 1))); if (d !== kbDay.day) { setKbDayFocus(kbDay.month, d, kbDay.hour); ensureDayVisibleInWeek(kbDay.month, d); } }
    }
  };
  // Shift+= : zoom IN one level, preserving the space + element.
  const doZoomIn = () => {
    const v = viewOf(), sp = spaceOf(), a = focusAnchor();
    if (sp === "dashboard") return; // the dashboard owns the keyboard; no zoom
    if (sp === "region") { regionDrill(a); return; }
    if (sp === "allday") {
      if (v === "year") rebaseFocusAndZoom(a.month, 1);
      else if (v === "month") { ensureDayVisibleInWeek(a.month, a.day); tweenTo(2); }
      else if (v === "week") zoomToDay(a.month, a.day); // band shows in the daily strip; stays selected
      return;
    }
    if (sp === "timed") { const d = currentInstanceDay(); if (v === "week" && d) { zoomToDay(d.month, d.day); const vl = vlocOf(selectedId!); if (vl != null) ensureHourVisible(vl); } return; }
    tweenTo(Math.min(3, Math.round(z) + 1)); // no focus → plain zoom
  };
  // Shift+- : zoom OUT one level, preserving the space + element (timed past week → day-Region).
  const doZoomOut = () => {
    const v = viewOf(), sp = spaceOf(), a = focusAnchor();
    if (sp === "dashboard") return; // the dashboard owns the keyboard; no zoom
    if (sp === "allday") { const to = Math.max(0, Math.round(z) - 1); if (to === 0) scrollToMonth(a.month); tweenTo(to); return; }
    if (sp === "timed") {
      const d = currentInstanceDay(); const h = (selectedId ? vlocOf(selectedId) : null) ?? 12;
      if (v === "day" && d) { zoomToWeekOfDay(d.month, d.day); ensureHourVisible(h); }
      else if (v === "week" && d) { setSelectedId(null); setFocusedOcc(null); zoomToMonthWithDay(d.month, d.day, h); } // not drawn in month → convert to Region
      return;
    }
    // region / none
    if (v === "day") { const h = kbDay?.hour ?? a.hour; setKbDayFocus(focus, dailyDom, h); tweenTo(2); ensureHourVisible(h); }
    else if (v === "week") tweenTo(1);
    else if (v === "month") { scrollToMonth(kbDay?.month ?? focus); tweenTo(0); } // reveal the region month in the year grid
  };
  // Shift+N in an hour-cursor Region (week/day): create a 1-hour event at the cursor, select it, and open
  // its drawer — the drawer shell auto-focuses + selects the title so you can name it straight away.
  const createEventAtRegion = () => {
    if (!kbDay) return;
    const v = viewOf();
    if (v !== "week" && v !== "day") return;
    const day = v === "day" ? dailyDom : kbDay.day;
    const start = Math.max(0, Math.min(23, Math.round(kbDay.hour)));
    const created = addEvent({ year, month: kbDay.month, day, startHour: start, endHour: Math.min(24, start + 1), title: "Event", color: "default" });
    setSelectedId(created.id); setFocusedOcc(null); blurKbFocus();
    openDrawer(created.id, null);
  };

  const keyHandlerRef = useRef<(e: KeyboardEvent) => void>(() => {});
  keyHandlerRef.current = (e: KeyboardEvent) => {
    // A modal dialog (delete / hide / recurring-delete / cross-year confirm, or Help) is open →
    // the canvas is inert. The dialog owns its own keys (Escape closes it via <Dialog>).
    if (document.body.classList.contains("ui-dialog-open")) return;
    // Calendar-level undo/redo. While a text field is focused, Cmd+Z belongs to the
    // browser (native per-field text history) — bail and let it through.
    if ((e.metaKey || e.ctrlKey) && (e.key === "z" || e.key === "Z" || e.key === "y" || e.key === "Y")) {
      const a = e.target as HTMLElement | null;
      if (a && (a.tagName === "INPUT" || a.tagName === "TEXTAREA" || a.isContentEditable)) return;
      e.preventDefault();
      const redo = e.key === "y" || e.key === "Y" || ((e.key === "z" || e.key === "Z") && e.shiftKey);
      if (redo) history.redo(); else history.undo();
      return;
    }
    // Clipboard: ⌘C copy / ⌘X cut (need a selection), ⌘V paste at the cursor. Skip while a
    // text field is focused so the browser's native clipboard handling wins.
    if (e.metaKey || e.ctrlKey) {
      const a = e.target as HTMLElement | null;
      const editable = !!a && (a.tagName === "INPUT" || a.tagName === "TEXTAREA" || a.isContentEditable);
      if (!editable) {
        const k = e.key.toLowerCase();
        if (k === "c" && selectedId) { e.preventDefault(); doCopy(); return; }
        if (k === "x" && selectedId) { e.preventDefault(); doCut(); return; }
        if (k === "v" && clip) { e.preventDefault(); doPaste(); return; }
      }
    }
    // Unified keyboard navigation: Tab cycles the view's spaces; Space drills a Region inward; Shift+=/−
    // zoom preserving the space + element; arrows navigate within the space; Shift+arrows move the element.
    {
      const a = e.target as HTMLElement | null;
      const editable = !!a && (a.tagName === "INPUT" || a.tagName === "TEXTAREA" || a.isContentEditable);
      const plain = !e.metaKey && !e.ctrlKey && !e.altKey;
      // A focused track-name input (yearly "track" stop) types normally, but Tab/Shift+Tab keep cycling
      // the ring and Escape returns to the month.
      if (a?.classList.contains("cc-track-input")) {
        const ti = Number(a.getAttribute("data-track-i")); // sync (e.g. the input was focused by mouse)
        if (!Number.isNaN(ti)) trackIdxRef.current = ti;
        if (e.key === "Tab") { e.preventDefault(); doTab(e.shiftKey); return; }
        if (e.key === "Escape") { e.preventDefault(); enterSpace("region", focusAnchor()); return; }
        return; // everything else edits the name
      }
      if (!editable) {
        const sp = spaceOf();
        if (e.key === "Tab") { e.preventDefault(); doTab(e.shiftKey); return; }
        // Dashboard space (daily): Up/Down move through todos, Space checks/unchecks the focused one.
        if (sp === "dashboard") {
          if (e.key === "ArrowUp" || e.key === "ArrowDown") { e.preventDefault(); dashRef.current?.move(e.key === "ArrowUp" ? -1 : 1); return; }
          if (plain && !e.shiftKey && (e.key === " " || e.key === "Spacebar")) { e.preventDefault(); dashRef.current?.toggle(); return; }
        }
        // Enter over an event in an hour-cursor Region (week/day): select it → switch to Timed mode.
        if (plain && !e.shiftKey && e.key === "Enter" && sp === "region" && kbDay && (viewOf() === "week" || viewOf() === "day")) {
          const hit = eventAtRegion(kbDay.month, viewOf() === "day" ? dailyDom : kbDay.day, Math.round(kbDay.hour));
          if (hit) { e.preventDefault(); setSelectedId(hit.id); setFocusedOcc(hit.occ); navAnchorRef.current = hit.vloc; blurKbFocus(); ensureHourVisible(hit.vloc); return; }
        }
        // Shift+N: new event at the week/day hour cursor → drawer with the title focused.
        if (plain && e.shiftKey && (e.key === "n" || e.key === "N") && sp === "region" && (viewOf() === "week" || viewOf() === "day")) { e.preventDefault(); createEventAtRegion(); return; }
        if (plain && !e.shiftKey && (e.key === " " || e.key === "Spacebar") && sp === "region") { e.preventDefault(); regionDrill(focusAnchor()); return; }
        if (plain && e.shiftKey && (e.key === "+" || e.key === "=")) { e.preventDefault(); doZoomIn(); return; }
        if (plain && e.shiftKey && (e.key === "_" || e.key === "-")) { e.preventDefault(); doZoomOut(); return; }
        if (e.key.startsWith("Arrow")) {
          if (e.shiftKey && plain) {
            if (sp === "allday") { e.preventDefault(); moveSelectedBand(e.key); return; }
            if (sp === "timed") { e.preventDefault(); moveSelectedTimed(e.key); return; }
          } else if (plain) {
            if (sp === "region") { e.preventDefault(); navRegion(e.key); return; }
            if (sp === "allday") { e.preventDefault(); navBand(e.key); return; }
            if (sp === "timed") {
              e.preventDefault();
              if (e.key === "ArrowUp" || e.key === "ArrowDown") navWithinDay(e.key === "ArrowUp" ? -1 : 1);
              else if (viewOf() === "week") navAcrossDays(e.key === "ArrowLeft" ? -1 : 1);
              return;
            }
          }
        }
      }
    }
    // Selected-event shortcuts left to the event spaces: Enter = inline rename, Space = open drawer.
    if (selectedId != null) {
      const tgt = e.target as HTMLElement | null;
      const editable = !!tgt && (tgt.tagName === "INPUT" || tgt.tagName === "TEXTAREA" || tgt.isContentEditable);
      if (!editable) {
        if (e.key === "Enter") {
          e.preventDefault();
          // timed/band rename inline; deadlines (no inline edit) open the drawer (also name-focused).
          if (deadlines.some((d) => d.id === selectedId)) openDrawer(selectedId, focusedOcc);
          else setEditingId(selectedId);
          return;
        }
        if (e.key === " " || e.key === "Spacebar") { e.preventDefault(); openDrawer(selectedId, focusedOcc); return; }
      }
    }
    if (selectedId == null || (e.key !== "Delete" && e.key !== "Backspace")) return;
    const t = e.target as HTMLElement | null;
    if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) return; // typing
    e.preventDefault();
    const ev = events.find((x) => x.id === selectedId) ?? bandEvents.find((x) => x.id === selectedId) ?? deadlines.find((x) => x.id === selectedId);
    if (!ev) return;
    if (ev.imported) { setHideConfirmId(ev.id); return; } // imported → hide (no delete / recurring scope)
    if (isRecurring(ev.id)) { const occ = focusedOcc ?? eventDateOf(ev.id); if (occ) { setRecurDelete({ id: ev.id, occ }); return; } } // recurring → pick scope
    if (ev.title === "Event" || ev.title === "Deadline") { removeEvent(ev.id); removeBandEvent(ev.id); removeDeadline(ev.id); setSelectedId(null); } // untouched → no prompt
    else setConfirmDeleteId(ev.id);
  };
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => keyHandlerRef.current(e);
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);
  // Close the year dropdown on any click outside it.
  useEffect(() => {
    if (!yearMenuOpen) return;
    const onDown = (e: MouseEvent) => {
      if (yearWrapRef.current && !yearWrapRef.current.contains(e.target as Node)) setYearMenuOpen(false);
    };
    document.addEventListener("mousedown", onDown);
    return () => document.removeEventListener("mousedown", onDown);
  }, [yearMenuOpen]);
  // Track the cursor so ⌘V / Edit▸Paste knows where to drop the event. Moves over the top
  // bar (and its menus) are ignored, so opening Edit keeps the last in-calendar anchor.
  useEffect(() => {
    const onMM = (e: MouseEvent) => {
      if ((e.target as HTMLElement).closest(".cc-bar")) return;
      pasteAnchorRef.current = { x: e.clientX, y: e.clientY };
    };
    window.addEventListener("mousemove", onMM);
    return () => window.removeEventListener("mousemove", onMM);
  }, []);

  // ── Tag filter ──
  // Aggregate every event's tags (case-insensitive) into {key,label,count}, sorted by how
  // many events carry each, plus a count of untagged events. `key` (lowercased) is the
  // filter identity; `label` keeps a readable casing (first seen).
  const norm = (t: string) => t.trim().toLowerCase();
  const { tagRows, untaggedCount, allKeys } = useMemo(() => {
    const agg = new Map<string, { label: string; count: number }>();
    let untagged = 0;
    const tally = (tags?: string[]) => {
      const keys = new Set((tags ?? []).map(norm).filter(Boolean)); // distinct per event
      if (keys.size === 0) { untagged++; return; }
      for (const raw of tags ?? []) {
        const k = norm(raw);
        if (!k || !keys.has(k)) continue;
        keys.delete(k); // count each tag once per event
        const e = agg.get(k);
        if (e) e.count++; else agg.set(k, { label: raw.trim(), count: 1 });
      }
    };
    for (const e of events) tally(e.tags);
    for (const e of bandEvents) tally(e.tags);
    for (const e of deadlines) tally(e.tags);
    const rows: TagRow[] = [...agg.entries()]
      .map(([key, v]) => ({ key, label: v.label, count: v.count }))
      .sort((a, b) => b.count - a.count || a.label.localeCompare(b.label));
    const keys = new Set<string>(rows.map((r) => r.key));
    keys.add(UNTAGGED);
    return { tagRows: rows, untaggedCount: untagged, allKeys: keys };
  }, [events, bandEvents, deadlines]);

  // "If Any": an event shows if it has at least one tag that is NOT hidden; an untagged
  // event shows unless UNTAGGED is hidden. Empty filter → everything shows (fast path).
  const tagVisible = (tags?: string[]): boolean => {
    if (tagHidden.size === 0) return true;
    const ts = (tags ?? []).map(norm).filter(Boolean);
    if (ts.length === 0) return !tagHidden.has(UNTAGGED);
    return ts.some((t) => !tagHidden.has(t));
  };
  const visEvents = tagHidden.size === 0 ? events : events.filter((e) => tagVisible(e.tags));
  const visBand = tagHidden.size === 0 ? bandEvents : bandEvents.filter((e) => tagVisible(e.tags));
  const visDeadlines = tagHidden.size === 0 ? deadlines : deadlines.filter((e) => tagVisible(e.tags));

  const toggleTag = (key: string) => setTagHidden((prev) => {
    const next = new Set(prev);
    if (next.has(key)) next.delete(key); else next.add(key); // on→off / off→on
    return next;
  });
  const showAllTags = () => setTagHidden(new Set());
  const hideAllTags = () => setTagHidden(new Set(allKeys));

  if (vp.w === 0) return <div ref={wrapRef} className="cc-wrap" />;

  // Alt timezone → hours it leads the main tz by, at the focused week's date (DST-aware).
  let altDelta: number | null = null;
  let altLabel: string | null = null;
  if (altTz) {
    const r = resolveDate(focus, weekStartDOM(focus, Math.round(week)));
    const refDate = new Date(year, r?.month ?? focus, r?.day ?? 1, 12);
    altDelta = tzDeltaHours(mainTz, altTz, refDate);
    altLabel = tzAbbrev(altTz, refDate);
  }

  // overscroll rubber-band: nudge only the day content (the gutter month-name/track-editors/hour-labels
  // stay put), so a boundary push gives feedback without the gutter sliding off.
  const dayOverPan = monthEdge ? -monthEdge.dir * 30 * monthEdge.t : 0;
  setDaily(dailyDom, dailyFrac, dayAnim, dayOverPan); // sync the daily-view module state before buildScene / the layers read frameFor
  // An active keyboard Region focus stands in for the mouse hover so it highlights identically per view:
  // year → the month band, month → the day column, week/day → the hour cell. The mouse reclaims the
  // visual the moment it moves (kbActive→false). Only when nothing else (an event) is selected.
  const NO_HOVER: Hover = { month: null, dom: null, week: null, hour: null, hourFrac: null, nameMonth: null, nearLeft: null };
  let effHover: Hover = hover;
  if (kbActive && kbDay && selectedId == null) {
    if (z < 0.5) effHover = { ...NO_HOVER, month: kbDay.month };
    else if (z < 1.5) effHover = { ...NO_HOVER, month: kbDay.month, dom: kbDay.day, week: weekOfDate(kbDay.month, kbDay.day) };
    else effHover = { ...NO_HOVER, month: kbDay.month, dom: z < 2.5 ? kbDay.day : dailyDom, hour: kbDay.hour }; // week/day: hour cell
  }
  const scene = buildScene(z, focus, week, vp, scrollY, effHover, now, year, altDelta, altLabel, tlScroll, monthAnim, detailMul);
  const tl = timelineInfo(z, focus, week, vp, scrollY, tlScroll);
  const showScrollbar = z >= 1.5 && tl.zoomable; // week + day view; hidden only once all 24h fit at MAX hour height
  const level = z < 0.5 ? 0 : z < 1.5 ? 1 : z < 2.5 ? 2 : 3;
  // Daily view: progress 0→1 over z 2→3, and the chosen day's calendar date (for the breadcrumb + dashboard).
  const dailyP = Math.min(1, Math.max(0, z - 2));
  const dailyDate = resolveDate(focus, dailyDom);
  // "Today" button: shown unless we're already in today's daily view. `now` ticks each minute.
  const todayD = new Date(now);
  const inTodayDaily = level === 3 && year === currentYear && dailyDate != null
    && dailyDate.month === todayD.getMonth() && dailyDate.day === todayD.getDate();
  // The daily-dashboard's left edge = the day column's RESTING right edge. `tl.x0` carries the
  // day-paging pan, so add it back out — the dashboard stays put while the day content slides under it.
  const dashLeft = tl.x0 + dailyDom * tl.colW + (dayAnim ? dayAnim.dir * dayAnim.p * tl.colW : 0);
  // The carousel days: prev / current / next around the chosen day (clamped within the year), keyed
  // by date so the dashboard's inner panels are reused across a page-turn commit.
  const dashDays = dailyDate
    ? [-1, 0, 1]
        .map((offset) => {
          const d = new Date(year, dailyDate.month, dailyDate.day + offset);
          if (d.getFullYear() !== year) return null; // clamp at Jan 1 / Dec 31
          const iso = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
          return { offset, key: `${d.getMonth()}-${d.getDate()}`, iso, label: d.toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric" }) };
        })
        .filter((x): x is { offset: number; key: string; iso: string; label: string } => x != null)
    : [];
  const hint =
    level === 0 ? "click a month to open it · or pinch to zoom"
    : level === 1 ? (hoverWeek != null ? "click to open week · or pinch to zoom" : "hover a week · pinch to zoom")
    : level === 2 ? "scroll sideways to change week · pinch in for a day · or out"
    : "pinch out to leave the day";

  const years: number[] = [];
  for (let y = 2024; y <= currentYear + 3; y++) years.push(y);

  return (
    <div ref={wrapRef} style={WRAP_VARS} className={`cc-wrap${hoverMonth != null ? " cc-clickable" : ""}${overEvent ? " cc-over-event" : ""}`} onMouseMove={drawerId ? undefined : onMove} onMouseLeave={clearHover} onClick={drawerId ? undefined : (e) => { if (hadSelectionAtDownRef.current) return; onClick(e); }}>
      <div className="cc-bar">
        <div className="cc-crumbs" role="navigation" aria-label="Breadcrumb" onClick={(e) => e.stopPropagation()}>
          <div className="cc-year-wrap" ref={yearWrapRef}>
            <button
              className={`cc-crumb${level === 0 ? " current" : ""}`}
              onClick={() => (level === 0 ? setYearMenuOpen((o) => !o) : tweenTo(0))}
            >
              Year {year}{level === 0 && <span className="cc-caret">▾</span>}
            </button>
            {yearMenuOpen && (
              <div className="cc-year-menu" role="listbox">
                {years.map((y) => (
                  <button
                    key={y}
                    className={`cc-year-opt${y === year ? " sel" : ""}`}
                    onClick={() => { selectYear(y); setYearMenuOpen(false); }}
                  >
                    {y}
                  </button>
                ))}
              </div>
            )}
          </div>
          {level >= 1 && (
            <>
              <span className="cc-sep">›</span>
              <button className={`cc-crumb${level === 1 ? " current" : ""}`} onClick={() => tweenTo(1)}>{MONTH_LONG[displayFocus]}</button>
            </>
          )}
          {level >= 2 && (
            <>
              <span className="cc-sep">›</span>
              <button className={`cc-crumb${level === 2 ? " current" : ""}`} onClick={() => tweenTo(2)}>Week {Math.round(week) + 1}</button>
            </>
          )}
          {level >= 3 && dailyDate && (
            <>
              <span className="cc-sep">›</span>
              <button className="cc-crumb current" onClick={() => tweenTo(3)}>{new Date(year, dailyDate.month, dailyDate.day).toLocaleDateString(undefined, { weekday: "long" })}, {dailyDate.day}{ordinal(dailyDate.day)}</button>
            </>
          )}
        </div>
        {!inTodayDaily && (
          <button className="cc-action cc-action-accent cc-action-sm cc-today-btn" title="Jump to today" onClick={(e) => { e.stopPropagation(); goToToday(); }}>Today</button>
        )}
        <span className="cc-hint">{hint}</span>
        <div className="cc-bar-actions" onClick={(e) => e.stopPropagation()}>
          {year !== currentYear && (
            <button className="cc-action cc-action-accent cc-action-sm" onClick={goToCurrentYear}>Back to Current Year</button>
          )}
          <EditMenu
            canUndo={history.canUndo} onUndo={() => history.undo()}
            canRedo={history.canRedo} onRedo={() => history.redo()}
            canCut={selectedId != null} onCut={doCut}
            canCopy={selectedId != null} onCopy={doCopy}
            canPaste={clip != null} onPaste={doPaste}
            altTz={altTz} onAltTz={setAltTz}
            mainTz={mainTzSetting} onMainTz={setMainTz}
          />
          <ViewMenu
            onGo={goToNow}
            tags={tagRows}
            untaggedCount={untaggedCount}
            hidden={tagHidden}
            onToggle={toggleTag}
            onShowAll={showAllTags}
            onHideAll={hideAllTags}
            showHidden={showHidden}
            onToggleShowHidden={() => setShowHidden((v) => !v)}
            dimPast={dimPast} onToggleDimPast={toggleDimPast}
          />
          <ConnectivityMenu />
          <HelpMenu />
        </div>
      </div>

      {/* solid left gutter — occludes lane content that slides under it (week view) */}
      <div className="cc-gutter" style={{ width: LABEL_W }} />

      <div className="cc-layer" style={yearFade < 1 ? { opacity: yearFade } : undefined}>
        {scene.items.map((it) => <ItemView key={it.key} it={it} />)}
        <BandEventsLayer vp={vp} z={z} focus={focus} week={week} scrollY={scrollY} year={year} events={visBand} addEvent={addBandEvent} updateEvent={updateBandEvent} selectedId={selectedId} focusedOcc={focusedOcc} onSelect={selectEvent} onOpenDetail={openDrawer} onContextMenu={openMenu} editingId={editingId} onEditConsumed={() => setEditingId(null)} monthAnim={monthAnim} dimPast={dimPast} now={now} />
        <PromotedBandLayer vp={vp} z={z} focus={focus} week={week} scrollY={scrollY} year={year} timed={visEvents} deadlines={visDeadlines} bandEvents={visBand} updateTimed={updateEvent} updateDeadline={updateDeadline} selectedId={selectedId} focusedOcc={focusedOcc} onSelect={selectEvent} onOpenDetail={openDrawer} onContextMenu={openMenu} monthAnim={monthAnim} dimPast={dimPast} now={now} />
        <EventsLayer vp={vp} z={z} focus={focus} week={week} scrollY={scrollY} year={year} events={visEvents} addEvent={addEvent} updateEvent={updateEvent} onEventHover={setOverEvent} onOpenDetail={openDrawer} onContextMenu={openMenu} selectedId={selectedId} focusedOcc={focusedOcc} onSelect={selectEvent} tlScroll={tlScroll} editingId={editingId} onEditConsumed={() => setEditingId(null)} detailMul={detailMul} monthAnim={monthAnim} dimPast={dimPast} now={now} />
        <DeadlinesLayer vp={vp} z={z} focus={focus} week={week} scrollY={scrollY} tlScroll={tlScroll} year={year} mainTz={mainTz} hover={hover} deadlines={visDeadlines} addDeadline={addDeadline} updateDeadline={updateDeadline} selectedId={selectedId} onSelect={selectEvent} onOpenDetail={openDrawer} onContextMenu={openMenu} detailMul={detailMul} monthAnim={monthAnim} dimPast={dimPast} now={now} onLabelHover={setOverEvent} />
        <TrackEditor trackNames={trackNames} editTrack={editTrack} vp={vp} z={z} focus={focus} week={week} scrollY={scrollY} monthAnim={monthAnim} />
        {dailyP > 0.001 && (
          <DailyDashboard
            ref={dashRef}
            left={dashLeft}
            top={tl.tlTop - 18 - 4 * TRACK_H - 1} /* align the dashboard's top bar with the track band's top border */
            bandH={4 * TRACK_H}
            bottom={vp.h - 8}
            right={vp.w}
            opacity={dailyP}
            dir={dayAnim?.dir ?? 1}
            p={dayAnim?.p ?? 0}
            days={dashDays}
            today={(() => { const n = new Date(now); return `${n.getFullYear()}-${String(n.getMonth() + 1).padStart(2, "0")}-${String(n.getDate()).padStart(2, "0")}`; })()}
            deadlines={visDeadlines}
            onOpenTodo={openTodo}
            onOpenDeadline={openDeadlineItem}
            noteEdit={noteEdit}
            onNoteEditConsumed={() => setNoteEdit(null)}
          />
        )}
        {z > 2.5 && (
          <DailyResizeHandle
            x={dashLeft}
            top={tl.tlTop - 18 - 4 * TRACK_H - 3}
            bottom={vp.h - 8}
            onResizeStart={startDailyResize}
          />
        )}
        {/* month-boundary overscroll prompt: a circular progress ring that fills as you push past the
            first/last day (daily) or week (week view); "ready" at full → release commits the month-jump.
            The right edge is the dashboard's left in daily, or the viewport edge in week view. */}
        {monthEdge && z > 1.5 && (() => {
          const RC = 2 * Math.PI * 18; // ring circumference (r=18)
          const t = Math.min(1, monthEdge.t);
          const rightEdge = z > 2.5 ? dashLeft : vp.w; // daily: dashboard left · week: viewport edge
          return (
            <div
              className={`cc-month-edge${monthEdge.t >= 1 ? " ready" : ""}`}
              style={{
                top: (tl.tlTop + vp.h - 8) / 2,
                ...(monthEdge.dir > 0 ? { right: vp.w - rightEdge + 16 } : { left: LABEL_W + 16 }),
                opacity: Math.min(1, 0.55 + t * 0.45),
                transform: "translateY(-50%)",
              }}
            >
              <div className="cc-month-edge-circle">
                <svg width="44" height="44" viewBox="0 0 44 44" aria-hidden>
                  <circle className="cc-month-edge-track" cx="22" cy="22" r="18" />
                  <circle className="cc-month-edge-prog" cx="22" cy="22" r="18" style={{ strokeDasharray: RC, strokeDashoffset: RC * (1 - t) }} />
                </svg>
                <span className="cc-month-edge-arrow">{monthEdge.dir > 0 ? "→" : "←"}</span>
              </div>
              <span className="cc-month-edge-text">{monthEdge.dir > 0 ? "Next month" : "Prev month"}</span>
            </div>
          );
        })()}

        {/* Year-boundary overscroll prompt (yearly + month view, Dec↓ / Jan↑). Vertical arrows,
            centered horizontally in the content area, anchored to the bottom (next) / top (prev) edge. */}
        {monthEdge && z <= 1.5 && (() => {
          const RC = 2 * Math.PI * 18;
          const t = Math.min(1, monthEdge.t);
          return (
            <div
              className={`cc-month-edge cc-month-edge-v${monthEdge.t >= 1 ? " ready" : ""}`}
              style={{
                left: LABEL_W + (vp.w - LABEL_W) / 2,
                ...(monthEdge.dir > 0 ? { bottom: 20 } : { top: TOP_PAD + 16 }),
                opacity: Math.min(1, 0.55 + t * 0.45),
                transform: "translateX(-50%)",
              }}
            >
              <div className="cc-month-edge-circle">
                <svg width="44" height="44" viewBox="0 0 44 44" aria-hidden>
                  <circle className="cc-month-edge-track" cx="22" cy="22" r="18" />
                  <circle className="cc-month-edge-prog" cx="22" cy="22" r="18" style={{ strokeDasharray: RC, strokeDashoffset: RC * (1 - t) }} />
                </svg>
                <span className="cc-month-edge-arrow">{monthEdge.dir > 0 ? "↓" : "↑"}</span>
              </div>
              <span className="cc-month-edge-text">{monthEdge.dir > 0 ? "Next year" : "Previous year"}</span>
            </div>
          );
        })()}
      </div>

      {showScrollbar && (
        <TimelineScrollbar vp={vp} tlTop={tl.tlTop} viewH={tl.viewH} hourH={tl.hourH} scroll={tl.scroll} setScroll={setTlScroll} setHourH={setWeekHourH} />
      )}

      {/* Drawer spotlight: dim+blur veil over the calendar (click closes), with bright
          duplicates of the edited event — and all its visible recurrence occurrences —
          lifted above it. The base copy keeps the "selected" style; ghosts are plain. */}
      {/* Dim+blur veil — rendered whenever a drawer is open, INDEPENDENT of the measured
          spotlight below. Previously the whole block (veil included) was gated on
          spotBoxes.length > 0, so editing an event off-screen (e.g. to a non-visible day/month)
          left spotBoxes empty → the veil vanished while the drawer stayed open, with no way to
          click-to-close. Decoupling keeps the click-to-close veil always available. */}
      {drawerId && drawerEv && (
        <div className="cc-spot-mask" onMouseDown={() => setDrawerId(null)} onClick={(e) => e.stopPropagation()} />
      )}
      {drawerId && spotBoxes.length > 0 && drawerEv && (() => {
        const evColor = previewColor ?? drawerEv.color;
        const isRec = (drawerEv.repeat?.kind ?? "none") !== "none";
        const ai = !!drawerEv.createdByAI;
        const imported = !!drawerEv.imported;
        // Badges match how the underlying element renders them: base copies (occ null) show none,
        // occurrence ghosts add the recurrence mark, and band-shaped copies of a timed/deadline
        // event are promotions (the recurrence mark follows the series, like PromotedBandLayer).
        const badgesFor = (b: Spot) => {
          const promoted = b.shape === "band" && !drawerBand;
          return { ai, imported, recurring: isRec && (b.occ != null || promoted), promoted };
        };
        return (
          <>
            {/* deadline lines (only present for deadline events) */}
            {spotLines.map((b, i) => (
              <div key={`l${i}`} className={`cc-ddl cc-ev-${evColor}${b.occ === focusedOcc ? " selected" : ""}`} style={{ position: "absolute", inset: 0, zIndex: 91, pointerEvents: "none" }}>
                <div className="cc-ddl-line" style={{ position: "absolute", left: b.left, top: b.top, width: b.width, transform: "none" }} />
              </div>
            ))}
            {/* each measured element duplicated in its own shape (deadline label / band / timed) */}
            {spotBoxes.map((b, i) => {
              const badges = badgesFor(b);
              if (b.shape === "ddl") return (
                <div key={i} className={`cc-ddl cc-ev-${evColor}${b.occ === focusedOcc ? " selected" : ""}`} style={{ position: "absolute", inset: 0, zIndex: 91, pointerEvents: "none" }}>
                  <div
                    className={`cc-ddl-label${b.caret === "l" ? " cc-ddl-label-l" : b.caret === "r" ? " cc-ddl-label-r" : ""}`}
                    style={{ position: "absolute", left: b.left, top: b.top, width: b.width, height: b.height, transform: "none", pointerEvents: b.occ === focusedOcc ? "auto" : "none" }}
                    onMouseDown={(e) => e.stopPropagation()}
                  >
                    <span className="cc-ddl-title">{drawerEv.title}</span>
                    {drawerDeadline && <span className="cc-ddl-time">{deadlineTimeLabel(drawerDeadline, mainTz)}</span>}
                    <EventBadges {...badges} />
                  </div>
                </div>
              );
              // timed blocks get the same height-aware text scheme as the originals (hide the
              // time when short, clamp the title to whole lines); bands stay single-line.
              const timed = b.shape === "timed";
              const { tiny, short, titleLines } = timed ? eventTextLayout(b.height) : { tiny: false, short: false, titleLines: 1 };
              // bands: replay the original's title clip so a copy's text stops before the next bar
              const clip = b.shape === "band" && b.bandGap != null;
              return (
                <div
                  key={i}
                  className={`cc-item cc-tevent ${b.shape === "band" ? "cc-tevent-band " : ""}cc-ev-${evColor}${b.occ === focusedOcc ? " selected cc-focused-occ" : ""}${clip ? " cc-band-clip" : ""}${timed && short ? " cc-tevent-short" : ""}${timed && tiny ? " cc-tevent-tiny" : ""} cc-spot-dup`}
                  style={{ left: b.left, top: b.top, width: b.width, height: b.height, zIndex: 91, pointerEvents: b.occ === focusedOcc ? "auto" : "none", ...(clip ? ({ "--band-gap": b.bandGap } as React.CSSProperties) : {}) }}
                  onMouseDown={(e) => e.stopPropagation()}
                >
                  <div className="cc-tevent-inner">
                    <div className="cc-tevent-title" style={timed ? ({ WebkitLineClamp: titleLines } as React.CSSProperties) : undefined}>{drawerEv.title}</div>
                    {timed && drawerTimed && !short && <div className="cc-tevent-time">{fmtRange(drawerTimed.startHour, drawerTimed.endHour)}</div>}
                  </div>
                  <EventBadges {...badges} />
                </div>
              );
            })}
          </>
        );
      })()}

      {(() => {
        if (!drawerId) return null;
        if (drawerTimed) return <EventDrawer key={drawerId} event={drawerTimed} onChange={updateEvent} onDelete={requestDeleteEvent} onRestore={restoreEvent} onInternalize={internalizeCopy} onClose={() => setDrawerId(null)} onColorPreview={setPreviewColor} focusOcc={focusedOcc} onGoToFirst={goToFirst} />;
        if (drawerBand) return <BandEventDrawer key={drawerId} event={drawerBand} onChange={updateBandEvent} onDelete={requestDeleteEvent} onRestore={restoreEvent} onInternalize={internalizeCopy} onClose={() => setDrawerId(null)} onColorPreview={setPreviewColor} focusOcc={focusedOcc} onGoToFirst={goToFirst} />;
        if (drawerDeadline) return <DeadlineDrawer key={drawerId} event={drawerDeadline} mainTz={mainTz} onChange={updateDeadline} onDelete={requestDeleteEvent} onRestore={restoreEvent} onInternalize={internalizeCopy} onClose={() => setDrawerId(null)} onColorPreview={setPreviewColor} focusOcc={focusedOcc} onGoToFirst={goToFirst} />;
        return null;
      })()}

      {(() => {
        const tev = menu ? events.find((e) => e.id === menu.id) : null;
        const bev = menu ? bandEvents.find((e) => e.id === menu.id) : null;
        const ddl = menu ? deadlines.find((e) => e.id === menu.id) : null;
        const color = tev?.color ?? bev?.color ?? ddl?.color;
        const menuImported = !!(tev?.imported || bev?.imported || ddl?.imported);
        return menu && color != null ? (
          <EventContextMenu
            x={menu.x}
            y={menu.y}
            color={color}
            onColor={(c) => { if (tev) updateEvent(menu.id, { color: c }); else if (bev) updateBandEvent(menu.id, { color: c }); else updateDeadline(menu.id, { color: c }); }}
            onDelete={() => { requestDeleteEvent(menu.id); setMenu(null); }}
            imported={menuImported}
            onClose={() => setMenu(null)}
          />
        ) : null;
      })()}

      {(() => {
        const ev = confirmDeleteId
          ? (events.find((e) => e.id === confirmDeleteId) ?? bandEvents.find((e) => e.id === confirmDeleteId) ?? deadlines.find((e) => e.id === confirmDeleteId))
          : null;
        return ev ? (
          <ConfirmDialog
            open
            title="Delete this event?"
            message={<>“{ev.title}” will be removed. This can’t be undone.</>}
            onCancel={() => setConfirmDeleteId(null)}
            choices={[{ label: "Delete", variant: "danger", onClick: () => { removeEvent(ev.id); removeBandEvent(ev.id); removeDeadline(ev.id); setSelectedId(null); setConfirmDeleteId(null); } }]}
          />
        ) : null;
      })()}

      {(() => {
        const ev = hideConfirmId ? anyEventById(hideConfirmId) : null;
        return ev ? (
          <ConfirmDialog
            open
            title="Make this event invisible?"
            message={<>“{ev.title}” is synced from a calendar, so it can’t be deleted here. We’ll hide it — and it won’t reappear on the next sync. Restore it anytime from View → Show hidden events.</>}
            onCancel={() => setHideConfirmId(null)}
            choices={[{ label: "Hide", variant: "primary", onClick: () => hideEvent(ev.id) }]}
          />
        ) : null;
      })()}

      {(() => {
        const ev = recurDelete
          ? (events.find((e) => e.id === recurDelete.id) ?? bandEvents.find((e) => e.id === recurDelete.id) ?? deadlines.find((e) => e.id === recurDelete.id))
          : null;
        const close = () => setRecurDelete(null);
        return recurDelete && ev ? (
          <ConfirmDialog
            open
            compact
            spread
            closeAsX
            title="Delete recurring event"
            message={<>“{ev.title}” repeats. What would you like to delete?</>}
            onCancel={close}
            choices={[
              { label: "This event only", variant: "ghost", onClick: () => { deleteOccurrence(recurDelete.id, recurDelete.occ); close(); } },
              { label: "This & all future", variant: "ghost", onClick: () => { deleteFuture(recurDelete.id, recurDelete.occ); close(); } },
              { label: "All events", variant: "danger", onClick: () => { deleteAny(recurDelete.id); setSelectedId(null); close(); } },
            ]}
          />
        ) : null;
      })()}

      {crossYear && (
        <ConfirmDialog
          open
          title={`Jump to ${crossYear.ty}?`}
          message={`The first occurrence of this event is in ${crossYear.ty}, a different year from the one you’re viewing. Jump there to see it?`}
          onCancel={() => setCrossYear(null)}
          choices={[{ label: `Jump to ${crossYear.ty}`, variant: "primary", onClick: () => { const c = crossYear; setCrossYear(null); runGoToFirst(c.id, c.ty, c.tm, c.tw, c.lvl); } }]}
        />
      )}
    </div>
  );
}
