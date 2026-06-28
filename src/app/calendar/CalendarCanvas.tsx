"use client";

import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { buildScene } from "./scene";
import { fmtRange, snapHour, TimedEvent } from "./eventTypes";
import { LABEL_W } from "./constants";
import { MONTH_LONG, weekStartDOM, resolveDate } from "./dates";
import { tzDeltaHours, tzAbbrev } from "./timezones";
import { timelineInfo, pointToSlot } from "./eventGeom";
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
import TagFilterMenu, { TagRow, UNTAGGED } from "./TagFilterMenu";
import BandEventsLayer from "./BandEventsLayer";
import DeadlinesLayer from "./DeadlinesLayer";
import { deadlineTimeLabel } from "./deadlineFormat";
import { NO_REPEAT, Repeat } from "@/lib/calendar/api";

export default function CalendarCanvas() {
  const { wrapRef, vp, z, focus, week, scrollY, tlScroll, setTlScroll, setWeekHourH, hoverMonth, hoverWeek, hover, now, year, currentYear, selectYear, goToCurrentYear, goToCurrentWeek, goToMonth, tweenTo, onMove, onClick, clearHover } =
    useCalendarInteractions();
  const { trackNames, editTrack, mainTz, altTz, setAltTz } = useCalendarSettings(year);
  const history = useHistory();
  const { events, addEvent, updateEvent, removeEvent } = useEvents(year, history);
  const { events: bandEvents, addEvent: addBandEvent, updateEvent: updateBandEvent, removeEvent: removeBandEvent } = useBandEvents(year, history);
  const { deadlines, addDeadline, updateDeadline, removeDeadline } = useDeadlines(year, history);

  // Each year loads its own events; entries referencing other years would be stale.
  // Depend on the stable `clear` only — `history` identity flips when canUndo/canRedo
  // change, which must NOT re-trigger a wipe.
  const clearHistory = history.clear;
  useEffect(() => { clearHistory(); }, [year, clearHistory]);

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
  // True when an event was selected at the moment a click began — that click only clears the
  // selection, so it must NOT also navigate (open a month/week). Snapshotted at mousedown
  // (capture phase, before the deselect listener runs) so the click handler can read it.
  const hadSelectionAtDownRef = useRef(false);
  const [focusedOcc, setFocusedOcc] = useState<string | null>(null); // the clicked occurrence date "YYYY-MM-DD" (null = the base)
  const [confirmDeleteId, setConfirmDeleteId] = useState<string | null>(null);
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
  const openDrawer = (id: string, occ?: string | null) => { setDrawerId(id); setFocusedOcc(occ ?? null); };
  const openMenu = (id: string, x: number, y: number, occ?: string | null) => { setMenu({ id, x, y }); setFocusedOcc(occ ?? null); };
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
  const drawerIsBand = drawerBand != null;
  const drawerIsDeadline = drawerDeadline != null;
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
  // "Go to first occurrence": close the drawer (leaving it open over a now-navigated calendar
  // strands the UI — the canvas handlers stay disabled and the spotlight goes stale), then
  // jump to the base event's month with it selected.
  const goToFirst = () => {
    if (!drawerEv) return;
    const ev = drawerEv;
    setDrawerId(null);
    setSelectedId(ev.id);
    setFocusedOcc(null);
    goToMonth(ev.month);
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
  type Spot = { left: number; top: number; width: number; height: number; occ: string | null };
  const [spotBoxes, setSpotBoxes] = useState<Spot[]>([]);
  const [spotLines, setSpotLines] = useState<Spot[]>([]); // deadline lines
  useLayoutEffect(() => {
    const wrap = wrapRef.current;
    if (!drawerId || !wrap) { setSpotBoxes([]); setSpotLines([]); return; }
    const wr = wrap.getBoundingClientRect();
    const rel = (el: Element): Spot => {
      const r = el.getBoundingClientRect();
      return { left: r.left - wr.left, top: r.top - wr.top, width: r.width, height: r.height, occ: (el as HTMLElement).getAttribute("data-occ") };
    };
    setSpotBoxes([...wrap.querySelectorAll(`[data-ev-id="${drawerId}"]`)].map(rel));
    setSpotLines(drawerIsDeadline ? [...wrap.querySelectorAll(`[data-ev-line-id="${drawerId}"]`)].map(rel) : []);
  }, [drawerId, drawerSig, vp.w, vp.h, wrapRef, drawerIsDeadline, focusedOcc]);
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
  const keyHandlerRef = useRef<(e: KeyboardEvent) => void>(() => {});
  keyHandlerRef.current = (e: KeyboardEvent) => {
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
    if (selectedId == null || (e.key !== "Delete" && e.key !== "Backspace")) return;
    const t = e.target as HTMLElement | null;
    if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) return; // typing
    e.preventDefault();
    const ev = events.find((x) => x.id === selectedId) ?? bandEvents.find((x) => x.id === selectedId) ?? deadlines.find((x) => x.id === selectedId);
    if (!ev) return;
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

  const scene = buildScene(z, focus, week, vp, scrollY, hover, now, year, altDelta, altLabel, tlScroll);
  const tl = timelineInfo(z, focus, week, vp, scrollY, tlScroll);
  const showScrollbar = z >= 1.5 && tl.maxScroll > 0; // week view, day taller than the viewport
  const level = z < 0.5 ? 0 : z < 1.5 ? 1 : 2;
  const hint =
    level === 0 ? "click a month to open it · or pinch to zoom"
    : level === 1 ? (hoverWeek != null ? "click to open week · or pinch to zoom" : "hover a week · pinch to zoom")
    : "scroll sideways to change week · pinch to zoom out";

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
              <button className={`cc-crumb${level === 1 ? " current" : ""}`} onClick={() => tweenTo(1)}>{MONTH_LONG[focus]}</button>
            </>
          )}
          {level >= 2 && (
            <>
              <span className="cc-sep">›</span>
              <button className="cc-crumb current" onClick={() => tweenTo(2)}>Week {Math.round(week) + 1}</button>
            </>
          )}
        </div>
        <span className="cc-hint">{hint}</span>
        <div className="cc-bar-actions" onClick={(e) => e.stopPropagation()}>
          <button className="cc-action cc-action-sm cc-action-plain" onClick={goToCurrentWeek} title="Jump to the current week">Now</button>
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
          />
        </div>
      </div>

      {/* solid left gutter — occludes lane content that slides under it (week view) */}
      <div className="cc-gutter" style={{ width: LABEL_W }} />

      <div className="cc-layer">
        {scene.items.map((it) => <ItemView key={it.key} it={it} />)}
        <BandEventsLayer vp={vp} z={z} focus={focus} week={week} scrollY={scrollY} year={year} events={visBand} addEvent={addBandEvent} updateEvent={updateBandEvent} selectedId={selectedId} onSelect={selectEvent} onOpenDetail={openDrawer} onContextMenu={openMenu} />
        <EventsLayer vp={vp} z={z} focus={focus} week={week} scrollY={scrollY} year={year} events={visEvents} addEvent={addEvent} updateEvent={updateEvent} onEventHover={setOverEvent} onOpenDetail={openDrawer} onContextMenu={openMenu} selectedId={selectedId} onSelect={selectEvent} tlScroll={tlScroll} />
        <DeadlinesLayer vp={vp} z={z} focus={focus} week={week} scrollY={scrollY} tlScroll={tlScroll} year={year} mainTz={mainTz} hover={hover} deadlines={visDeadlines} addDeadline={addDeadline} updateDeadline={updateDeadline} selectedId={selectedId} onSelect={selectEvent} onOpenDetail={openDrawer} onContextMenu={openMenu} />
        <TrackEditor trackNames={trackNames} editTrack={editTrack} vp={vp} z={z} focus={focus} week={week} scrollY={scrollY} />
      </div>

      {showScrollbar && (
        <TimelineScrollbar vp={vp} tlTop={tl.tlTop} viewH={tl.viewH} hourH={tl.hourH} scroll={tl.scroll} setScroll={setTlScroll} setHourH={setWeekHourH} />
      )}

      {/* Drawer spotlight: dim+blur veil over the calendar (click closes), with bright
          duplicates of the edited event — and all its visible recurrence occurrences —
          lifted above it. The base copy keeps the "selected" style; ghosts are plain. */}
      {drawerId && spotBoxes.length > 0 && drawerEv && (() => {
        const evColor = previewColor ?? drawerEv.color;
        return (
          <>
            <div className="cc-spot-mask" onMouseDown={() => setDrawerId(null)} onClick={(e) => e.stopPropagation()} />
            {drawerIsDeadline ? (
              <>
                {spotLines.map((b, i) => (
                  <div key={`l${i}`} className={`cc-ddl cc-ev-${evColor}${b.occ === focusedOcc ? " selected" : ""}`} style={{ position: "absolute", inset: 0, zIndex: 91, pointerEvents: "none" }}>
                    <div className="cc-ddl-line" style={{ position: "absolute", left: b.left, top: b.top, width: b.width, transform: "none" }} />
                  </div>
                ))}
                {spotBoxes.map((b, i) => (
                  <div key={`b${i}`} className={`cc-ddl cc-ev-${evColor}${b.occ === focusedOcc ? " selected" : ""}`} style={{ position: "absolute", inset: 0, zIndex: 91, pointerEvents: "none" }}>
                    <div
                      className="cc-ddl-label"
                      style={{ position: "absolute", left: b.left, top: b.top, width: b.width, height: b.height, transform: "none", pointerEvents: b.occ === focusedOcc ? "auto" : "none" }}
                      onMouseDown={(e) => e.stopPropagation()}
                    >
                      <span className="cc-ddl-title">{drawerEv.title}</span>
                      <span className="cc-ddl-time">{deadlineTimeLabel(drawerDeadline!, mainTz)}</span>
                    </div>
                  </div>
                ))}
              </>
            ) : (
              spotBoxes.map((b, i) => (
                <div
                  key={i}
                  className={`cc-item cc-tevent ${drawerIsBand ? "cc-tevent-band " : ""}cc-ev-${evColor}${b.occ === focusedOcc ? " selected" : ""} cc-spot-dup`}
                  style={{ left: b.left, top: b.top, width: b.width, height: b.height, zIndex: 91, pointerEvents: b.occ === focusedOcc ? "auto" : "none" }}
                  onMouseDown={(e) => e.stopPropagation()}
                >
                  <div className="cc-tevent-inner">
                    <div className="cc-tevent-title">{drawerEv.title}</div>
                    {!drawerIsBand && <div className="cc-tevent-time">{fmtRange((drawerEv as TimedEvent).startHour, (drawerEv as TimedEvent).endHour)}</div>}
                  </div>
                </div>
              ))
            )}
          </>
        );
      })()}

      {(() => {
        if (!drawerId) return null;
        if (drawerTimed) return <EventDrawer event={drawerTimed} onChange={updateEvent} onDelete={removeEvent} onClose={() => setDrawerId(null)} onColorPreview={setPreviewColor} focusOcc={focusedOcc} onGoToFirst={goToFirst} />;
        if (drawerBand) return <BandEventDrawer event={drawerBand} onChange={updateBandEvent} onDelete={removeBandEvent} onClose={() => setDrawerId(null)} onColorPreview={setPreviewColor} focusOcc={focusedOcc} onGoToFirst={goToFirst} />;
        if (drawerDeadline) return <DeadlineDrawer event={drawerDeadline} mainTz={mainTz} onChange={updateDeadline} onDelete={removeDeadline} onClose={() => setDrawerId(null)} onColorPreview={setPreviewColor} focusOcc={focusedOcc} onGoToFirst={goToFirst} />;
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
    </div>
  );
}
