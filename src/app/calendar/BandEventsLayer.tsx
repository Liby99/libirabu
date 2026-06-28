"use client";

import { useRef, useState } from "react";
import { RotateCw } from "lucide-react";
import { Vp } from "./types";
import { LABEL_W } from "./constants";
import { frameFor } from "./frames";
import { daysInMonth } from "./mock";
import { BandEvent } from "./bandEventTypes";
import { bandEventRect, bandSlotAtPoint, dayInMonth, BandRect } from "./bandGeom";
import { occurrenceDates, occKey, occDate } from "./occurrences";
import BandEventView from "./BandEventView";

interface Props {
  vp: Vp;
  z: number;
  focus: number;
  week: number;
  scrollY: number;
  year: number;
  events: BandEvent[];
  addEvent: (e: Omit<BandEvent, "id">) => BandEvent;
  updateEvent: (id: string, patch: Partial<BandEvent>) => void;
  selectedId: string | null;
  onSelect: (id: string | null, occ?: string | null) => void;
  onOpenDetail: (id: string, occ?: string | null) => void;
  onContextMenu: (id: string, x: number, y: number, occ?: string | null) => void;
}

type Draft = { month: number; track: number; a: number; b: number };

export default function BandEventsLayer({ vp, z, focus, week, scrollY, year, events, addEvent, updateEvent, selectedId, onSelect, onOpenDetail, onContextMenu }: Props) {
  const layerRef = useRef<HTMLDivElement>(null);
  const movedRef = useRef(false);
  const createdRef = useRef(false); // suppress the trailing click only after a real create-drag
  const [movingId, setMovingId] = useState<string | null>(null);
  const [hoveredId, setHoveredId] = useState<string | null>(null);
  const [draft, setDraft] = useState<Draft | null>(null);
  const draftRef = useRef<Draft | null>(null);
  const setDraftBoth = (d: Draft | null) => { draftRef.current = d; setDraft(d); };

  const localX = (clientX: number) => clientX - layerRef.current!.getBoundingClientRect().left;
  const localPt = (clientX: number, clientY: number) => {
    const r = layerRef.current!.getBoundingClientRect();
    return { px: clientX - r.left, py: clientY - r.top };
  };

  // ── Drag across a track lane → create a multi-day bar ──
  const onCreateDown = (e: React.MouseEvent) => {
    if (e.button !== 0) return;
    const { px, py } = localPt(e.clientX, e.clientY);
    const slot = bandSlotAtPoint(px, py, z, focus, week, vp, scrollY);
    if (!slot) return;
    e.preventDefault();
    e.stopPropagation();
    const { month, track, day: start } = slot;
    let moved = false;
    const onMove = (me: MouseEvent) => {
      if (Math.abs(me.clientX - e.clientX) > 3) moved = true;
      if (!moved) return;
      const end = dayInMonth(localX(me.clientX), month, z, focus, week, vp, scrollY);
      setDraftBoth({ month, track, a: Math.min(start, end), b: Math.max(start, end) });
    };
    const onUp = () => {
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
      const d = draftRef.current;
      if (d && moved) {
        addEvent({ year, month: d.month, track: d.track, startDay: d.a, endDay: d.b, title: "Event", color: "default" });
        createdRef.current = true;
        setTimeout(() => { createdRef.current = false; }, 0);
      }
      setDraftBoth(null);
    };
    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
  };

  // ── Drag a left/right edge → change startDay / endDay (whole-day snap) ──
  const onResizeStart = (id: string, edge: "start" | "end", e: React.MouseEvent) => {
    if (e.button !== 0) return;
    e.preventDefault();
    e.stopPropagation();
    const ev = events.find((x) => x.id === id);
    if (!ev) return;
    movedRef.current = false;
    const onMove = (me: MouseEvent) => {
      if (Math.abs(me.clientX - e.clientX) > 3) movedRef.current = true;
      const day = dayInMonth(localX(me.clientX), ev.month, z, focus, week, vp, scrollY);
      if (edge === "start") updateEvent(id, { startDay: Math.min(day, ev.endDay) });
      else updateEvent(id, { endDay: Math.max(day, ev.startDay) });
    };
    const onUp = () => {
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
      setTimeout(() => { movedRef.current = false; }, 0); // suppress the trailing click
    };
    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
  };

  // ── Drag the bar body → move across days / tracks / months (preserve length) ──
  const onMoveStart = (id: string, e: React.MouseEvent) => {
    if (e.button !== 0) return;
    e.stopPropagation();
    const ev = events.find((x) => x.id === id);
    if (!ev) return;
    const { px, py } = localPt(e.clientX, e.clientY);
    const startSlot = bandSlotAtPoint(px, py, z, focus, week, vp, scrollY);
    const grab = startSlot ? startSlot.day - ev.startDay : 0; // days from start to grab point
    const len = ev.endDay - ev.startDay;
    movedRef.current = false;
    const onMove = (me: MouseEvent) => {
      if (Math.abs(me.clientX - e.clientX) > 3 || Math.abs(me.clientY - e.clientY) > 3) movedRef.current = true;
      if (!movedRef.current) return;
      setMovingId(id);
      const pt = localPt(me.clientX, me.clientY);
      const slot = bandSlotAtPoint(pt.px, pt.py, z, focus, week, vp, scrollY);
      if (!slot) return;
      const dim = daysInMonth(slot.month);
      const start = Math.max(1, Math.min(dim - len, slot.day - grab));
      updateEvent(id, { month: slot.month, track: slot.track, startDay: start, endDay: start + len });
    };
    const onUp = () => {
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
      setMovingId(null);
      setTimeout(() => { movedRef.current = false; }, 0);
    };
    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
  };

  // create surface: full grid in year/month; only the focus band strip in week (so it
  // never overlaps the timed-event create surface in the timeline below).
  const f = frameFor(focus, z, focus, week, vp, scrollY);
  const stripOnly = z >= 1.5;
  const surfTop = stripOnly ? f.bandY : 0;
  const surfH = stripOnly ? 4 * f.trackH : vp.h;

  const rects = events
    .filter((ev) => ev.year === year)
    .map((ev) => ({ ev, rect: bandEventRect(ev, z, focus, week, vp, scrollY) }))
    .filter((x): x is { ev: BandEvent; rect: BandRect } => x.rect != null);

  // Recurrence: read-only ghost copies of repeating band events on their occurrence weeks.
  // No year filter — a cross-year base (loaded from an earlier year) projects ghosts into
  // this year; occurrenceDates windows to `year`, so non-reaching events expand to nothing.
  const ghosts = events
    .filter((ev) => ev.repeat && ev.repeat.kind !== "none")
    .flatMap((ev) => {
      const span = ev.endDay - ev.startDay;
      return occurrenceDates({ year: ev.year, month: ev.month, day: ev.startDay }, ev.repeat, year)
        .map((o) => {
          const endDay = Math.min(o.day + span, daysInMonth(o.month));
          return { ev, o, rect: bandEventRect({ ...ev, month: o.month, startDay: o.day, endDay }, z, focus, week, vp, scrollY) };
        })
        .filter((x): x is { ev: BandEvent; o: { year: number; month: number; day: number }; rect: BandRect } => x.rect != null);
    });

  // Per (month, track) lane, the px distance from each bar's left to the NEXT bar's left —
  // counting real events AND recurrence ghosts together — so every title (real or ghost)
  // clips before the following bar instead of overlapping it. Keyed per bar.
  const gapByKey = new Map<string, number>();
  {
    type Bar = { key: string; month: number; track: number; start: number; x: number };
    const bars: Bar[] = [
      ...rects.map((r) => ({ key: r.ev.id, month: r.ev.month, track: r.ev.track, start: r.ev.startDay, x: r.rect.x })),
      ...ghosts.map((g) => ({ key: occKey(g.ev.id, g.o), month: g.o.month, track: g.ev.track, start: g.o.day, x: g.rect.x })),
    ];
    const groups = new Map<string, Bar[]>();
    for (const b of bars) {
      const k = `${b.month}-${b.track}`;
      const arr = groups.get(k); if (arr) arr.push(b); else groups.set(k, [b]);
    }
    for (const arr of groups.values()) {
      arr.sort((a, b) => a.start - b.start);
      for (let i = 0; i < arr.length - 1; i++) {
        const d = arr[i + 1].x - arr[i].x;
        if (d > 0) gapByKey.set(arr[i].key, d);
      }
    }
  }

  return (
    <div ref={layerRef} className="cc-band-events">
      <div
        className="cc-band-create-surface"
        style={{ left: LABEL_W, top: surfTop, width: vp.w - LABEL_W, height: Math.max(0, surfH) }}
        onMouseDown={onCreateDown}
        onClick={(e) => { if (createdRef.current) e.stopPropagation(); }} // let plain clicks navigate/deselect
      />
      {ghosts.map(({ ev, o, rect }) => {
        const gap = gapByKey.get(occKey(ev.id, o)); // clip the title before the next bar on the lane
        return (
          <div
            key={occKey(ev.id, o)}
            data-ev-id={ev.id}
            data-occ={occDate(o)}
            className={`cc-item cc-tevent cc-tevent-band cc-ev-${ev.color} cc-ghost${gap != null ? " cc-band-clip" : ""}${ev.id === selectedId ? " selected" : ""}`}
            style={{ transform: `translate(${rect.x}px, ${rect.y}px)`, width: rect.w, height: rect.h, pointerEvents: "auto", ...(gap != null ? ({ "--band-gap": `${Math.max(12, gap - 10)}px` } as React.CSSProperties) : {}) }}
            onClick={(e) => { e.stopPropagation(); onSelect(ev.id, occDate(o)); }}
            onDoubleClick={(e) => { e.stopPropagation(); onOpenDetail(ev.id, occDate(o)); }}
            onContextMenu={(e) => { e.preventDefault(); e.stopPropagation(); const r = e.currentTarget.getBoundingClientRect(); onContextMenu(ev.id, r.left + r.width / 2, r.top, occDate(o)); }}
          >
            <div className="cc-tevent-inner"><div className="cc-tevent-title">{ev.title}</div></div>
            <RotateCw className="cc-rec-badge" size={10} strokeWidth={2.5} aria-hidden />
          </div>
        );
      })}
      {rects.map(({ ev, rect }) => (
        <BandEventView
          key={ev.id}
          ev={ev}
          rect={rect}
          vw={vp.w}
          gap={gapByKey.get(ev.id)}
          raised={ev.id === hoveredId}
          onHover={setHoveredId}
          selected={ev.id === selectedId}
          moving={ev.id === movingId}
          movedRef={movedRef}
          onMoveStart={onMoveStart}
          onResizeStart={onResizeStart}
          onSelect={onSelect}
          onTitleCommit={(eid, title) => updateEvent(eid, { title })}
          onOpenDetail={onOpenDetail}
          onContextMenu={onContextMenu}
        />
      ))}
      {draft && (() => {
        const r = bandEventRect({ id: "", year, month: draft.month, track: draft.track, startDay: draft.a, endDay: draft.b, title: "", color: "default" }, z, focus, week, vp, scrollY);
        return r ? <div className="cc-tevent-preview" style={{ transform: `translate(${r.x}px, ${r.y}px)`, width: r.w, height: r.h }} /> : null;
      })()}
    </div>
  );
}
