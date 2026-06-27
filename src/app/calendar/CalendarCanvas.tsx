"use client";

import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { buildScene } from "./scene";
import { fmtRange, TimedEvent } from "./eventTypes";
import { LABEL_W } from "./constants";
import { MONTH_LONG, weekStartDOM, resolveDate } from "./dates";
import { COMMON_TZS, tzDeltaHours, tzAbbrev } from "./timezones";
import { timelineInfo } from "./eventGeom";
import TimelineScrollbar from "./TimelineScrollbar";
import { useCalendarInteractions } from "./useCalendarInteractions";
import { useCalendarSettings } from "./useCalendarSettings";
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
import BandEventsLayer from "./BandEventsLayer";
import DeadlinesLayer from "./DeadlinesLayer";
import { deadlineTimeLabel } from "./deadlineFormat";
import { NO_REPEAT, Repeat } from "@/lib/calendar/api";

export default function CalendarCanvas() {
  const { wrapRef, vp, z, focus, week, scrollY, tlScroll, setTlScroll, setWeekHourH, hoverMonth, hoverWeek, hover, now, year, currentYear, selectYear, goToCurrentYear, goToCurrentWeek, goToMonth, tweenTo, onMove, onClick, clearHover } =
    useCalendarInteractions();
  const { trackNames, editTrack, mainTz, altTz, setAltTz } = useCalendarSettings();
  const { events, addEvent, updateEvent, removeEvent } = useEvents(year);
  const { events: bandEvents, addEvent: addBandEvent, updateEvent: updateBandEvent, removeEvent: removeBandEvent } = useBandEvents(year);
  const { deadlines, addDeadline, updateDeadline, removeDeadline } = useDeadlines(year);

  const [yearMenuOpen, setYearMenuOpen] = useState(false);
  const [tzMenuOpen, setTzMenuOpen] = useState(false);
  const [overEvent, setOverEvent] = useState(false);
  const [drawerId, setDrawerId] = useState<string | null>(null);
  const [previewColor, setPreviewColor] = useState<string | null>(null); // hover a swatch → preview on the spotlight copy
  const [menu, setMenu] = useState<{ id: string; x: number; y: number } | null>(null);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [focusedOcc, setFocusedOcc] = useState<string | null>(null); // the clicked occurrence date "YYYY-MM-DD" (null = the base)
  const [confirmDeleteId, setConfirmDeleteId] = useState<string | null>(null);
  const yearWrapRef = useRef<HTMLDivElement>(null);
  const tzWrapRef = useRef<HTMLDivElement>(null);

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
  const goToFirst = () => { if (drawerEv) { setFocusedOcc(null); goToMonth(drawerEv.month); } };
  const menuRepeat = menu ? repeatOf(menu.id) : null;
  const menuRecurring = !!menuRepeat && menuRepeat.kind !== "none";
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
  // Deselect the selected event when clicking anywhere that isn't an event/drawer/menu.
  useEffect(() => {
    if (selectedId == null) return;
    const onDown = (e: MouseEvent) => {
      const t = e.target as HTMLElement;
      if (!t.closest(".cc-tevent, .cc-drawer, .cc-sticker, .cc-ddl-label, .cc-ddl-add")) setSelectedId(null);
    };
    document.addEventListener("mousedown", onDown, true); // capture → robust to stopPropagation
    return () => document.removeEventListener("mousedown", onDown, true);
  }, [selectedId]);

  // Keyboard: Delete/Backspace on a selected event → confirm (or delete outright if it's
  // still the untouched "Event" placeholder). Enter/Esc resolve the confirm dialog.
  const keyHandlerRef = useRef<(e: KeyboardEvent) => void>(() => {});
  keyHandlerRef.current = (e: KeyboardEvent) => {
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
  // Close the alt-timezone dropdown on any click outside it.
  useEffect(() => {
    if (!tzMenuOpen) return;
    const onDown = (e: MouseEvent) => {
      if (tzWrapRef.current && !tzWrapRef.current.contains(e.target as Node)) setTzMenuOpen(false);
    };
    document.addEventListener("mousedown", onDown);
    return () => document.removeEventListener("mousedown", onDown);
  }, [tzMenuOpen]);

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
    <div ref={wrapRef} className={`cc-wrap${hoverMonth != null ? " cc-clickable" : ""}${overEvent ? " cc-over-event" : ""}`} onMouseMove={drawerId ? undefined : onMove} onMouseLeave={clearHover} onClick={drawerId ? undefined : onClick}>
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
          <button className="cc-action" onClick={goToCurrentWeek}>Current Week</button>
          {year !== currentYear && (
            <button className="cc-action cc-action-accent" onClick={goToCurrentYear}>Back to Current Year</button>
          )}
          <div className="cc-year-wrap" ref={tzWrapRef}>
            <button className="cc-action" onClick={() => setTzMenuOpen((o) => !o)}>
              {COMMON_TZS.find((t) => t.id === altTz)?.label ?? "Alt Timezone"}<span className="cc-caret">▾</span>
            </button>
            {tzMenuOpen && (
              <div className="cc-year-menu cc-tz-menu" role="listbox">
                <button className={`cc-year-opt${!altTz ? " sel" : ""}`} onClick={() => { setAltTz(null); setTzMenuOpen(false); }}>None</button>
                {COMMON_TZS.map((t) => (
                  <button
                    key={t.id}
                    className={`cc-year-opt${altTz === t.id ? " sel" : ""}`}
                    onClick={() => { setAltTz(t.id); setTzMenuOpen(false); }}
                  >
                    {t.label}
                  </button>
                ))}
              </div>
            )}
          </div>
        </div>
      </div>

      {/* solid left gutter — occludes lane content that slides under it (week view) */}
      <div className="cc-gutter" style={{ width: LABEL_W }} />

      <div className="cc-layer">
        {scene.items.map((it) => <ItemView key={it.key} it={it} />)}
        <BandEventsLayer vp={vp} z={z} focus={focus} week={week} scrollY={scrollY} year={year} events={bandEvents} addEvent={addBandEvent} updateEvent={updateBandEvent} selectedId={selectedId} onSelect={selectEvent} onOpenDetail={openDrawer} onContextMenu={openMenu} />
        <EventsLayer vp={vp} z={z} focus={focus} week={week} scrollY={scrollY} year={year} events={events} addEvent={addEvent} updateEvent={updateEvent} onEventHover={setOverEvent} onOpenDetail={openDrawer} onContextMenu={openMenu} selectedId={selectedId} onSelect={selectEvent} tlScroll={tlScroll} />
        <DeadlinesLayer vp={vp} z={z} focus={focus} week={week} scrollY={scrollY} tlScroll={tlScroll} year={year} mainTz={mainTz} hover={hover} deadlines={deadlines} addDeadline={addDeadline} updateDeadline={updateDeadline} selectedId={selectedId} onSelect={selectEvent} onOpenDetail={openDrawer} onContextMenu={openMenu} />
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
