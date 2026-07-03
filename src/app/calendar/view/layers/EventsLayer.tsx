"use client";

// Timed-event layer: renders + handles drag/resize/create/collision-layout for events in the week/day timeline.

import { useRef, useState } from "react";
import EventBadges from "../events/EventBadges";
import { Vp } from "../../geometry/types";
import { TimedEvent, snapHour, fmtRange } from "../../model/types/eventTypes";
import { timelineInfo, eventRect, layoutDay, pointToSlot, eventTextLayout, incomingDetailReveal, relDomOf, EventRect, EventLayout, LayoutItem } from "../../geometry/eventGeom";
import { occurrenceDates, occKey, occDate, baseHidden } from "../../model/occurrences";
import { resolveDate, momentIsPast } from "../../util/dates";
import { PAST_DIM } from "../../geometry/constants";
import { LABEL_W } from "../../geometry/constants";
import { dailyFade, type MonthAnim } from "../../geometry/frames";
import TimedEventView from "../events/TimedEventView";

interface Props {
  vp: Vp;
  z: number;
  focus: number;
  week: number;
  scrollY: number;
  year: number;
  events: TimedEvent[];
  addEvent: (e: Omit<TimedEvent, "id">) => TimedEvent;
  updateEvent: (id: string, patch: Partial<TimedEvent>) => void;
  onEventHover: (over: boolean) => void;
  onOpenDetail: (id: string, occ?: string | null) => void;
  onContextMenu: (id: string, x: number, y: number, occ?: string | null) => void;
  selectedId: string | null;
  focusedOcc: string | null; // the focused occurrence ("YYYY-MM-DD", null = base) → the one instance that gets the standout ring
  onSelect: (id: string | null, occ?: string | null, space?: "timed" | "allday") => void;
  tlScroll: number;
  editingId: string | null;
  onEditConsumed: () => void;
  detailMul?: number; // timeline opacity multiplier during month↕month paging (outgoing month)
  dimPast?: boolean; // "dim past events" view toggle
  now?: number;      // ms timestamp (ticks each minute) → decides what's past
  monthAnim?: MonthAnim | null; // active page-turn → render the incoming month's events too
}

const MIN = 0.25; // 15-minute minimum duration / gap

// Per-day overlap layout for everything drawn in the displayed year — base events AND each
// recurrence occurrence ("ghost"). Occurrences are packed as their own instances (keyed by
// occKey) on the day they land, so a ghost and a normal event that overlap get offset just
// like two normal events would. The layout map is keyed by ev.id for bases and occKey(id, o)
// for ghosts; each renderer looks up its own key.
function buildLayout(events: TimedEvent[], year: number): Map<string, EventLayout> {
  const byDay = new Map<string, LayoutItem[]>();
  const push = (month: number, day: number, item: LayoutItem) => {
    const k = `${month}-${day}`;
    const arr = byDay.get(k);
    if (arr) arr.push(item); else byDay.set(k, [item]);
  };
  for (const ev of events) {
    // the base occurrence, unless it's individually hidden (exdate / past `until`)
    if (ev.year === year && !baseHidden(occDate({ year: ev.year, month: ev.month, day: ev.day }), ev.repeat)) {
      push(ev.month, ev.day, { id: ev.id, startHour: ev.startHour, endHour: ev.endHour });
    }
    // recurrence ghosts on their occurrence days (occurrenceDates already drops exdates/until)
    if (ev.repeat && ev.repeat.kind !== "none") {
      for (const o of occurrenceDates({ year: ev.year, month: ev.month, day: ev.day }, ev.repeat, year)) {
        push(o.month, o.day, { id: occKey(ev.id, o), startHour: ev.startHour, endHour: ev.endHour });
      }
    }
  }
  const out = new Map<string, EventLayout>();
  for (const group of byDay.values()) layoutDay(group).forEach((v, id) => out.set(id, v));
  return out;
}

export default function EventsLayer({ vp, z, focus, week, scrollY, year, events, addEvent, updateEvent, onEventHover, onOpenDetail, onContextMenu, selectedId, focusedOcc, onSelect, tlScroll, editingId, onEditConsumed, detailMul = 1, dimPast = false, now = 0, monthAnim = null }: Props) {
  const layerRef = useRef<HTMLDivElement>(null);
  // While resizing, keep the layout frozen so growing an event doesn't reorder it;
  // recompute (and briefly enable CSS transitions to animate the reflow) on release.
  const [resizing, setResizing] = useState(false);
  const [movingId, setMovingId] = useState<string | null>(null);
  const movedRef = useRef(false); // a real move happened → suppress the trailing click
  const createdRef = useRef(false); // a create-drag happened → suppress only that trailing click (plain clicks pass through to navigate)
  const [animating, setAnimating] = useState(false);
  const frozenRef = useRef<Map<string, EventLayout> | null>(null);
  const animTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const triggerAnimate = () => {
    setAnimating(true);
    if (animTimer.current) clearTimeout(animTimer.current);
    animTimer.current = setTimeout(() => setAnimating(false), 220);
  };
  const hoverIdRef = useRef<string | null>(null);
  const setHover = (id: string, on: boolean) => {
    if (on) hoverIdRef.current = id;
    else if (hoverIdRef.current === id) hoverIdRef.current = null;
    onEventHover(hoverIdRef.current != null);
  };
  const tl = timelineInfo(z, focus, week, vp, scrollY, tlScroll, detailMul);
  const interactive = z >= 1.5; // week view → create / resize enabled
  // Daily view (z→3): fade events on days other than the chosen one. `reveal` already carries the
  // timeline opacity; this folds in the per-day fade so only the chosen day's events remain.
  const dfade = (month: number, day: number) => dailyFade(relDomOf(focus, month, day) ?? -999, z);
  // dim-past multiplier: 0.4 for an occurrence whose END time has elapsed, else 1 (folds into opacity)
  const pdim = (oy: number, om: number, od: number, endHour: number) => (dimPast && momentIsPast(oy, om, od, endHour, now) ? PAST_DIM : 1);
  const [draft, setDraft] = useState<{ dom: number; start: number; end: number } | null>(null);
  const draftRef = useRef<{ dom: number; start: number; end: number } | null>(null);
  const setDraftBoth = (d: { dom: number; start: number; end: number } | null) => { draftRef.current = d; setDraft(d); };

  const localY = (clientY: number) => {
    const r = layerRef.current!.getBoundingClientRect();
    return Math.max(0, Math.min(24, (clientY - r.top - tl.tlTop + tl.scroll) / tl.hourH));
  };

  // ── Drag on empty timeline → create (30-min snap) ──
  const onCreateDown = (e: React.MouseEvent) => {
    if (!interactive || tl.hourH <= 0 || e.button !== 0) return;
    const r = layerRef.current!.getBoundingClientRect();
    const slot = pointToSlot(e.clientX - r.left, e.clientY - r.top, tl);
    if (slot.dom == null) return;
    e.preventDefault();
    e.stopPropagation();
    const dom = slot.dom;
    const start = snapHour(slot.hourFrac, 30);
    const y0 = e.clientY;
    let moved = false;

    const onMove = (me: MouseEvent) => {
      if (Math.abs(me.clientY - y0) > 3) moved = true;
      if (!moved) return;
      const end = snapHour(localY(me.clientY), 30);
      const a = Math.min(start, end), b = Math.max(start, end);
      setDraftBoth({ dom, start: a, end: Math.max(b, a + 0.5) });
    };
    const onUp = () => {
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
      const d = draftRef.current;
      if (d && moved) {
        const date = resolveDate(focus, d.dom);
        if (date) { addEvent({ year, month: date.month, day: date.day, startHour: d.start, endHour: d.end, title: "Event", color: "default" }); triggerAnimate(); }
        createdRef.current = true; // suppress the trailing click (so it doesn't also navigate)
        setTimeout(() => { createdRef.current = false; }, 0);
      }
      setDraftBoth(null);
    };
    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
  };

  // ── Drag a top/bottom handle → resize (15-min snap) ──
  const onResizeStart = (id: string, edge: "top" | "bottom", e: React.MouseEvent) => {
    if (tl.hourH <= 0) return;
    e.preventDefault();
    e.stopPropagation();
    const ev = events.find((x) => x.id === id);
    if (!ev) return;
    // freeze the layout for the duration of the drag (no transitions while dragging)
    if (animTimer.current) clearTimeout(animTimer.current);
    setAnimating(false);
    frozenRef.current = buildLayout(events, year);
    setResizing(true);
    const onMove = (me: MouseEvent) => {
      const snapped = snapHour(localY(me.clientY), 15);
      if (edge === "top") updateEvent(id, { startHour: Math.min(snapped, ev.endHour - MIN) });
      else updateEvent(id, { endHour: Math.max(snapped, ev.startHour + MIN) });
    };
    const onUp = () => {
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
      frozenRef.current = null;
      setResizing(false);
      triggerAnimate(); // animate the reflow into the final layout
    };
    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
  };

  // ── Drag the event body → move across time + days (15-min snap), preserving duration ──
  const onMoveStart = (id: string, e: React.MouseEvent) => {
    if (!interactive || tl.hourH <= 0 || e.button !== 0) return;
    e.stopPropagation();
    const ev = events.find((x) => x.id === id);
    if (!ev) return;
    const r0 = layerRef.current!.getBoundingClientRect();
    const grabOffset = (e.clientY - r0.top - tl.tlTop + tl.scroll) / tl.hourH - ev.startHour; // grab point ↓ from top
    const duration = ev.endHour - ev.startHour;
    const x0 = e.clientX, y0 = e.clientY;

    const onMove = (me: MouseEvent) => {
      if (!movedRef.current && Math.abs(me.clientX - x0) < 4 && Math.abs(me.clientY - y0) < 4) return;
      if (!movedRef.current) { // first real movement → freeze layout + lift
        movedRef.current = true;
        if (animTimer.current) clearTimeout(animTimer.current);
        setAnimating(false);
        frozenRef.current = buildLayout(events, year);
        setMovingId(id);
      }
      const r = layerRef.current!.getBoundingClientRect();
      const mouseHour = (me.clientY - r.top - tl.tlTop + tl.scroll) / tl.hourH;
      const start = Math.max(0, Math.min(24 - duration, snapHour(mouseHour - grabOffset, 15)));
      const patch: Partial<TimedEvent> = { startHour: start, endHour: start + duration };
      const slot = pointToSlot(me.clientX - r.left, me.clientY - r.top, tl); // day column under cursor
      if (slot.dom != null) {
        const date = resolveDate(focus, slot.dom);
        if (date) { patch.month = date.month; patch.day = date.day; }
      }
      updateEvent(id, patch);
    };
    const onUp = () => {
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
      if (movedRef.current) {
        frozenRef.current = null;
        setMovingId(null);
        triggerAnimate();
        setTimeout(() => { movedRef.current = false; }, 0); // reset after the trailing click
      }
    };
    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
  };

  // Overlap layout — frozen to its snapshot while a resize OR move drag is in progress.
  const layoutMap = tl.reveal > 0.02
    ? ((resizing || movingId != null) && frozenRef.current ? frozenRef.current : buildLayout(events, year))
    : new Map<string, EventLayout>();

  const rects = tl.reveal > 0.02
    ? events
        .filter((ev) => ev.year === year && !baseHidden(occDate({ year: ev.year, month: ev.month, day: ev.day }), ev.repeat))
        .map((ev) => ({ ev, rect: eventRect(ev, focus, tl, vp, layoutMap.get(ev.id)) }))
        .filter((x): x is { ev: TimedEvent; rect: EventRect } => x.rect != null)
        // deeper (more-indented) events render later → stack on top of the ones below them
        .sort((a, b) => (layoutMap.get(a.ev.id)?.level ?? 0) - (layoutMap.get(b.ev.id)?.level ?? 0))
    : [];

  // Recurrence: read-only ghost copies of each repeating event on its occurrence days.
  // No year filter — a cross-year base (loaded from an earlier year) projects ghosts into
  // this year; occurrenceDates windows to `year`, so non-reaching events expand to nothing.
  const ghosts = tl.reveal > 0.02
    ? events.filter((ev) => ev.repeat && ev.repeat.kind !== "none")
        .flatMap((ev) => occurrenceDates({ year: ev.year, month: ev.month, day: ev.day }, ev.repeat, year)
          .map((o) => ({ ev, o, rect: eventRect({ month: o.month, day: o.day, startHour: ev.startHour, endHour: ev.endHour }, focus, tl, vp, layoutMap.get(occKey(ev.id, o))) }))
          .filter((x): x is { ev: TimedEvent; o: { year: number; month: number; day: number }; rect: EventRect } => x.rect != null))
    : [];

  // Page-turn: the INCOMING month's events, read-only, cross-fading in at the same resting timeline
  // position (tl never moves during paging) so they appear as the band approaches. `to`'s events are
  // placed as if it were the focused month (eventRect(…, to, …)); opacity rides incomingDetailReveal.
  const inTo = monthAnim ? focus + monthAnim.dir : -1;
  const inReveal = monthAnim && inTo >= 0 && inTo <= 11 ? incomingDetailReveal(monthAnim.p) : 0;
  const inLayout = inReveal > 0.02 ? buildLayout(events, year) : null;
  const inRects = inReveal > 0.02
    ? events
        .filter((ev) => ev.year === year && ev.month === inTo && !baseHidden(occDate({ year: ev.year, month: ev.month, day: ev.day }), ev.repeat))
        .map((ev) => ({ ev, rect: eventRect(ev, inTo, tl, vp, inLayout!.get(ev.id)) }))
        .filter((x): x is { ev: TimedEvent; rect: EventRect } => x.rect != null)
    : [];
  const inGhosts = inReveal > 0.02
    ? events.filter((ev) => ev.repeat && ev.repeat.kind !== "none")
        .flatMap((ev) => occurrenceDates({ year: ev.year, month: ev.month, day: ev.day }, ev.repeat, year)
          .filter((o) => o.month === inTo)
          .map((o) => ({ ev, o, rect: eventRect({ month: o.month, day: o.day, startHour: ev.startHour, endHour: ev.endHour }, inTo, tl, vp, inLayout!.get(occKey(ev.id, o))) }))
          .filter((x): x is { ev: TimedEvent; o: { year: number; month: number; day: number }; rect: EventRect } => x.rect != null))
    : [];

  return (
    <div ref={layerRef} className={`cc-events${animating ? " cc-events-animating" : ""}`}>
      {interactive && tl.hourH > 0 && (
        <div
          className="cc-create-surface"
          style={{ left: LABEL_W, top: tl.tlTop, width: vp.w - LABEL_W, height: tl.tlBottom - tl.tlTop }}
          onMouseDown={onCreateDown}
          onClick={(e) => { if (createdRef.current) e.stopPropagation(); }} // let a plain click through (→ navigate to the day)
        />
      )}
      {/* clip+scroll the hourly content to the visible timeline window */}
      {tl.hourH > 0 && (
        <div className="cc-events-clip" style={{ top: tl.tlTop, width: vp.w, height: tl.viewH }}>
          <div className="cc-events-scroll" style={{ transform: `translateY(${-tl.scroll}px)` }}>
            {ghosts.map(({ ev, o, rect }) => {
              const { tiny, short, titleLines } = eventTextLayout(rect.h);
              return (
              <div
                key={occKey(ev.id, o)}
                data-ev-id={ev.id}
                data-occ={occDate(o)}
                className={`cc-item cc-tevent cc-ev-${ev.color} cc-ghost${ev.id === selectedId ? " selected" : ""}${ev.id === selectedId && focusedOcc === occDate(o) ? " cc-focused-occ" : ""}${short ? " cc-tevent-short" : ""}${tiny ? " cc-tevent-tiny" : ""}`}
                style={{ transform: `translate(${rect.x}px, ${rect.y}px)`, width: rect.w, height: rect.h, opacity: tl.reveal * dfade(o.month, o.day) * pdim(o.year, o.month, o.day, ev.endHour), pointerEvents: interactive ? "auto" : "none" }}
                onClick={(e) => { e.stopPropagation(); onSelect(ev.id, occDate(o), "timed"); }}
                onDoubleClick={(e) => { e.stopPropagation(); onOpenDetail(ev.id, occDate(o)); }}
                onMouseEnter={() => setHover(occKey(ev.id, o), true)}
                onMouseLeave={() => setHover(occKey(ev.id, o), false)}
                onContextMenu={(e) => { e.preventDefault(); e.stopPropagation(); const r = e.currentTarget.getBoundingClientRect(); onContextMenu(ev.id, r.left + r.width / 2, r.top, occDate(o)); }}
              >
                <div className="cc-tevent-inner">
                  {tl.wide && <div className="cc-tevent-title" style={{ WebkitLineClamp: titleLines } as React.CSSProperties}>{ev.title}</div>}
                  {tl.wide && !short && <div className="cc-tevent-time">{fmtRange(ev.startHour, ev.endHour)}</div>}
                </div>
                <EventBadges ai={ev.createdByAI} imported={ev.imported} recurring />
              </div>
              );
            })}
            {rects.map(({ ev, rect }) => (
              <TimedEventView
                key={ev.id}
                ev={ev}
                rect={rect}
                wide={tl.wide}
                reveal={tl.reveal * dfade(ev.month, ev.day) * pdim(ev.year, ev.month, ev.day, ev.endHour)}
                interactive={interactive}
                moving={ev.id === movingId}
                movedRef={movedRef}
                onResizeStart={onResizeStart}
                onMoveStart={onMoveStart}
                onTitleCommit={(id, title) => updateEvent(id, { title })}
                onHover={(on) => setHover(ev.id, on)}
                onOpenDetail={onOpenDetail}
                onContextMenu={onContextMenu}
                selected={ev.id === selectedId}
                focused={ev.id === selectedId && focusedOcc == null}
                onSelect={(id) => onSelect(id, null, "timed")}
                requestEdit={editingId === ev.id}
                onEditConsumed={onEditConsumed}
              />
            ))}
            {/* incoming month's events (read-only) — cross-fade in during a page-turn */}
            {[...inGhosts.map((g) => ({ key: occKey(g.ev.id, g.o), ev: g.ev, rect: g.rect, recurring: true })),
              ...inRects.map((r) => ({ key: `in-${r.ev.id}`, ev: r.ev, rect: r.rect, recurring: false }))].map(({ key, ev, rect, recurring }) => {
              const { tiny, short, titleLines } = eventTextLayout(rect.h);
              return (
                <div
                  key={key}
                  className={`cc-item cc-tevent cc-ev-${ev.color}${recurring ? " cc-ghost" : ""}${short ? " cc-tevent-short" : ""}${tiny ? " cc-tevent-tiny" : ""}`}
                  style={{ transform: `translate(${rect.x}px, ${rect.y}px)`, width: rect.w, height: rect.h, opacity: inReveal, pointerEvents: "none" }}
                >
                  <div className="cc-tevent-inner">
                    {tl.wide && <div className="cc-tevent-title" style={{ WebkitLineClamp: titleLines } as React.CSSProperties}>{ev.title}</div>}
                    {tl.wide && !short && <div className="cc-tevent-time">{fmtRange(ev.startHour, ev.endHour)}</div>}
                  </div>
                  <EventBadges ai={ev.createdByAI} imported={ev.imported} recurring={recurring} />
                </div>
              );
            })}
            {draft && (
              <div
                className="cc-tevent-preview"
                style={{
                  transform: `translate(${tl.x0 + (draft.dom - 1) * tl.colW + 2}px, ${draft.start * tl.hourH}px)`,
                  width: Math.max(3, tl.colW - 4),
                  height: Math.max(3, (draft.end - draft.start) * tl.hourH),
                }}
              />
            )}
          </div>
        </div>
      )}
    </div>
  );
}
