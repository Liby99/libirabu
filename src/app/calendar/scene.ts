// Builds the flat list of positioned items to render, for a given zoom state.
// All geometry comes from frames.ts; this file decides WHICH items exist and how
// they're styled at each zoom level.

import { Item, Scene, Frame, Vp } from "./types";
import { LABEL_W, MNAME_W, RIGHT_PAD, Q_HEADER_H, clamp } from "./constants";
import { frameFor } from "./frames";
import { firstDOW, weekStartDOM, weeksInMonth, resolveDate, MONTH_NAMES, WD, WD3 } from "./dates";
import { TRACKS, EVENTS, TIMED, daysInMonth, YEAR } from "./mock";

const LINE = "#4c2d14"; // gridline color (dimmed via item opacity; theme via CSS var)

export function buildScene(z: number, focus: number, week: number, vp: Vp, scrollY: number): Scene {
  const items: Item[] = [];
  buildQuarterHeaders(items, z, focus, week, vp, scrollY);
  buildMonthBands(items, z, focus, week, vp, scrollY);
  buildEvents(items, z, focus, week, vp, scrollY);
  buildDetail(items, z, focus, week, vp, scrollY);
  return { items };
}

const onScreen = (f: Frame, vp: Vp) => f.bandY <= vp.h + 20 && f.bandY + 4 * f.trackH >= -20;

// Quarter day-number headers (1–31) + the first month's top border. Year view only.
function buildQuarterHeaders(items: Item[], z: number, focus: number, week: number, vp: Vp, scrollY: number) {
  const yearVis = clamp(1 - z / 0.4, 0, 1);
  if (yearVis <= 0.02) return;
  const dayW = (vp.w - LABEL_W - 16) / 31;
  for (let q = 0; q < 4; q++) {
    // anchor to the quarter's first month's LIVE band so it travels during the zoom
    const hy = frameFor(q * 3, z, focus, week, vp, scrollY).bandY - Q_HEADER_H;
    if (hy < -Q_HEADER_H || hy > vp.h) continue;
    for (let d = 1; d <= 31; d++) {
      items.push({ key: `qh-${q}-${d}`, kind: "dayLabel", x: LABEL_W + (d - 1) * dayW, y: hy + 5, w: dayW, h: 14, opacity: yearVis * 0.7, text: String(d), fontSize: 10, align: "center", z: 4 });
    }
    // top border: gutter + grid segments with the RIGHT_PAD gap, above the gutter strip
    const topY = hy + Q_HEADER_H - 1;
    items.push({ key: `qhsepg-${q}`, kind: "gridline", x: 0, y: topY, w: LABEL_W - RIGHT_PAD, h: 1, opacity: yearVis * 0.6, color: LINE, z: 11 });
    items.push({ key: `qhsepd-${q}`, kind: "gridline", x: LABEL_W, y: topY, w: 31 * dayW, h: 1, opacity: yearVis * 0.6, color: LINE, z: 11 });
  }
}

// The 12 month bands: vertical name, 4 track lanes, end-of-month dim, month divider.
function buildMonthBands(items: Item[], z: number, focus: number, week: number, vp: Vp, scrollY: number) {
  const dimFade = 1 - clamp(z - 1, 0, 1); // end-of-month hatch fades out entering week view
  for (let m = 0; m < 12; m++) {
    const f = frameFor(m, z, focus, week, vp, scrollY);
    if (f.opacity < 0.02 || !onScreen(f, vp)) continue;
    const dim = daysInMonth(m);
    const fullW = 31 * f.dayW; // always draw all 31 grid cells

    items.push({ key: `ml-${m}`, kind: "monthLabel", x: 0, y: f.bandY, w: MNAME_W, h: f.trackH * 4, opacity: f.opacity, text: MONTH_NAMES[m], fontSize: 13, align: "center", z: 8 });

    for (let t = 0; t < 4; t++) {
      items.push({ key: `row-${m}-${t}`, kind: "row", x: f.x0, y: f.bandY + t * f.trackH, w: fullW, h: f.trackH, opacity: f.opacity, color: TRACKS[t].color, cols: 31, z: 1, inner: t > 0 });
    }
    // dim cells past the month's actual length (e.g. Feb 29–31)
    if (dim < 31 && dimFade > 0.02) {
      items.push({ key: `dim-${m}`, kind: "dim", x: f.x0 + dim * f.dayW, y: f.bandY, w: (31 - dim) * f.dayW, h: 4 * f.trackH, opacity: f.opacity * dimFade, z: 3 });
    }
    // solid divider under each month
    items.push({ key: `msep-${m}`, kind: "gridline", x: f.x0, y: f.bandY + 4 * f.trackH - 1, w: fullW, h: 1, opacity: f.opacity * 0.55, color: LINE, z: 1 });
  }
}

// Multi-day event bars painted on the track lanes.
function buildEvents(items: Item[], z: number, focus: number, week: number, vp: Vp, scrollY: number) {
  for (const ev of EVENTS) {
    const f = frameFor(ev.month, z, focus, week, vp, scrollY);
    if (f.opacity < 0.02 || !onScreen(f, vp)) continue;
    const x = f.x0 + (ev.start - 1) * f.dayW;
    const w = (ev.end - ev.start + 1) * f.dayW;
    if (x + w < -40 || x > vp.w + 40) continue;
    items.push({ key: `ev-${ev.id}`, kind: "event", x: x + 1, y: f.bandY + ev.track * f.trackH + 1, w: Math.max(2, w - 2), h: f.trackH - 2, opacity: f.opacity, color: TRACKS[ev.track].color, text: f.dayW > 14 ? ev.title : undefined, fontSize: 11, z: 2 });
  }
}

// Focused month's headers (dates/weekdays) + 0:00–24:00 timeline + week boundaries.
// Hidden until near Month view, then fades in (keeps the year→month zoom cheap).
function buildDetail(items: Item[], z: number, focus: number, week: number, vp: Vp, scrollY: number) {
  const reveal = z < 0.82 ? 0 : clamp((z - 0.82) / 0.18, 0, 1);
  if (reveal <= 0.02) return;

  const f = frameFor(focus, z, focus, week, vp, scrollY);
  const dim = daysInMonth(focus);
  const colW = f.dayW;
  const bandBottom = f.bandY + 4 * f.trackH;
  const wide = colW > 60; // week view → full weekday names + event titles
  const weekZoom = clamp(z - 1, 0, 1); // 0 at month, 1 at week — gates spillover

  // top border of the focused band (gutter + grid, with the RIGHT_PAD gap)
  items.push({ key: "ftopg", kind: "gridline", x: 0, y: f.bandY - 1, w: LABEL_W - RIGHT_PAD, h: 1, opacity: reveal * 0.6, color: LINE, z: 11 });
  items.push({ key: "ftopd", kind: "gridline", x: LABEL_W, y: f.bandY - 1, w: vp.w - LABEL_W - 6, h: 1, opacity: reveal * 0.6, color: LINE, z: 11 });

  const tlTop = bandBottom + 18;
  const tlBottom = vp.h - 8;
  const hasTL = tlBottom > tlTop;
  const hourH = hasTL ? (tlBottom - tlTop) / 24 : 0;

  // hour grid: every hour in week (even=dashed/odd=dotted), every 6h in month
  if (hasTL) {
    for (let hr = 0; hr <= 24; hr += wide ? 1 : 6) {
      const y = tlTop + hr * hourH;
      const even = hr % 2 === 0;
      items.push({ key: `hl-${hr}`, kind: "gridline", x: LABEL_W, y, w: vp.w - LABEL_W - 6, h: 1, opacity: reveal * (even ? 0.22 : 0.12), color: LINE, z: 0, lineStyle: even ? "dashed" : "dotted" });
      if (hr % (wide ? 2 : 6) === 0) {
        items.push({ key: `ht-${hr}`, kind: "dayLabel", x: LABEL_W - 46, y: y - 7, w: 42, h: 14, opacity: reveal * 0.7, text: `${String(hr).padStart(2, "0")}:00`, fontSize: 9, align: "center", z: 9 });
      }
    }
  }

  // one day column: date above band, weekday below, dotted divider + timed events
  const pushDay = (dom: number, op: number) => {
    const r = resolveDate(focus, dom);
    if (!r) return;
    const x = f.x0 + (dom - 1) * colW;
    if (x + colW < -40 || x > vp.w + 40) return;
    const dow = new Date(YEAR, r.month, r.day).getDay();
    const dateText = r.month === focus ? String(r.day) : `${MONTH_NAMES[r.month]} ${r.day}`;
    items.push({ key: `date-${dom}`, kind: "dayLabel", x, y: f.bandY - 20, w: colW, h: 16, opacity: op, text: dateText, fontSize: wide ? 13 : 10, align: "center", z: 4 });
    items.push({ key: `wd-${dom}`, kind: "dayLabel", x, y: bandBottom + 2, w: colW, h: 14, opacity: op * 0.9, text: wide ? WD3[dow] : WD[dow], fontSize: wide ? 11 : 9, align: "center", z: 4 });
    if (!hasTL) return;
    const isWeekStart = (((firstDOW(focus) + dom - 1) % 7) + 7) % 7 === 0;
    if (!isWeekStart) {
      items.push({ key: `tdv-${dom}`, kind: "gridline", x, y: tlTop, w: 1, h: tlBottom - tlTop, opacity: op * 0.4, color: LINE, z: 0, lineStyle: "dotted" });
    }
    for (const ev of TIMED) {
      if (ev.month !== r.month || ev.day !== r.day) continue;
      items.push({ key: `te-${ev.id}`, kind: "event", x: x + 2, y: tlTop + ev.startHour * hourH, w: Math.max(3, colW - 4), h: Math.max(3, (ev.endHour - ev.startHour) * hourH), opacity: op, color: TRACKS[ev.track].color, text: wide ? ev.title : undefined, fontSize: 11, z: 2 });
    }
  };

  for (let d = 1; d <= dim; d++) pushDay(d, reveal);

  // dashed Sunday-aligned week boundaries spanning band + timeline
  const bottom = hasTL ? tlBottom : bandBottom;
  for (let w = 0; w <= weeksInMonth(focus); w++) {
    const x = f.x0 + (weekStartDOM(focus, w) - 1) * colW;
    if (x < LABEL_W - 2 || x > vp.w + 2) continue;
    items.push({ key: `wkb-${w}`, kind: "gridline", x: x - 1, y: f.bandY, w: 1, h: bottom - f.bandY, opacity: reveal * 0.4, color: LINE, z: 1, lineStyle: "dashed" });
  }

  // spillover days (prev/next month) + month-boundary lines — fade in toward week view
  if (weekZoom > 0.01) {
    const lead = weekStartDOM(focus, 0); // ≤ 1
    const tail = weekStartDOM(focus, weeksInMonth(focus) - 1) + 6; // ≥ dim
    for (let dom = lead; dom <= 0; dom++) pushDay(dom, weekZoom * 0.5);
    for (let dom = dim + 1; dom <= tail; dom++) pushDay(dom, weekZoom * 0.5);
    for (const bx of [1, dim + 1]) {
      const x = f.x0 + (bx - 1) * colW;
      if (x < -2 || x > vp.w + 2) continue;
      items.push({ key: `mb-${bx}`, kind: "gridline", x: x - 1, y: f.bandY - 6, w: 1.5, h: tlBottom - (f.bandY - 6), opacity: weekZoom * 0.7, color: LINE, z: 5 });
    }
  }
}
