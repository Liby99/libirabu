"use client";

import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { X } from "lucide-react";
import { buildScene } from "./scene";
import { setDaily } from "./frames";
import DailyDashboard from "./DailyDashboard";
import DailyResizeHandle from "./DailyResizeHandle";
import { fmtRange, snapHour, TimedEvent } from "./eventTypes";
import { LABEL_W, TRACK_H } from "./constants";
import { MONTH_LONG, weekStartDOM, resolveDate } from "./dates";
import { tzDeltaHours, tzAbbrev } from "./timezones";
import { timelineInfo, pointToSlot, eventTextLayout } from "./eventGeom";
import EventBadges from "./EventBadges";
import { bandSlotAtPoint } from "./bandGeom";
import { daysInMonth } from "./mock";
import { BandEvent } from "./bandEventTypes";
import { Deadline } from "./deadlineTypes";
import TimelineScrollbar from "./TimelineScrollbar";
import { useCalendarInteractions } from "./useCalendarInteractions";
import { useCalendarSettings } from "./useCalendarSettings";
import { useHistory } from "./history";
import { useEvents } from "./useEvents";
import { useBandEvents } from "./useBandEvents";
import { useDeadlines } from "./useDeadlines";
import ItemView from "./Item";
import TrackEditor from "./TrackEditor";
import EventsLayer from "./EventsLayer";
import EventDrawer from "./EventDrawer";
import BandEventDrawer from "./BandEventDrawer";
import DeadlineDrawer from "./DeadlineDrawer";
import EventContextMenu from "./EventContextMenu";
import EditMenu from "./EditMenu";
import NavMenu from "./NavMenu";
import TagFilterMenu, { TagRow, UNTAGGED } from "./TagFilterMenu";
import BandEventsLayer from "./BandEventsLayer";
import PromotedBandLayer from "./PromotedBandLayer";
import DeadlinesLayer from "./DeadlinesLayer";
import { deadlineTimeLabel } from "./deadlineFormat";
import { NO_REPEAT, Repeat } from "@/lib/calendar/api";
import type { ParsedTodo } from "@/lib/assistant/tools/todos";

// Ordinal suffix for a day-of-month (1→st, 2→nd, 3→rd, 4→th, 11–13→th …).
function ordinal(n: number): string {
  const v = n % 100;
  if (v >= 11 && v <= 13) return "th";
  return ["th", "st", "nd", "rd"][n % 10] ?? "th";
}

export default function CalendarCanvas() {
  const { wrapRef, vp, z, focus, displayFocus, week, scrollY, tlScroll, setTlScroll, setWeekHourH, hoverMonth, hoverWeek, hover, now, year, currentYear, selectYear, goToCurrentYear, goToNow, goToMonth, goToOccurrence, tweenTo, onMove, onClick, clearHover, monthAnim, detailMul, dailyDom, dayAnim, monthEdge, dailyFrac, setDailyFrac } =
    useCalendarInteractions();
  const { trackNames, editTrack, mainTz, mainTzSetting, altTz, setAltTz, setMainTz } = useCalendarSettings(year);
  const history = useHistory();
  const { events, addEvent, updateEvent, removeEvent } = useEvents(year, history);
  const { events: bandEvents, addEvent: addBandEvent, updateEvent: updateBandEvent, removeEvent: removeBandEvent } = useBandEvents(year, history);
  const { deadlines, addDeadline, updateDeadline, removeDeadline } = useDeadlines(year, history);

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
  const [confirmDeleteId, setConfirmDeleteId] = useState<string | null>(null);
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

  // Interactions carry which occurrence (date) was clicked, so per-occurrence actions work.
  const selectEvent = (id: string | null, occ?: string | null) => { setSelectedId(id); setFocusedOcc(occ ?? null); };
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
  const requestDeleteEvent = (id: string) => {
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
  // Click a TODO in the daily dashboard → jump the calendar to its source event and open its
  // drawer. The TODO carries (eventId, occurrenceKey); resolve the event's date from the loaded
  // stores (authoritative) or fall back to the occurrence/due date, then reuse the same
  // navigate-then-open trajectory as "go to first occurrence" (cross-year aware via goToOccurrence).
  const openTodo = (t: ParsedTodo) => {
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
    if (!Number.isInteger(ty) || !Number.isInteger(tm) || !Number.isInteger(td)) return; // unparseable anchor
    const tw = Math.floor((new Date(ty, tm, 1).getDay() + td - 1) / 7);
    const lvl = Math.round(z);
    setDrawerId(null);
    setSelectedId(t.eventId);
    setFocusedOcc(occ);
    window.setTimeout(() => goToOccurrence(ty, tm, tw, lvl, () => openDrawer(t.eventId, occ)), 200);
  };

  const menuRepeat = menu ? repeatOf(menu.id) : null;
  const menuRecurring = !!menuRepeat && menuRepeat.kind !== "none";

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
  type Spot = { left: number; top: number; width: number; height: number; occ: string | null; shape: "ddl" | "band" | "timed"; bandGap: string | null };
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
      return { left: r.left - wr.left, top: r.top - wr.top, width: r.width, height: r.height, occ: (el as HTMLElement).getAttribute("data-occ"), shape, bandGap };
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
      // the selection so Edit▸Cut/Copy still act on the selected event.
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

  const keyHandlerRef = useRef<(e: KeyboardEvent) => void>(() => {});
  keyHandlerRef.current = (e: KeyboardEvent) => {
    // The recurring-delete scope dialog is modal: swallow every key (Escape dismisses it) so the
    // canvas behind stays inert.
    if (recurDelete != null) { if (e.key === "Escape") { e.preventDefault(); setRecurDelete(null); } else e.preventDefault(); return; }
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
    if (confirmDeleteId != null) {
      if (e.key === "Escape") { e.preventDefault(); setConfirmDeleteId(null); }
      else if (e.key === "Enter") { e.preventDefault(); removeEvent(confirmDeleteId); removeBandEvent(confirmDeleteId); removeDeadline(confirmDeleteId); setSelectedId(null); setConfirmDeleteId(null); }
      return;
    }
    // Selected-event shortcuts: Enter = inline rename, Space = open drawer, Up/Down = ±15 min.
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
        if (e.key === "ArrowUp" || e.key === "ArrowDown") { e.preventDefault(); nudgeSelected(e.key === "ArrowUp" ? -0.25 : 0.25); return; }
      }
    }
    if (selectedId == null || (e.key !== "Delete" && e.key !== "Backspace")) return;
    const t = e.target as HTMLElement | null;
    if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) return; // typing
    e.preventDefault();
    const ev = events.find((x) => x.id === selectedId) ?? bandEvents.find((x) => x.id === selectedId) ?? deadlines.find((x) => x.id === selectedId);
    if (!ev) return;
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
  const scene = buildScene(z, focus, week, vp, scrollY, hover, now, year, altDelta, altLabel, tlScroll, monthAnim, detailMul);
  const tl = timelineInfo(z, focus, week, vp, scrollY, tlScroll);
  const showScrollbar = z >= 1.5 && tl.maxScroll > 0; // week + day view, day taller than the viewport
  const level = z < 0.5 ? 0 : z < 1.5 ? 1 : z < 2.5 ? 2 : 3;
  // Daily view: progress 0→1 over z 2→3, and the chosen day's calendar date (for the breadcrumb + dashboard).
  const dailyP = Math.min(1, Math.max(0, z - 2));
  const dailyDate = resolveDate(focus, dailyDom);
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
    <div ref={wrapRef} className={`cc-wrap${hoverMonth != null ? " cc-clickable" : ""}${overEvent ? " cc-over-event" : ""}`} onMouseMove={drawerId ? undefined : onMove} onMouseLeave={clearHover} onClick={drawerId ? undefined : (e) => { if (hadSelectionAtDownRef.current) return; onClick(e); }}>
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
        <span className="cc-hint">{hint}</span>
        <div className="cc-bar-actions" onClick={(e) => e.stopPropagation()}>
          <NavMenu onGo={goToNow} />
          {year !== currentYear && (
            <button className="cc-action cc-action-accent cc-action-sm" onClick={goToCurrentYear}>Back to Current Year</button>
          )}
          <TagFilterMenu
            tags={tagRows}
            untaggedCount={untaggedCount}
            hidden={tagHidden}
            onToggle={toggleTag}
            onShowAll={showAllTags}
            onHideAll={hideAllTags}
          />
          <EditMenu
            canUndo={history.canUndo} onUndo={() => history.undo()}
            canRedo={history.canRedo} onRedo={() => history.redo()}
            canCut={selectedId != null} onCut={doCut}
            canCopy={selectedId != null} onCopy={doCopy}
            canPaste={clip != null} onPaste={doPaste}
            altTz={altTz} onAltTz={setAltTz}
            mainTz={mainTzSetting} onMainTz={setMainTz}
            dimPast={dimPast} onToggleDimPast={toggleDimPast}
          />
        </div>
      </div>

      {/* solid left gutter — occludes lane content that slides under it (week view) */}
      <div className="cc-gutter" style={{ width: LABEL_W }} />

      <div className="cc-layer">
        {scene.items.map((it) => <ItemView key={it.key} it={it} />)}
        <BandEventsLayer vp={vp} z={z} focus={focus} week={week} scrollY={scrollY} year={year} events={visBand} addEvent={addBandEvent} updateEvent={updateBandEvent} selectedId={selectedId} onSelect={selectEvent} onOpenDetail={openDrawer} onContextMenu={openMenu} editingId={editingId} onEditConsumed={() => setEditingId(null)} monthAnim={monthAnim} dimPast={dimPast} now={now} />
        <PromotedBandLayer vp={vp} z={z} focus={focus} week={week} scrollY={scrollY} year={year} timed={visEvents} deadlines={visDeadlines} bandEvents={visBand} updateTimed={updateEvent} updateDeadline={updateDeadline} selectedId={selectedId} onSelect={selectEvent} onOpenDetail={openDrawer} onContextMenu={openMenu} monthAnim={monthAnim} dimPast={dimPast} now={now} />
        <EventsLayer vp={vp} z={z} focus={focus} week={week} scrollY={scrollY} year={year} events={visEvents} addEvent={addEvent} updateEvent={updateEvent} onEventHover={setOverEvent} onOpenDetail={openDrawer} onContextMenu={openMenu} selectedId={selectedId} onSelect={selectEvent} tlScroll={tlScroll} editingId={editingId} onEditConsumed={() => setEditingId(null)} detailMul={detailMul} monthAnim={monthAnim} dimPast={dimPast} now={now} />
        <DeadlinesLayer vp={vp} z={z} focus={focus} week={week} scrollY={scrollY} tlScroll={tlScroll} year={year} mainTz={mainTz} hover={hover} deadlines={visDeadlines} addDeadline={addDeadline} updateDeadline={updateDeadline} selectedId={selectedId} onSelect={selectEvent} onOpenDetail={openDrawer} onContextMenu={openMenu} detailMul={detailMul} monthAnim={monthAnim} dimPast={dimPast} now={now} />
        <TrackEditor trackNames={trackNames} editTrack={editTrack} vp={vp} z={z} focus={focus} week={week} scrollY={scrollY} monthAnim={monthAnim} />
        {dailyP > 0.001 && (
          <DailyDashboard
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
            first/last day; "ready" at full → release commits the month-jump. */}
        {monthEdge && z > 2.5 && (() => {
          const RC = 2 * Math.PI * 18; // ring circumference (r=18)
          const t = Math.min(1, monthEdge.t);
          return (
            <div
              className={`cc-month-edge${monthEdge.t >= 1 ? " ready" : ""}`}
              style={{
                top: (tl.tlTop + vp.h - 8) / 2,
                ...(monthEdge.dir > 0 ? { right: vp.w - dashLeft + 16 } : { left: LABEL_W + 16 }),
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
        // Badges match how the underlying element renders them: base copies (occ null) show none,
        // occurrence ghosts add the recurrence mark, and band-shaped copies of a timed/deadline
        // event are promotions (the recurrence mark follows the series, like PromotedBandLayer).
        const badgesFor = (b: Spot) => {
          const promoted = b.shape === "band" && !drawerBand;
          return { ai, recurring: isRec && (b.occ != null || promoted), promoted };
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
                    className="cc-ddl-label"
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
                  className={`cc-item cc-tevent ${b.shape === "band" ? "cc-tevent-band " : ""}cc-ev-${evColor}${b.occ === focusedOcc ? " selected" : ""}${clip ? " cc-band-clip" : ""}${timed && short ? " cc-tevent-short" : ""}${timed && tiny ? " cc-tevent-tiny" : ""} cc-spot-dup`}
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
        if (drawerTimed) return <EventDrawer key={drawerId} event={drawerTimed} onChange={updateEvent} onDelete={requestDeleteEvent} onClose={() => setDrawerId(null)} onColorPreview={setPreviewColor} focusOcc={focusedOcc} onGoToFirst={goToFirst} />;
        if (drawerBand) return <BandEventDrawer key={drawerId} event={drawerBand} onChange={updateBandEvent} onDelete={requestDeleteEvent} onClose={() => setDrawerId(null)} onColorPreview={setPreviewColor} focusOcc={focusedOcc} onGoToFirst={goToFirst} />;
        if (drawerDeadline) return <DeadlineDrawer key={drawerId} event={drawerDeadline} mainTz={mainTz} onChange={updateDeadline} onDelete={requestDeleteEvent} onClose={() => setDrawerId(null)} onColorPreview={setPreviewColor} focusOcc={focusedOcc} onGoToFirst={goToFirst} />;
        return null;
      })()}

      {(() => {
        const tev = menu ? events.find((e) => e.id === menu.id) : null;
        const bev = menu ? bandEvents.find((e) => e.id === menu.id) : null;
        const ddl = menu ? deadlines.find((e) => e.id === menu.id) : null;
        const color = tev?.color ?? bev?.color ?? ddl?.color;
        return menu && color != null ? (
          <EventContextMenu
            x={menu.x}
            y={menu.y}
            color={color}
            onColor={(c) => { if (tev) updateEvent(menu.id, { color: c }); else if (bev) updateBandEvent(menu.id, { color: c }); else updateDeadline(menu.id, { color: c }); }}
            onDelete={() => { removeEvent(menu.id); removeBandEvent(menu.id); removeDeadline(menu.id); }}
            recurring={menuRecurring}
            onDeleteThis={menuRecurring && focusedOcc ? () => deleteOccurrence(menu.id, focusedOcc) : undefined}
            onDeleteFuture={menuRecurring && focusedOcc ? () => deleteFuture(menu.id, focusedOcc) : undefined}
            onClose={() => setMenu(null)}
          />
        ) : null;
      })()}

      {(() => {
        const ev = confirmDeleteId
          ? (events.find((e) => e.id === confirmDeleteId) ?? bandEvents.find((e) => e.id === confirmDeleteId) ?? deadlines.find((e) => e.id === confirmDeleteId))
          : null;
        return ev ? (
          <div className="cc-confirm-backdrop" onMouseDown={() => setConfirmDeleteId(null)}>
            <div className="cc-confirm" onMouseDown={(e) => e.stopPropagation()}>
              <div className="cc-confirm-title">Delete this event?</div>
              <div className="cc-confirm-msg">“{ev.title}” will be removed. This can’t be undone.</div>
              <div className="cc-confirm-actions">
                <button className="cc-confirm-cancel" onClick={() => setConfirmDeleteId(null)}>Cancel</button>
                <button className="cc-confirm-delete" onClick={() => { removeEvent(ev.id); removeBandEvent(ev.id); removeDeadline(ev.id); setSelectedId(null); setConfirmDeleteId(null); }}>Delete</button>
              </div>
            </div>
          </div>
        ) : null;
      })()}

      {(() => {
        const ev = recurDelete
          ? (events.find((e) => e.id === recurDelete.id) ?? bandEvents.find((e) => e.id === recurDelete.id) ?? deadlines.find((e) => e.id === recurDelete.id))
          : null;
        const close = () => setRecurDelete(null);
        return recurDelete && ev ? (
          <div className="cc-confirm-backdrop" onMouseDown={close}>
            <div className="cc-confirm cc-confirm-recur" onMouseDown={(e) => e.stopPropagation()}>
              <button className="cc-confirm-x" onClick={close} title="Cancel" aria-label="Cancel"><X size={13} /></button>
              <div className="cc-confirm-title">Delete recurring event</div>
              <div className="cc-confirm-msg">“{ev.title}” repeats. What would you like to delete?</div>
              <div className="cc-confirm-actions cc-confirm-recur-actions">
                <button className="cc-confirm-opt" onClick={() => { deleteOccurrence(recurDelete.id, recurDelete.occ); close(); }}>This event only</button>
                <button className="cc-confirm-opt" onClick={() => { deleteFuture(recurDelete.id, recurDelete.occ); close(); }}>This &amp; all future</button>
                <button className="cc-confirm-opt cc-confirm-delete" onClick={() => { deleteAny(recurDelete.id); setSelectedId(null); close(); }}>All events</button>
              </div>
            </div>
          </div>
        ) : null;
      })()}

      {crossYear && (
        <div className="cc-confirm-backdrop" onMouseDown={() => setCrossYear(null)}>
          <div className="cc-confirm" onMouseDown={(e) => e.stopPropagation()}>
            <div className="cc-confirm-title">Jump to {crossYear.ty}?</div>
            <div className="cc-confirm-msg">The first occurrence of this event is in {crossYear.ty}, a different year from the one you’re viewing. Jump there to see it?</div>
            <div className="cc-confirm-actions">
              <button className="cc-confirm-cancel" onClick={() => setCrossYear(null)}>Cancel</button>
              <button className="cc-confirm-go" onClick={() => { const c = crossYear; setCrossYear(null); runGoToFirst(c.id, c.ty, c.tm, c.tw, c.lvl); }}>Jump to {crossYear.ty}</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
