// Pure layout: every visual element's rect is a function of the zoom scalar `z`.
//   z = 0  → Year   (GridCal-like: months stacked, 3/quarter, 4 quarters)
//   z = 1  → Month  (focused month's track band on top, full width)
//   z = 2  → Week   (focused week's 7 days widened; tracks = all-day band)
// Year→Month is a vertical reflow (day width constant); Month→Week is horizontal.

import { TRACKS, EVENTS, TIMED, daysInMonth, YEAR } from "./mock";

export interface Vp { w: number; h: number }

export interface Item {
  key: string;
  kind: "row" | "event" | "monthLabel" | "dayLabel" | "quarterLabel" | "gridline";
  x: number; y: number; w: number; h: number;
  opacity: number;
  z: number; // stacking
  color?: string;
  text?: string;
  fontSize?: number;
  align?: "left" | "center";
  cols?: number; // for row gridlines (= days in month)
}

export interface Scene {
  items: Item[];
  outline?: { x: number; y: number; w: number; h: number };
}

const TOP_PAD = 70; // room for breadcrumb + dates row + weekday row above the band
const LABEL_W = 64;

const lerp = (a: number, b: number, t: number) => a + (b - a) * t;
const clamp = (v: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, v));
export const easeInOut = (t: number) => (t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2);

// Per-month frame: where day 1 sits, day width, band top, track row height, opacity.
interface Frame { x0: number; dayW: number; bandY: number; trackH: number; opacity: number }

const QUARTER_GAP = 14;
const MONTH_GAP = 7;

function yearFrame(m: number, vp: Vp): Frame {
  const dayW = (vp.w - LABEL_W - 16) / 31;
  // total vertical budget for 48 track rows + gaps
  const innerGaps = 8 * MONTH_GAP + 3 * QUARTER_GAP; // 8 intra-quarter month gaps + 3 quarter gaps
  const trackH = (vp.h - TOP_PAD - 16 - innerGaps) / 48;
  const monthH = trackH * 4;
  const q = Math.floor(m / 3);
  const within = m % 3;
  const quarterBlockH = monthH * 3 + MONTH_GAP * 2;
  const bandY = TOP_PAD + q * (quarterBlockH + QUARTER_GAP) + within * (monthH + MONTH_GAP);
  return { x0: LABEL_W, dayW, bandY, trackH, opacity: 1 };
}

function monthFrame(m: number, focus: number, vp: Vp): Frame {
  const dayW = (vp.w - LABEL_W - 16) / 31; // same day width as year → vertical-only transition
  const trackH = 30;
  if (m === focus) return { x0: LABEL_W, dayW, bandY: TOP_PAD, trackH, opacity: 1 };
  const dir = m < focus ? -1 : 1;
  const off = dir < 0 ? -trackH * 4 - 80 : vp.h + 80;
  return { x0: LABEL_W, dayW, bandY: off, trackH, opacity: 0 };
}

function weekFrame(m: number, focus: number, week: number, vp: Vp): Frame {
  const trackH = 34;
  if (m === focus) {
    const dayW = (vp.w - LABEL_W - 16) / 7;
    const x0 = LABEL_W - week * 7 * dayW; // shift so the focused week's first day lands at LABEL_W
    return { x0, dayW, bandY: TOP_PAD, trackH, opacity: 1 };
  }
  const dir = m < focus ? -1 : 1;
  const off = dir < 0 ? -trackH * 4 - 80 : vp.h + 80;
  return { x0: LABEL_W, dayW: (vp.w - LABEL_W - 16) / 7, bandY: off, trackH, opacity: 0 };
}

function blend(a: Frame, b: Frame, t: number): Frame {
  return {
    x0: lerp(a.x0, b.x0, t),
    dayW: lerp(a.dayW, b.dayW, t),
    bandY: lerp(a.bandY, b.bandY, t),
    trackH: lerp(a.trackH, b.trackH, t),
    opacity: lerp(a.opacity, b.opacity, t),
  };
}

function frameFor(m: number, z: number, focus: number, week: number, vp: Vp): Frame {
  if (z <= 1) return blend(yearFrame(m, vp), monthFrame(m, focus, vp), easeInOut(clamp(z, 0, 1)));
  return blend(monthFrame(m, focus, vp), weekFrame(m, focus, week, vp), easeInOut(clamp(z - 1, 0, 1)));
}

export function weeksInMonth(m: number): number {
  return Math.ceil(daysInMonth(m) / 7);
}

const MONTH_NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const WD = ["S", "M", "T", "W", "T", "F", "S"];
const WD3 = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

export function buildScene(
  z: number,
  focus: number,
  week: number,
  vp: Vp,
): Scene {
  const items: Item[] = [];

  for (let m = 0; m < 12; m++) {
    const f = frameFor(m, z, focus, week, vp);
    if (f.opacity < 0.02) continue;
    const dim = daysInMonth(m);
    const bandW = dim * f.dayW;

    // month label
    items.push({
      key: `ml-${m}`, kind: "monthLabel", x: 6, y: f.bandY, w: LABEL_W - 8, h: f.trackH * 4,
      opacity: f.opacity, text: MONTH_NAMES[m], fontSize: clamp(f.trackH * 0.5, 9, 16), align: "center", z: 3,
    });

    // track rows (with gridline background drawn by the component)
    for (let t = 0; t < 4; t++) {
      items.push({
        key: `row-${m}-${t}`, kind: "row",
        x: f.x0, y: f.bandY + t * f.trackH, w: bandW, h: f.trackH,
        opacity: f.opacity, color: TRACKS[t].color, cols: dim, z: 1,
      });
    }

  }

  // events (drawn after rows so they sit on top)
  for (const ev of EVENTS) {
    const f = frameFor(ev.month, z, focus, week, vp);
    if (f.opacity < 0.02) continue;
    const x = f.x0 + (ev.start - 1) * f.dayW;
    const w = (ev.end - ev.start + 1) * f.dayW;
    // hide events horizontally outside the viewport in week view (cheap cull)
    if (x + w < -40 || x > vp.w + 40) continue;
    items.push({
      key: `ev-${ev.id}`, kind: "event",
      x: x + 1, y: f.bandY + ev.track * f.trackH + 1, w: Math.max(2, w - 2), h: f.trackH - 2,
      opacity: f.opacity, color: TRACKS[ev.track].color,
      text: f.dayW > 14 ? ev.title : undefined, fontSize: 11, z: 2,
    });
  }

  // ── Header rows (focused month) + 0:00–24:00 day-detail timeline ─────────
  const reveal = clamp(z, 0, 1); // 0 in year, 1 by month, stays 1 in week
  if (reveal > 0.02) {
    const f = frameFor(focus, z, focus, week, vp);
    const dim = daysInMonth(focus);
    const colW = f.dayW;
    const bandBottom = f.bandY + 4 * f.trackH;
    const wide = colW > 60; // week view → full weekday names + event titles

    // dates (1–31) above the band, weekdays (Mon, Tue, …) just above the band
    for (let d = 1; d <= dim; d++) {
      const x = f.x0 + (d - 1) * colW;
      if (x + colW < -40 || x > vp.w + 40) continue;
      const dow = new Date(YEAR, focus, d).getDay();
      items.push({
        key: `date-${d}`, kind: "dayLabel", x, y: f.bandY - 34, w: colW, h: 16,
        opacity: reveal, text: String(d), fontSize: wide ? 13 : 10, align: "center", z: 4,
      });
      items.push({
        key: `wd-${d}`, kind: "dayLabel", x, y: f.bandY - 18, w: colW, h: 14,
        opacity: reveal * 0.8, text: wide ? WD3[dow] : WD[dow], fontSize: wide ? 11 : 9, align: "center", z: 4,
      });
    }

    // timeline grid 0:00–24:00
    const tlTop = bandBottom + 10;
    const tlBottom = vp.h - 8;
    if (tlBottom > tlTop) {
      const hourH = (tlBottom - tlTop) / 24;
      const hourStep = wide ? 2 : 6;

      // horizontal hour lines + left-gutter hour labels
      for (let hr = 0; hr <= 24; hr += hourStep) {
        const y = tlTop + hr * hourH;
        items.push({
          key: `hl-${hr}`, kind: "gridline", x: LABEL_W, y, w: vp.w - LABEL_W - 6, h: 1,
          opacity: reveal * 0.16, color: "#4c2d14", z: 0,
        });
        items.push({
          key: `ht-${hr}`, kind: "dayLabel", x: 2, y: y - 7, w: LABEL_W - 8, h: 14,
          opacity: reveal * 0.7, text: `${String(hr).padStart(2, "0")}:00`, fontSize: 9, align: "center", z: 4,
        });
      }

      // day-column dividers + timed event blocks
      for (let d = 1; d <= dim; d++) {
        const x = f.x0 + (d - 1) * colW;
        if (x + colW < -40 || x > vp.w + 40) continue;
        items.push({
          key: `tdv-${d}`, kind: "gridline", x, y: tlTop, w: 1, h: tlBottom - tlTop,
          opacity: reveal * 0.28, color: "#4c2d14", z: 0,
        });
      }
      for (const ev of TIMED) {
        if (ev.month !== focus) continue;
        const x = f.x0 + (ev.day - 1) * colW;
        if (x + colW < -40 || x > vp.w + 40) continue;
        items.push({
          key: `te-${ev.id}`, kind: "event",
          x: x + 2, y: tlTop + ev.startHour * hourH, w: Math.max(3, colW - 4),
          h: Math.max(3, (ev.endHour - ev.startHour) * hourH),
          opacity: reveal, color: TRACKS[ev.track].color,
          text: wide ? ev.title : undefined, fontSize: 11, z: 2,
        });
      }
    }
  }

  return { items };
}

interface Rect { x: number; y: number; w: number; h: number }

function focusGeom(vp: Vp) {
  return { x0: LABEL_W, dayW: (vp.w - LABEL_W - 16) / 31, bandY: TOP_PAD, trackH: 30 };
}

// Year phase: which month is under the cursor.
export function monthAtPoint(px: number, py: number, vp: Vp): number | null {
  for (let m = 0; m < 12; m++) {
    const f = yearFrame(m, vp);
    const dim = daysInMonth(m);
    if (py >= f.bandY && py <= f.bandY + 4 * f.trackH && px >= f.x0 && px <= f.x0 + dim * f.dayW) {
      return m;
    }
  }
  return null;
}

// Month phase: which week of the focused month is under the cursor.
export function weekAtPointInMonth(px: number, focus: number, vp: Vp): number | null {
  const g = focusGeom(vp);
  const dim = daysInMonth(focus);
  if (px < g.x0 || px > g.x0 + dim * g.dayW) return null;
  const day = Math.floor((px - g.x0) / g.dayW);
  return Math.min(Math.floor(day / 7), weeksInMonth(focus) - 1);
}

// Outline around a whole month (year phase).
export function monthOutlineRect(m: number, vp: Vp): Rect {
  const f = yearFrame(m, vp);
  const dim = daysInMonth(m);
  return { x: f.x0 - 1, y: f.bandY - 1, w: dim * f.dayW + 2, h: 4 * f.trackH + 2 };
}

// Outline around a week within the focused month (month phase).
export function weekOutlineRect(focus: number, week: number, vp: Vp): Rect {
  const g = focusGeom(vp);
  return { x: g.x0 + week * 7 * g.dayW - 1, y: g.bandY - 1, w: 7 * g.dayW + 2, h: 4 * g.trackH + 2 };
}

export { TOP_PAD, LABEL_W };
