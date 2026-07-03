"use client";

// Promoted-band layer: renders timed/deadline events promoted to read-only ghost bands on their lane.

import { useRef, useState } from "react";
import { Vp } from "../../geometry/types";
import { frameFor, type MonthAnim } from "../../geometry/frames";
import { PAST_DIM } from "../../geometry/constants";
import { dayIsPast } from "../../util/dates";
import { bandEventRect, BandRect } from "../../geometry/bandGeom";
import { TimedEvent } from "../../model/types/eventTypes";
import { Deadline } from "../../model/types/deadlineTypes";
import { BandEvent } from "../../model/types/bandEventTypes";
import { occurrenceDates, occKey, occDate, baseHidden } from "../../model/occurrences";
import EventBadges from "../events/EventBadges";

// A timed/deadline event that's been "promoted" → rendered as a read-only 1-day ghost band on
// its lane, on the base day AND on every recurrence occurrence. Opening it opens the ORIGINAL
// event's drawer; the only band-specific interaction is dragging it vertically between lanes
// (changes the series' promoteTrack; day/month stay fixed).
interface PItem {
  key: string;
  id: string;
  kind: "timed" | "deadline";
  occ: string | null; // occurrence date "YYYY-MM-DD", or null for the base day
  month: number;
  day: number;
  track: number;
  title: string;
  color: string;
  recurring: boolean;
  ai: boolean;
  imported: boolean;
}

interface Props {
  vp: Vp;
  z: number;
  focus: number;
  week: number;
  scrollY: number;
  year: number;
  timed: TimedEvent[];
  deadlines: Deadline[];
  bandEvents: BandEvent[]; // real bands on the same lanes — so promoted titles clip before them too
  updateTimed: (id: string, patch: Partial<TimedEvent>) => void;
  updateDeadline: (id: string, patch: Partial<Deadline>) => void;
  selectedId: string | null;
  focusedOcc: string | null; // the focused occurrence → the one promoted bar that gets the standout ring
  onSelect: (id: string | null, occ?: string | null, space?: "timed" | "allday") => void;
  onOpenDetail: (id: string, occ?: string | null) => void;
  onContextMenu: (id: string, x: number, y: number, occ?: string | null) => void;
  monthAnim: MonthAnim | null;
  dimPast?: boolean; // "dim past events" view toggle
  now?: number;      // ms timestamp → decides what's past
}

const isRecurring = (r: TimedEvent["repeat"]) => !!r && r.kind !== "none";

export default function PromotedBandLayer({ vp, z, focus, week, scrollY, year, timed, deadlines, bandEvents, updateTimed, updateDeadline, selectedId, focusedOcc, onSelect, onOpenDetail, onContextMenu, monthAnim, dimPast = false, now = 0 }: Props) {
  // dim-past multiplier: 0.4 for a promoted bar whose day is fully behind us, else 1 (day-level
  // — the 1-day ghost band carries no time, so today's bars stay un-dimmed)
  const pdim = (m: number, day: number) => (dimPast && dayIsPast(year, m, day, now) ? PAST_DIM : 1);
  const layerRef = useRef<HTMLDivElement>(null);
  const movedRef = useRef(false);
  const [movingId, setMovingId] = useState<string | null>(null);

  const items: PItem[] = [];
  const add = (kind: "timed" | "deadline", id: string, eyear: number, month: number, day: number, track: number | null | undefined, title: string, color: string, repeat: TimedEvent["repeat"], ai: boolean, imported: boolean) => {
    if (track == null) return;
    const recurring = isRecurring(repeat);
    const base = { kind, id, track, title, color, recurring, ai, imported };
    if (eyear === year && !baseHidden(occDate({ year: eyear, month, day }), repeat)) items.push({ ...base, key: id, occ: null, month, day }); // the base day (this year only)
    if (recurring) {
      for (const o of occurrenceDates({ year: eyear, month, day }, repeat, year)) {
        items.push({ ...base, key: occKey(id, o), occ: occDate(o), month: o.month, day: o.day });
      }
    }
  };
  timed.forEach((e) => add("timed", e.id, e.year, e.month, e.day, e.promoteTrack, e.title, e.color, e.repeat, !!e.createdByAI, !!e.imported));
  deadlines.forEach((d) => add("deadline", d.id, d.year, d.month, d.day, d.promoteTrack, d.title, d.color, d.repeat, !!d.createdByAI, !!d.imported));

  const setTrack = (it: PItem, track: number) => {
    if (it.kind === "timed") updateTimed(it.id, { promoteTrack: track });
    else updateDeadline(it.id, { promoteTrack: track });
  };

  // Drag a bar vertically to move the series between lanes (its day/month stay fixed).
  const onMoveStart = (it: PItem, e: React.MouseEvent) => {
    if (e.button !== 0) return;
    e.stopPropagation();
    movedRef.current = false;
    const onMove = (me: MouseEvent) => {
      if (Math.abs(me.clientX - e.clientX) > 3 || Math.abs(me.clientY - e.clientY) > 3) movedRef.current = true;
      if (!movedRef.current) return;
      setMovingId(it.id);
      const r = layerRef.current!.getBoundingClientRect();
      const f = frameFor(it.month, z, focus, week, vp, scrollY);
      const track = Math.max(0, Math.min(3, Math.floor((me.clientY - r.top - f.bandY) / f.trackH)));
      if (track !== it.track) setTrack(it, track);
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

  const rects = items
    .map((it) => ({ it, rect: bandEventRect({ id: it.id, year, month: it.month, track: it.track, startDay: it.day, endDay: it.day, title: it.title, color: it.color }, z, focus, week, vp, scrollY, monthAnim) }))
    .filter((x): x is { it: PItem; rect: BandRect } => x.rect != null);

  // Title clip: each promoted bar's title stops before the NEXT bar on its lane — counting
  // other promoted bars AND real band events — so titles never overlap the following event.
  const gapByKey = new Map<string, number>();
  {
    type Bar = { key: string | null; lane: string; start: number; x: number };
    const bars: Bar[] = [
      ...rects.map((r) => ({ key: r.it.key, lane: `${r.it.month}-${r.it.track}`, start: r.it.day, x: r.rect.x })),
      ...bandEvents
        .filter((ev) => ev.year === year)
        .map((ev) => ({ ev, rect: bandEventRect(ev, z, focus, week, vp, scrollY, monthAnim) }))
        .filter((b): b is { ev: BandEvent; rect: BandRect } => b.rect != null)
        .map((b) => ({ key: null, lane: `${b.ev.month}-${b.ev.track}`, start: b.ev.startDay, x: b.rect.x })),
    ];
    const groups = new Map<string, Bar[]>();
    for (const b of bars) { const arr = groups.get(b.lane); if (arr) arr.push(b); else groups.set(b.lane, [b]); }
    for (const arr of groups.values()) {
      arr.sort((a, b) => a.start - b.start);
      for (let i = 0; i < arr.length - 1; i++) {
        const d = arr[i + 1].x - arr[i].x;
        if (d > 0 && arr[i].key) gapByKey.set(arr[i].key as string, d); // only clip the promoted bars
      }
    }
  }

  return (
    <div className="cc-promoted-layer" ref={layerRef}>
      {rects.map(({ it, rect }) => {
        const gap = gapByKey.get(it.key);
        const dim = pdim(it.month, it.day);
        return (
          <div
            key={it.key}
            data-ev-id={it.id}
            data-occ={it.occ ?? undefined}
            className={`cc-item cc-tevent cc-tevent-band cc-ghost cc-promoted cc-ev-${it.color}${gap != null ? " cc-band-clip" : ""}${it.id === selectedId ? " selected" : ""}${it.id === selectedId && (it.occ ?? null) === (focusedOcc ?? null) ? " cc-focused-occ" : ""}${it.id === movingId ? " moving" : ""}`}
            style={{ transform: `translate(${rect.x}px, ${rect.y}px)`, width: rect.w, height: rect.h, pointerEvents: "auto", ...(dim < 1 ? { opacity: dim } : {}), ...(gap != null ? ({ "--band-gap": `${Math.max(12, gap - 10)}px` } as React.CSSProperties) : {}) }}
            onMouseDown={(e) => onMoveStart(it, e)}
            onClick={(e) => { e.stopPropagation(); if (movedRef.current) return; onSelect(it.id, it.occ, "allday"); }}
            onDoubleClick={(e) => { e.stopPropagation(); onOpenDetail(it.id, it.occ); }}
            onContextMenu={(e) => { e.preventDefault(); e.stopPropagation(); const r = e.currentTarget.getBoundingClientRect(); onContextMenu(it.id, r.left + r.width / 2, r.top, it.occ); }}
          >
            <div className="cc-tevent-inner"><div className="cc-tevent-title">{it.title}</div></div>
            <EventBadges ai={it.ai} imported={it.imported} recurring={it.recurring} promoted />
          </div>
        );
      })}
    </div>
  );
}
