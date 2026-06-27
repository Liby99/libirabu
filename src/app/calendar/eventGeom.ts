// Bridges timed-event data ↔ screen geometry, mirroring scene.ts buildDetail so
// events line up exactly with the rendered day columns / hour timeline.

import { Vp } from "./types";
import { LABEL_W } from "./constants";
import { frameFor } from "./frames";
import { daysInMonth } from "./mock";
import { TimedEvent } from "./eventTypes";

export const MIN_HOUR_H = 50; // week-view per-hour height range (slider)
export const MAX_HOUR_H = 90;

// User-controlled week-view per-hour height (driven by the timeline scrollbar). Held
// at module level — synced from React state each render — so hourMetrics() can stay
// param-free across its many call sites (same pattern as YEAR in mock.ts).
let _weekHourH = 60;
export const clampHourH = (h: number) => Math.min(MAX_HOUR_H, Math.max(MIN_HOUR_H, h));
export function setWeekHourH(h: number) { _weekHourH = clampHourH(h); }
export function getWeekHourH() { return _weekHourH; }

// Hour height + scroll for a timeline window. month (z≤1) fits the viewport; week (z≥2)
// uses the slider height when the day would overflow, else fills (so a tall window shows
// the whole day with no scroll / no slider).
export function hourMetrics(tlTop: number, tlBottom: number, z: number, tlScroll: number) {
  const viewH = Math.max(0, tlBottom - tlTop);
  const fitH = viewH > 0 ? viewH / 24 : 0;
  // tall enough to fit at the minimum hour height → just fill the viewport (no scroll)
  const weekH = fitH >= MIN_HOUR_H ? fitH : clampHourH(_weekHourH);
  const hourH = fitH + (weekH - fitH) * Math.min(1, Math.max(0, z - 1));
  const maxScroll = Math.max(0, 24 * hourH - viewH);
  return { viewH, hourH, maxScroll, scroll: Math.min(Math.max(0, tlScroll), maxScroll) };
}

export interface TimelineInfo {
  x0: number;
  colW: number;
  tlTop: number;
  tlBottom: number;
  viewH: number;     // visible timeline height (tlBottom - tlTop)
  hourH: number;
  scroll: number;    // applied vertical scroll (clamped to maxScroll)
  maxScroll: number; // 0 unless the day is taller than the viewport (week, short window)
  reveal: number;    // 0 until ~month view, then 1 — matches buildDetail
  wide: boolean;     // week view (full event bodies)
}

// Single source of truth for the day-detail timeline geometry. `hourH` blends from
// fit-to-viewport (month, z≤1) to a 40px minimum (week, z≥2); when the day is taller
// than the viewport the extra becomes scrollable (only ever happens toward week view).
export function timelineInfo(z: number, focus: number, week: number, vp: Vp, scrollY: number, tlScroll: number): TimelineInfo {
  const f = frameFor(focus, z, focus, week, vp, scrollY);
  const tlTop = f.bandY + 4 * f.trackH + 18;
  const tlBottom = vp.h - 8;
  const m = hourMetrics(tlTop, tlBottom, z, tlScroll);
  return {
    x0: f.x0,
    colW: f.dayW,
    tlTop,
    tlBottom,
    viewH: m.viewH,
    hourH: m.hourH,
    scroll: m.scroll,
    maxScroll: m.maxScroll,
    reveal: z < 0.82 ? 0 : Math.min(1, Math.max(0, (z - 0.82) / 0.18)),
    wide: f.dayW > 60,
  };
}

// An event's day expressed in `focus`'s numbering (≤0 / >dim for spillover days);
// null when the event's month is not the focused month or an immediate neighbour.
export function relDomOf(focus: number, month: number, day: number): number | null {
  if (month === focus) return day;
  if (month === focus - 1) return day - daysInMonth(focus - 1);
  if (month === focus + 1) return daysInMonth(focus) + day;
  return null;
}

export interface EventRect { x: number; y: number; w: number; h: number }

// Hybrid placement within a day column:
//  • `col`/`nCols` — side-by-side columns: events whose TITLE bands collide (starts
//    closer than the title height) get separate columns and split the width.
//  • `level`/`maxLevel` — within a column, body-only overlaps (titles clear of each
//    other vertically) cascade with a small left indent instead of splitting further.
export interface EventLayout { col: number; nCols: number; level: number; maxLevel: number }

const TITLE_H = 1;    // title + time occupy ~1 hour of height
const INDENT_PX = 9;  // per-level left indent / right margin for cascaded events
const MIN_W = 26;     // floor on an event's drawn width

interface PackCol { events: TimedEvent[]; maxTitleEnd: number }

export function layoutDay(events: TimedEvent[]): Map<string, EventLayout> {
  const out = new Map<string, EventLayout>();
  const sorted = [...events].sort((a, b) => a.startHour - b.startHour || b.endHour - a.endHour);
  const level = new Map<string, number>();
  let cols: PackCol[] = [];
  let clusterEnd = -Infinity;

  const flush = () => {
    if (!cols.length) return;
    const nCols = cols.length;
    cols.forEach((c, ci) => {
      let maxLevel = 0;
      for (const e of c.events) maxLevel = Math.max(maxLevel, level.get(e.id)!);
      for (const e of c.events) out.set(e.id, { col: ci, nCols, level: level.get(e.id)!, maxLevel });
    });
    cols = [];
  };

  for (const ev of sorted) {
    if (ev.startHour >= clusterEnd) { flush(); clusterEnd = -Infinity; }
    const titleEnd = Math.min(ev.startHour + TITLE_H, ev.endHour);
    // first column whose titles all clear this event's title band → no title collision
    let col = cols.find((c) => c.maxTitleEnd <= ev.startHour);
    if (!col) { col = { events: [], maxTitleEnd: -Infinity }; cols.push(col); }
    // body-overlap depth within that column (titles already clear, only bodies overlap)
    let lvl = 0;
    for (const p of col.events) {
      if (p.endHour > ev.startHour) lvl = Math.max(lvl, level.get(p.id)! + 1);
    }
    level.set(ev.id, lvl);
    col.events.push(ev);
    col.maxTitleEnd = Math.max(col.maxTitleEnd, titleEnd);
    clusterEnd = Math.max(clusterEnd, ev.endHour);
  }
  flush();
  return out;
}

export function eventRect(
  ev: { month: number; day: number; startHour: number; endHour: number },
  focus: number,
  tl: TimelineInfo,
  vp: Vp,
  layout?: EventLayout,
): EventRect | null {
  const dom = relDomOf(focus, ev.month, ev.day);
  if (dom == null || tl.hourH <= 0) return null;
  const colX = tl.x0 + (dom - 1) * tl.colW;
  if (colX + tl.colW < -40 || colX > vp.w + 40) return null;
  const col = layout?.col ?? 0;
  const nCols = layout?.nCols ?? 1;
  const level = layout?.level ?? 0;
  const maxLevel = layout?.maxLevel ?? 0;
  const subW = tl.colW / nCols;
  const indent = maxLevel > 0 ? Math.min(INDENT_PX, Math.max(0, (subW - MIN_W) / maxLevel)) : 0;
  return {
    x: colX + col * subW + level * indent + 2, // 2px outer margin each side
    // y is relative to the scroll container's content top (the 0:00 line); the
    // container is anchored at tlTop and translated by -scroll.
    y: ev.startHour * tl.hourH + 1, // 1px top/bottom margin so stacked events never touch
    w: Math.max(3, subW - maxLevel * indent - 4),
    h: Math.max(3, (ev.endHour - ev.startHour) * tl.hourH - 2),
  };
}

// Pointer (layer-local px/py, screen coords) → focus-relative day column + fractional
// hour, accounting for the timeline scroll. `dom` is null left of the grid (gutter).
export function pointToSlot(px: number, py: number, tl: TimelineInfo): { dom: number | null; hourFrac: number } {
  const dom = px >= LABEL_W && tl.colW > 0 ? Math.floor((px - tl.x0) / tl.colW) + 1 : null;
  const hourFrac = tl.hourH > 0 ? Math.max(0, Math.min(24, (py - tl.tlTop + tl.scroll) / tl.hourH)) : 0;
  return { dom, hourFrac };
}
