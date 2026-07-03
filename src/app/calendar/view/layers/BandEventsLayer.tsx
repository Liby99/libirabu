"use client";

// All-day band layer: renders + handles drag/resize/create for band events across a month's 4 tracks.

import { Fragment, useRef, useState } from "react";
import EventBadges from "../events/EventBadges";
import { Vp } from "../../geometry/types";
import { LABEL_W, PAST_DIM } from "../../geometry/constants";
import { dayIsPast } from "../../util/dates";
import { frameFor, type MonthAnim } from "../../geometry/frames";
import { daysInMonth } from "../../model/api/mock";
import { BandEvent } from "../../model/types/bandEventTypes";
import { bandEventRect, bandSlotAtPoint, dayInMonth, BandRect } from "../../geometry/bandGeom";
import { occurrenceDates, occKey, occDate, baseHidden } from "../../model/occurrences";
import BandEventView from "../events/BandEventView";

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
  focusedOcc: string | null; // the focused occurrence → the one bar that gets the standout ring
  onSelect: (id: string | null, occ?: string | null, space?: "timed" | "allday") => void;
  onOpenDetail: (id: string, occ?: string | null) => void;
  onContextMenu: (id: string, x: number, y: number, occ?: string | null) => void;
  editingId: string | null;
  onEditConsumed: () => void;
  monthAnim: MonthAnim | null;
  dimPast?: boolean; // "dim past events" view toggle
  now?: number;      // ms timestamp → decides what's past
}

type Draft = { month: number; track: number; a: number; b: number };

export default function BandEventsLayer({ vp, z, focus, week, scrollY, year, events, addEvent, updateEvent, selectedId, focusedOcc, onSelect, onOpenDetail, onContextMenu, editingId, onEditConsumed, monthAnim, dimPast = false, now = 0 }: Props) {
  // dim-past multiplier: 0.4 once an all-day band's last day is fully behind us, else 1
  const bdim = (oy: number, om: number, endDay: number) => (dimPast && dayIsPast(oy, om, endDay, now) ? PAST_DIM : 1);
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
    .filter((ev) => ev.year === year && !baseHidden(occDate({ year: ev.year, month: ev.month, day: ev.startDay }), ev.repeat))
    .map((ev) => ({ ev, rect: bandEventRect(ev, z, focus, week, vp, scrollY, monthAnim) }))
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
          return { ev, o, rect: bandEventRect({ ...ev, month: o.month, startDay: o.day, endDay }, z, focus, week, vp, scrollY, monthAnim) };
        })
        .filter((x): x is { ev: BandEvent; o: { year: number; month: number; day: number }; rect: BandRect } => x.rect != null);
    });

  // Two per-lane title treatments, computed over real events AND recurrence ghosts together
  // (keyed per bar):
  //  • gapByKey — px from a bar's left to the NEXT bar (one that STARTS LATER) on the lane, so
  //    a title clips before the following bar instead of overflowing into it.
  //  • collideByKey — bars that share the SAME start day on a lane stack on top of one another.
  //    The shorter sits on top (higher z) with its title clipped to its own width; each longer
  //    bar beneath gets a left mask (width = the next-shorter bar) hiding its covered title.
  //    Two bars of identical length fully overlap → an error we flag with a red badge.
  type Bar = { key: string; month: number; track: number; start: number; len: number; x: number; w: number };
  const bars: Bar[] = [
    ...rects.map((r) => ({ key: r.ev.id, month: r.ev.month, track: r.ev.track, start: r.ev.startDay, len: r.ev.endDay - r.ev.startDay, x: r.rect.x, w: r.rect.w })),
    ...ghosts.map((g) => {
      const end = Math.min(g.o.day + (g.ev.endDay - g.ev.startDay), daysInMonth(g.o.month));
      return { key: occKey(g.ev.id, g.o), month: g.o.month, track: g.ev.track, start: g.o.day, len: end - g.o.day, x: g.rect.x, w: g.rect.w };
    }),
  ];
  const gapByKey = new Map<string, number>();
  const collideByKey = new Map<string, { z: number; maskLeft: number; error: boolean }>();
  {
    const lanes = new Map<string, Bar[]>();
    for (const b of bars) {
      const k = `${b.month}-${b.track}`;
      const arr = lanes.get(k); if (arr) arr.push(b); else lanes.set(k, [b]);
    }
    for (const lane of lanes.values()) {
      // clip each title before the next bar that starts later
      const byStart = [...lane].sort((a, b) => a.start - b.start);
      for (let i = 0; i < byStart.length - 1; i++) {
        const d = byStart[i + 1].x - byStart[i].x;
        if (d > 0) gapByKey.set(byStart[i].key, d);
      }
      // same-start stacks: longest at the bottom, each covered by the next-shorter above it
      const byDay = new Map<number, Bar[]>();
      for (const b of lane) { const g = byDay.get(b.start); if (g) g.push(b); else byDay.set(b.start, [b]); }
      for (const stack of byDay.values()) {
        if (stack.length < 2) continue;
        stack.sort((a, b) => b.len - a.len); // longest first (bottom)
        for (let i = 0; i < stack.length; i++) {
          const above = stack[i + 1]; // the next-shorter bar, directly on top of this one
          const sameLen = (i > 0 && stack[i - 1].len === stack[i].len) || (!!above && above.len === stack[i].len);
          collideByKey.set(stack[i].key, { z: 10 + stack[i].start + i * 2, maskLeft: above ? above.w : 0, error: sameLen });
        }
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
        const key = occKey(ev.id, o);
        const gap = gapByKey.get(key); // clip the title before the next bar on the lane
        const cd = collideByKey.get(key); // same-start stack: z / left-mask / error
        const endDay = Math.min(o.day + (ev.endDay - ev.startDay), daysInMonth(o.month));
        const dim = bdim(o.year, o.month, endDay);
        return (
          <Fragment key={key}>
            {cd && cd.maskLeft > 0 && (
              <div className="cc-band-undercut-mask" style={{ left: rect.x, top: rect.y, width: cd.maskLeft, height: rect.h, zIndex: cd.z + 1 }} />
            )}
            {cd?.error && (
              <div className="cc-band-error-badge" title="Two events share the same dates on this track — give one a different date or track." style={{ left: rect.x + rect.w - 17, top: rect.y + (rect.h - 15) / 2, zIndex: cd.z + 3 }}>!</div>
            )}
            <div
              data-ev-id={ev.id}
              data-occ={occDate(o)}
              className={`cc-item cc-tevent cc-tevent-band cc-ev-${ev.color} cc-ghost${gap != null ? " cc-band-clip" : ""}${ev.id === selectedId ? " selected" : ""}${ev.id === selectedId && occDate(o) === focusedOcc ? " cc-focused-occ" : ""}${cd ? " cc-band-collide" : ""}${cd && cd.maskLeft > 0 ? " cc-band-undercut" : ""}`}
              style={{ transform: `translate(${rect.x}px, ${rect.y}px)`, width: rect.w, height: rect.h, pointerEvents: "auto", ...(cd ? { zIndex: cd.z } : {}), ...(dim < 1 ? { opacity: dim } : {}), ...(gap != null ? ({ "--band-gap": `${Math.max(12, gap - 10)}px` } as React.CSSProperties) : {}), ...(cd && cd.maskLeft > 0 ? ({ "--band-mask-left": `${cd.maskLeft}px` } as React.CSSProperties) : {}) }}
              onClick={(e) => { e.stopPropagation(); onSelect(ev.id, occDate(o), "allday"); }}
              onDoubleClick={(e) => { e.stopPropagation(); onOpenDetail(ev.id, occDate(o)); }}
              onContextMenu={(e) => { e.preventDefault(); e.stopPropagation(); const r = e.currentTarget.getBoundingClientRect(); onContextMenu(ev.id, r.left + r.width / 2, r.top, occDate(o)); }}
            >
              <div className="cc-tevent-inner"><div className="cc-tevent-title">{ev.title}</div></div>
              <EventBadges ai={ev.createdByAI} imported={ev.imported} recurring />
            </div>
          </Fragment>
        );
      })}
      {rects.map(({ ev, rect }) => (
        <BandEventView
          key={ev.id}
          ev={ev}
          rect={rect}
          vw={vp.w}
          gap={gapByKey.get(ev.id)}
          collide={collideByKey.get(ev.id)}
          dim={bdim(ev.year, ev.month, ev.endDay)}
          raised={ev.id === hoveredId}
          onHover={setHoveredId}
          selected={ev.id === selectedId}
          focused={ev.id === selectedId && focusedOcc == null}
          moving={ev.id === movingId}
          movedRef={movedRef}
          onMoveStart={onMoveStart}
          onResizeStart={onResizeStart}
          onSelect={(id) => onSelect(id, null, "allday")}
          onTitleCommit={(eid, title) => updateEvent(eid, { title })}
          onOpenDetail={onOpenDetail}
          onContextMenu={onContextMenu}
          requestEdit={editingId === ev.id}
          onEditConsumed={onEditConsumed}
        />
      ))}
      {draft && (() => {
        const r = bandEventRect({ id: "", year, month: draft.month, track: draft.track, startDay: draft.a, endDay: draft.b, title: "", color: "default" }, z, focus, week, vp, scrollY);
        return r ? <div className="cc-tevent-preview" style={{ transform: `translate(${r.x}px, ${r.y}px)`, width: r.w, height: r.h }} /> : null;
      })()}
    </div>
  );
}
