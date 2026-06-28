"use client";

import { useRef, useState } from "react";
import { RotateCw } from "lucide-react";
import { Vp } from "./types";
import { TimedEvent, snapHour, fmtRange } from "./eventTypes";
import { timelineInfo, eventRect, layoutDay, pointToSlot, EventRect, EventLayout } from "./eventGeom";
import { occurrenceDates, occKey, occDate } from "./occurrences";
import { resolveDate } from "./dates";
import { LABEL_W } from "./constants";
import TimedEventView from "./TimedEventView";

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
  onSelect: (id: string | null, occ?: string | null) => void;
  tlScroll: number;
}

const MIN = 0.25; // 15-minute minimum duration / gap

// Per-day overlap layout for all events in the displayed year.
function buildLayout(events: TimedEvent[], year: number): Map<string, EventLayout> {
  const byDay = new Map<string, TimedEvent[]>();
  for (const ev of events) {
    if (ev.year !== year) continue;
    const k = `${ev.month}-${ev.day}`;
    const arr = byDay.get(k);
    if (arr) arr.push(ev); else byDay.set(k, [ev]);
  }
  const out = new Map<string, EventLayout>();
  for (const group of byDay.values()) layoutDay(group).forEach((v, id) => out.set(id, v));
  return out;
}

export default function EventsLayer({ vp, z, focus, week, scrollY, year, events, addEvent, updateEvent, onEventHover, onOpenDetail, onContextMenu, selectedId, onSelect, tlScroll }: Props) {
  const layerRef = useRef<HTMLDivElement>(null);
  // While resizing, keep the layout frozen so growing an event doesn't reorder it;
  // recompute (and briefly enable CSS transitions to animate the reflow) on release.
  const [resizing, setResizing] = useState(false);
  const [movingId, setMovingId] = useState<string | null>(null);
  const movedRef = useRef(false); // a real move happened → suppress the trailing click
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
  const tl = timelineInfo(z, focus, week, vp, scrollY, tlScroll);
  const interactive = z >= 1.5; // week view → create / resize enabled
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
        .filter((ev) => ev.year === year)
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
          .map((o) => ({ ev, o, rect: eventRect({ month: o.month, day: o.day, startHour: ev.startHour, endHour: ev.endHour }, focus, tl, vp) }))
          .filter((x): x is { ev: TimedEvent; o: { year: number; month: number; day: number }; rect: EventRect } => x.rect != null))
    : [];

  return (
    <div ref={layerRef} className={`cc-events${animating ? " cc-events-animating" : ""}`}>
      {interactive && tl.hourH > 0 && (
        <div
          className="cc-create-surface"
          style={{ left: LABEL_W, top: tl.tlTop, width: vp.w - LABEL_W, height: tl.tlBottom - tl.tlTop }}
          onMouseDown={onCreateDown}
          onClick={(e) => e.stopPropagation()}
        />
      )}
      {/* clip+scroll the hourly content to the visible timeline window */}
      {tl.hourH > 0 && (
        <div className="cc-events-clip" style={{ top: tl.tlTop, width: vp.w, height: tl.viewH }}>
          <div className="cc-events-scroll" style={{ transform: `translateY(${-tl.scroll}px)` }}>
            {ghosts.map(({ ev, o, rect }) => (
              <div
                key={occKey(ev.id, o)}
                data-ev-id={ev.id}
                data-occ={occDate(o)}
                className={`cc-item cc-tevent cc-ev-${ev.color} cc-ghost${ev.id === selectedId ? " selected" : ""}`}
                style={{ transform: `translate(${rect.x}px, ${rect.y}px)`, width: rect.w, height: rect.h, opacity: tl.reveal, pointerEvents: interactive ? "auto" : "none" }}
                onClick={(e) => { e.stopPropagation(); onSelect(ev.id, occDate(o)); }}
                onDoubleClick={(e) => { e.stopPropagation(); onOpenDetail(ev.id, occDate(o)); }}
                onMouseEnter={() => setHover(occKey(ev.id, o), true)}
                onMouseLeave={() => setHover(occKey(ev.id, o), false)}
                onContextMenu={(e) => { e.preventDefault(); e.stopPropagation(); const r = e.currentTarget.getBoundingClientRect(); onContextMenu(ev.id, r.left + r.width / 2, r.top, occDate(o)); }}
              >
                <div className="cc-tevent-inner">
                  {tl.wide && <div className="cc-tevent-title">{ev.title}</div>}
                  {tl.wide && <div className="cc-tevent-time">{fmtRange(ev.startHour, ev.endHour)}</div>}
                </div>
                <RotateCw className="cc-rec-badge" size={10} strokeWidth={2.5} aria-hidden />
              </div>
            ))}
            {rects.map(({ ev, rect }) => (
              <TimedEventView
                key={ev.id}
                ev={ev}
                rect={rect}
                wide={tl.wide}
                reveal={tl.reveal}
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
                onSelect={onSelect}
              />
            ))}
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
