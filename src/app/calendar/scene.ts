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

const TOP_PAD = 56; // room for breadcrumb + dates row above the band (weekdays sit below)
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

// Weeks are Sunday-aligned calendar weeks. weekStartDOM may be ≤0 or >daysInMonth
// when the week spills into the adjacent month (those days are rendered dimmer).
function firstDOW(m: number): number { return new Date(YEAR, m, 1).getDay(); } // 0=Sun
function weekStartDOM(m: number, week: number): number { return 1 - firstDOW(m) + week * 7; }

function weekFrame(m: number, focus: number, week: number, vp: Vp): Frame {
  const trackH = 34;
  const dayW = (vp.w - LABEL_W - 16) / 7;
  if (m === focus) {
    const startDOM = weekStartDOM(focus, week);
    const x0 = LABEL_W - (startDOM - 1) * dayW; // day=startDOM lands at LABEL_W
    return { x0, dayW, bandY: TOP_PAD, trackH, opacity: 1 };
  }
  const dir = m < focus ? -1 : 1;
  const off = dir < 0 ? -trackH * 4 - 80 : vp.h + 80;
  return { x0: LABEL_W, dayW, bandY: off, trackH, opacity: 0 };
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
  return Math.ceil((firstDOW(m) + daysInMonth(m)) / 7);
}

// Resolve a (focus month, day-of-month-that-may-spill) into a real {month, day}.
function resolveDate(focus: number, dom: number): { month: number; day: number } | null {
  if (dom >= 1 && dom <= daysInMonth(focus)) return { month: focus, day: dom };
  if (dom < 1) {
    const m = focus - 1;
    if (m < 0) return null;
    return { month: m, day: daysInMonth(m) + dom };
  }
  const m = focus + 1;
  if (m > 11) return null;
  return { month: m, day: dom - daysInMonth(focus) };
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

  // Non-focused months fade out quickly (gone by z≈0.4) so most transition frames
  // only draw the focused month — the main perf win for the year→month zoom.
  const offFade = clamp(1 - z / 0.4, 0, 1);

  for (let m = 0; m < 12; m++) {
    const f = frameFor(m, z, focus, week, vp);
    const op = m === focus ? f.opacity : Math.min(f.opacity, offFade);
    if (op < 0.02) continue;
    const dim = daysInMonth(m);
    const bandW = dim * f.dayW;

    items.push({
      key: `ml-${m}`, kind: "monthLabel", x: 6, y: f.bandY, w: LABEL_W - 8, h: f.trackH * 4,
      opacity: op, text: MONTH_NAMES[m], fontSize: clamp(f.trackH * 0.5, 9, 16), align: "center", z: 3,
    });

    for (let t = 0; t < 4; t++) {
      items.push({
        key: `row-${m}-${t}`, kind: "row",
        x: f.x0, y: f.bandY + t * f.trackH, w: bandW, h: f.trackH,
        opacity: op, color: TRACKS[t].color, cols: dim, z: 1,
      });
    }
  }

  // events (drawn after rows so they sit on top)
  for (const ev of EVENTS) {
    const f = frameFor(ev.month, z, focus, week, vp);
    const op = ev.month === focus ? f.opacity : Math.min(f.opacity, offFade);
    if (op < 0.02) continue;
    const x = f.x0 + (ev.start - 1) * f.dayW;
    const w = (ev.end - ev.start + 1) * f.dayW;
    if (x + w < -40 || x > vp.w + 40) continue; // cull off-screen (week view)
    items.push({
      key: `ev-${ev.id}`, kind: "event",
      x: x + 1, y: f.bandY + ev.track * f.trackH + 1, w: Math.max(2, w - 2), h: f.trackH - 2,
      opacity: op, color: TRACKS[ev.track].color,
      text: f.dayW > 14 ? ev.title : undefined, fontSize: 11, z: 2,
    });
  }

  // ── Header rows (focused month) + 0:00–24:00 day-detail timeline ─────────
  // Hidden until we're nearly at Month view, then fades in — avoids drawing the
  // ~150 detail items during the bulk of the year→month zoom.
  const reveal = z < 0.82 ? 0 : clamp((z - 0.82) / 0.18, 0, 1);
  if (reveal > 0.02) {
    const f = frameFor(focus, z, focus, week, vp);
    const dim = daysInMonth(focus);
    const colW = f.dayW;
    const bandBottom = f.bandY + 4 * f.trackH;
    const wide = colW > 60; // week view → full weekday names + event titles
    const weekZoom = clamp(z - 1, 0, 1); // 0 at month, 1 at week — gates spillover days

    const tlTop = bandBottom + 18;
    const tlBottom = vp.h - 8;
    const hasTL = tlBottom > tlTop;
    const hourH = hasTL ? (tlBottom - tlTop) / 24 : 0;

    // global hour grid (once)
    if (hasTL) {
      for (let hr = 0; hr <= 24; hr += wide ? 2 : 6) {
        const y = tlTop + hr * hourH;
        items.push({ key: `hl-${hr}`, kind: "gridline", x: LABEL_W, y, w: vp.w - LABEL_W - 6, h: 1, opacity: reveal * 0.16, color: "#4c2d14", z: 0 });
        items.push({ key: `ht-${hr}`, kind: "dayLabel", x: 2, y: y - 7, w: LABEL_W - 8, h: 14, opacity: reveal * 0.7, text: `${String(hr).padStart(2, "0")}:00`, fontSize: 9, align: "center", z: 4 });
      }
    }

    // render one day column (header above band, weekday below band, timeline)
    const pushDay = (dom: number, op: number) => {
      const r = resolveDate(focus, dom);
      if (!r) return;
      const x = f.x0 + (dom - 1) * colW;
      if (x + colW < -40 || x > vp.w + 40) return;
      const dow = new Date(YEAR, r.month, r.day).getDay();
      // date number above the band — spillover days also show their month
      const dateText = r.month === focus ? String(r.day) : `${MONTH_NAMES[r.month]} ${r.day}`;
      items.push({ key: `date-${dom}`, kind: "dayLabel", x, y: f.bandY - 20, w: colW, h: 16, opacity: op, text: dateText, fontSize: wide ? 13 : 10, align: "center", z: 4 });
      // weekday just below the band
      items.push({ key: `wd-${dom}`, kind: "dayLabel", x, y: bandBottom + 2, w: colW, h: 14, opacity: op * 0.9, text: wide ? WD3[dow] : WD[dow], fontSize: wide ? 11 : 9, align: "center", z: 4 });
      if (!hasTL) return;
      items.push({ key: `tdv-${dom}`, kind: "gridline", x, y: tlTop, w: 1, h: tlBottom - tlTop, opacity: op * 0.4, color: "#4c2d14", z: 0 });
      for (const ev of TIMED) {
        if (ev.month !== r.month || ev.day !== r.day) continue;
        items.push({
          key: `te-${ev.id}`, kind: "event",
          x: x + 2, y: tlTop + ev.startHour * hourH, w: Math.max(3, colW - 4),
          h: Math.max(3, (ev.endHour - ev.startHour) * hourH),
          opacity: op, color: TRACKS[ev.track].color, text: wide ? ev.title : undefined, fontSize: 11, z: 2,
        });
      }
    };

    // in-month days
    for (let d = 1; d <= dim; d++) pushDay(d, reveal);
    // spillover days of the focused week (Sun–Sat), dimmer, fading in as we reach week view
    if (weekZoom > 0.01) {
      const start = weekStartDOM(focus, week);
      for (let i = 0; i < 7; i++) {
        const dom = start + i;
        if (dom >= 1 && dom <= dim) continue;
        pushDay(dom, weekZoom * 0.5);
      }
      // border between months within the week
      let prevM: number | null = null;
      for (let i = 0; i < 7; i++) {
        const dom = start + i;
        const r = resolveDate(focus, dom);
        const m = r ? r.month : null;
        if (i > 0 && m != null && prevM != null && m !== prevM) {
          const x = f.x0 + (dom - 1) * colW;
          items.push({ key: `mb-${i}`, kind: "gridline", x: x - 1, y: f.bandY - 6, w: 2, h: tlBottom - (f.bandY - 6), opacity: weekZoom * 0.7, color: "#4c2d14", z: 5 });
        }
        prevM = m;
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

// Month phase: which (Sunday-aligned) week of the focused month is under the cursor.
export function weekAtPointInMonth(px: number, focus: number, vp: Vp): number | null {
  const g = focusGeom(vp);
  const dim = daysInMonth(focus);
  if (px < g.x0 || px > g.x0 + dim * g.dayW) return null;
  const d = Math.floor((px - g.x0) / g.dayW) + 1; // 1..dim
  const w = Math.floor((firstDOW(focus) + d - 1) / 7);
  return Math.min(Math.max(w, 0), weeksInMonth(focus) - 1);
}

// Outline around a whole month (year phase).
export function monthOutlineRect(m: number, vp: Vp): Rect {
  const f = yearFrame(m, vp);
  const dim = daysInMonth(m);
  return { x: f.x0 - 1, y: f.bandY - 1, w: dim * f.dayW + 2, h: 4 * f.trackH + 2 };
}

// Outline around a week within the focused month (month phase); clamped to in-month days.
export function weekOutlineRect(focus: number, week: number, vp: Vp): Rect {
  const g = focusGeom(vp);
  const dim = daysInMonth(focus);
  const s = Math.max(1, weekStartDOM(focus, week));
  const e = Math.min(dim, weekStartDOM(focus, week) + 6);
  return { x: g.x0 + (s - 1) * g.dayW - 1, y: g.bandY - 1, w: (e - s + 1) * g.dayW + 2, h: 4 * g.trackH + 2 };
}

export function weekOfDate(month: number, day: number): number {
  return Math.floor((firstDOW(month) + day - 1) / 7);
}

// Week phase: which day column is under the cursor (may be a spillover day).
export function dayAtPointInWeek(px: number, focus: number, week: number, vp: Vp): { month: number; day: number; week: number } | null {
  const dayW = (vp.w - LABEL_W - 16) / 7;
  if (px < LABEL_W) return null;
  const i = Math.floor((px - LABEL_W) / dayW);
  if (i < 0 || i > 6) return null;
  const r = resolveDate(focus, weekStartDOM(focus, week) + i);
  if (!r) return null;
  return { month: r.month, day: r.day, week: weekOfDate(r.month, r.day) };
}

export { TOP_PAD, LABEL_W };
