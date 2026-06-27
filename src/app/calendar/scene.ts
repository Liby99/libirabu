// Builds the flat list of positioned items to render, for a given zoom state.
// All geometry comes from frames.ts; this file decides WHICH items exist and how
// they're styled at each zoom level.

import { Item, Scene, Frame, Vp, Hover } from "./types";
import { LABEL_W, MNAME_W, RIGHT_PAD, Q_HEADER_H, clamp } from "./constants";
import { frameFor } from "./frames";
import { firstDOW, weekStartDOM, weeksInMonth, resolveDate, MONTH_NAMES, WD, WD3 } from "./dates";
import { TRACKS, daysInMonth, YEAR, setCalendarYear } from "./mock";
import { hourMetrics } from "./eventGeom";

const LINE = "#4c2d14"; // gridline color (dimmed via item opacity; theme via CSS var)
const HL_SOFT = 0.05;   // L1 coarse highlight (month band / week span / day column)
const HL_STRONG = 0.11; // L2 fine highlight (day column / hour cell)

export function buildScene(z: number, focus: number, week: number, vp: Vp, scrollY: number, hover: Hover, now: number, year: number, altDeltaHours: number | null, altLabel: string | null, tlScroll: number): Scene {
  setCalendarYear(year); // sync the live YEAR binding before any date math this frame
  const items: Item[] = [];
  buildHover(items, z, focus, week, vp, scrollY, hover, tlScroll); // first → its z:3 layers sit under labels
  buildToday(items, z, focus, week, vp, scrollY, now, tlScroll);
  buildQuarterHeaders(items, z, focus, week, vp, scrollY);
  buildMonthBands(items, z, focus, week, vp, scrollY);
  buildDetail(items, z, focus, week, vp, scrollY, altDeltaHours, altLabel, tlScroll);
  return { items };
}

// "Today" markers + the live current-time line. Like buildHover, emits a fixed set
// of persistent layers (stable keys, opacity 0 when not applicable) so they fade and
// cross-fade with the same transitions. Only shown when the displayed year (YEAR) is
// the current calendar year. `now` is a ms timestamp that ticks each minute.
function buildToday(items: Item[], z: number, focus: number, week: number, vp: Vp, scrollY: number, now: number, tlScroll: number) {
  const d = new Date(now);
  const present = d.getFullYear() === YEAR;
  const tMonth = d.getMonth();
  const tDom = d.getDate();
  const nowFrac = d.getHours() + d.getMinutes() / 60; // 0..24
  const timeStr = `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;

  // today's day expressed in `focus`'s numbering (≤0 / >dim when it's a spillover day)
  const relDom = tMonth === focus ? tDom
    : tMonth === focus - 1 ? tDom - daysInMonth(focus - 1)
    : tMonth === focus + 1 ? daysInMonth(focus) + tDom
    : null;

  // "Current Time / HH:MM" label beside the now line. Placed on the side with more
  // room: column in the first half → label to its right (left-aligned); latter half
  // → to its left (right-aligned).
  const pushNowLabel = (key: string, x: number, colW: number, lineY: number, active: boolean) => {
    const W = 84, GAP = 10, H = 30;
    const firstHalf = x + colW / 2 < (LABEL_W + vp.w) / 2;
    items.push({
      key, kind: "nowlabel", text: timeStr, align: firstHalf ? "left" : "right",
      x: firstHalf ? x + colW + GAP : x - GAP - W, y: lineY - H / 2, w: W, h: H,
      opacity: active ? 1 : 0, z: 9,
    });
  };

  // ── Year: today's day column in its month band ──
  {
    const f = frameFor(tMonth, z, focus, week, vp, scrollY);
    const on = present && z < 0.5 && onScreen(f, vp);
    const tx = f.x0 + (tDom - 1) * f.dayW;
    items.push({ key: "td-y", kind: "today", x: tx, y: f.bandY, w: f.dayW, h: 4 * f.trackH, opacity: on ? 1 : 0, z: 3 });
    // "TODAY" caption just below the marker
    const tagW = 54;
    items.push({ key: "td-tag", kind: "todaytag", text: "TODAY", x: tx + f.dayW / 2 - tagW / 2, y: f.bandY + 4 * f.trackH + 3, w: tagW, h: 11, opacity: on ? 1 : 0, fontSize: 8, align: "center", z: 9 });
  }

  // ── Month: today's column (band + timeline) + now line, only if focus is today's month ──
  {
    const active = present && z >= 0.5 && z < 1.5 && focus === tMonth;
    const f = frameFor(focus, z, focus, week, vp, scrollY);
    const colW = f.dayW;
    const tlTop = f.bandY + 4 * f.trackH + 18;
    const tlBottom = vp.h - 8;
    const detail = z >= 0.82;
    const x = f.x0 + (tDom - 1) * colW;
    items.push({ key: "td-m", kind: "today", x, y: f.bandY, w: colW, h: (detail ? tlBottom : f.bandY + 4 * f.trackH) - f.bandY, opacity: active ? 1 : 0, z: 3 });
    const { hourH, scroll } = hourMetrics(tlTop, tlBottom, z, tlScroll);
    const lineY = tlTop + nowFrac * hourH - scroll;
    const lineOn = active && detail && hourH > 0 && lineY >= tlTop && lineY <= tlBottom;
    items.push({ key: "now-m", kind: "now", x, y: lineY, w: colW, h: 2, opacity: lineOn ? 1 : 0, z: 6 });
    pushNowLabel("nl-m", x, colW, lineY, lineOn);
  }

  // ── Week: today's column (band + timeline) + now line, only if today is in the focused week ──
  {
    const wk = Math.round(week);
    const inWeek = relDom != null && relDom >= weekStartDOM(focus, wk) && relDom <= weekStartDOM(focus, wk) + 6;
    const active = present && z >= 1.5 && inWeek;
    const f = frameFor(focus, z, focus, week, vp, scrollY);
    const colW = f.dayW;
    const tlTop = f.bandY + 4 * f.trackH + 18;
    const tlBottom = vp.h - 8;
    const x = f.x0 + ((relDom ?? 1) - 1) * colW;
    items.push({ key: "td-w", kind: "today", x, y: f.bandY, w: colW, h: tlBottom - f.bandY, opacity: active ? 1 : 0, z: 3 });
    const { hourH, scroll } = hourMetrics(tlTop, tlBottom, z, tlScroll);
    const lineY = tlTop + nowFrac * hourH - scroll;
    const lineOn = active && hourH > 0 && lineY >= tlTop && lineY <= tlBottom;
    items.push({ key: "now-w", kind: "now", x, y: lineY, w: colW, h: 2, opacity: lineOn ? 1 : 0, z: 6 });
    pushNowLabel("nl-w", x, colW, lineY, lineOn);
  }
}

// Hierarchical hover highlight. Emits a FIXED set of persistent layers (stable
// keys) — one coarse (L1) + one fine (L2) per zoom level — repositioned each frame
// and faded via opacity (0 when inactive). Stable keys let React reuse the nodes,
// so the CSS `transition` on .cc-hl animates the dim/brighten and cross-fades
// between levels as you zoom (month tint fades out while week tint fades in).
function buildHover(items: Item[], z: number, focus: number, week: number, vp: Vp, scrollY: number, hover: Hover, tlScroll: number) {
  const h = hover ?? { month: null, dom: null, week: null, hour: null };

  // ── Year: hovered month band (soft) + day column across its 4 lanes (strong) ──
  {
    const m = h.month ?? focus;
    const f = frameFor(m, z, focus, week, vp, scrollY);
    const dim = daysInMonth(m);
    const bandH = 4 * f.trackH;
    const monthOn = z < 0.5 && h.month != null && onScreen(f, vp);
    items.push({ key: "hl-ym", kind: "hl", x: f.x0, y: f.bandY, w: dim * f.dayW, h: bandH, opacity: monthOn ? HL_SOFT : 0, z: 3 });
    // left gutter (vertical month name + track-name inputs): own layer at z:6 so it
    // sits ABOVE the opaque .cc-gutter strip (z:5) but below the name/inputs.
    items.push({ key: "hl-yg", kind: "hl", x: 0, y: f.bandY, w: LABEL_W, h: bandH, opacity: monthOn ? HL_SOFT : 0, z: 6 });
    // month-name strip: strong (L2) highlight when the cursor is over the clickable name.
    const nameOn = z < 0.5 && h.nameMonth != null && onScreen(f, vp);
    items.push({ key: "hl-yn", kind: "hl", x: 0, y: f.bandY, w: MNAME_W, h: bandH, opacity: nameOn ? HL_STRONG : 0, z: 7 });
    const dcol = h.dom ?? 1;
    const dayOn = monthOn && h.dom != null && h.dom >= 1 && h.dom <= dim;
    items.push({ key: "hl-yd", kind: "hl", x: f.x0 + (dcol - 1) * f.dayW, y: f.bandY, w: f.dayW, h: bandH, opacity: dayOn ? HL_STRONG : 0, z: 3 });
    // small weekday chip above the hovered day column (Mon, Tue, …)
    const wdow = new Date(YEAR, m, dcol).getDay();
    items.push({ key: "hl-ywd", kind: "weekdaytag", text: WD3[wdow], x: f.x0 + (dcol - 1) * f.dayW, y: f.bandY - 15, w: f.dayW, h: 13, opacity: dayOn ? 1 : 0, fontSize: 8.5, align: "center", z: 9 });
  }

  // ── Month: hovered week span (soft) + day column (strong), spanning band+timeline ──
  {
    const active = z >= 0.5 && z < 1.5;
    const f = frameFor(focus, z, focus, week, vp, scrollY);
    const dim = daysInMonth(focus);
    const colW = f.dayW;
    const top = f.bandY;
    const bottom = z >= 0.82 ? vp.h - 8 : f.bandY + 4 * f.trackH; // timeline only once it reveals
    let wx = f.x0, ww = 0;
    if (h.week != null) {
      const ws = weekStartDOM(focus, h.week); // ≤1 at the leading edge
      const startCol = Math.max(0, ws - 1);
      const endCol = Math.min(dim, ws - 1 + 7);
      wx = f.x0 + startCol * colW;
      ww = Math.max(0, (endCol - startCol) * colW);
    }
    items.push({ key: "hl-mw", kind: "hl", x: wx, y: top, w: ww, h: bottom - top, opacity: active && ww > 0 ? HL_SOFT : 0, z: 3 });
    const dcol = h.dom ?? 1;
    const dayOn = active && h.dom != null && h.dom >= 1 && h.dom <= dim;
    items.push({ key: "hl-md", kind: "hl", x: f.x0 + (dcol - 1) * colW, y: top, w: colW, h: bottom - top, opacity: dayOn ? HL_STRONG : 0, z: 3 });
  }

  // ── Week: hovered day column (soft) + hour cell within it (strong) ──
  {
    const active = z >= 1.5;
    const f = frameFor(focus, z, focus, week, vp, scrollY);
    const colW = f.dayW;
    const tlTop = f.bandY + 4 * f.trackH + 18;
    const tlBottom = vp.h - 8;
    const { hourH, scroll } = hourMetrics(tlTop, tlBottom, z, tlScroll);
    const dcol = h.dom ?? 1;
    const x = f.x0 + (dcol - 1) * colW;
    items.push({ key: "hl-wd", kind: "hl", x, y: f.bandY, w: colW, h: tlBottom - f.bandY, opacity: active && h.dom != null ? HL_SOFT : 0, z: 3 });
    // hovered hour cell — scrolled + clamped to the visible timeline window
    const rawHy = h.hour != null ? tlTop + h.hour * hourH - scroll : tlTop;
    const cellTop = Math.max(tlTop, rawHy), cellBot = Math.min(tlBottom, rawHy + hourH);
    const hourOn = active && h.dom != null && h.hour != null && hourH > 0 && cellBot > cellTop;
    items.push({ key: "hl-wh", kind: "hl", x, y: cellTop, w: colW, h: Math.max(0, cellBot - cellTop), opacity: hourOn ? HL_STRONG : 0, z: 3 });

    // cursor: a Current-Time-style line at the exact mouse position + a "HH:MM" tag
    const hf = h.hourFrac ?? 0;
    const cy = tlTop + hf * hourH - scroll;
    const curOn = active && h.dom != null && h.hourFrac != null && hourH > 0 && cy >= tlTop && cy <= tlBottom;
    items.push({ key: "cur-line", kind: "cursor", x, y: cy, w: colW, h: 2, opacity: curOn ? 1 : 0, z: 7 });
    const total = Math.round(hf * 60);
    const tStr = `${String(Math.floor(total / 60) % 24).padStart(2, "0")}:${String(total % 60).padStart(2, "0")}`;
    const firstHalf = x + colW / 2 < (LABEL_W + vp.w) / 2;
    const TW = 44, GAP = 10, TH = 20;
    items.push({
      key: "cur-tag", kind: "timetag", text: tStr, align: firstHalf ? "left" : "right",
      x: firstHalf ? x + colW + GAP : x - GAP - TW, y: cy - TH / 2, w: TW, h: TH,
      opacity: curOn ? 1 : 0, z: 9,
    });
  }
}

const onScreen = (f: Frame, vp: Vp) => f.bandY <= vp.h + 20 && f.bandY + 4 * f.trackH >= -20;

// Quarter day-number headers (1–31) + the first month's top border. Year view only.
function buildQuarterHeaders(items: Item[], z: number, focus: number, week: number, vp: Vp, scrollY: number) {
  const yearVis = clamp(1 - z / 0.4, 0, 1);
  if (yearVis <= 0.02) return;
  const dayW = (vp.w - LABEL_W) / 31;
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

// Focused month's headers (dates/weekdays) + 0:00–24:00 timeline + week boundaries.
// Hidden until near Month view, then fades in (keeps the year→month zoom cheap).
function buildDetail(items: Item[], z: number, focus: number, week: number, vp: Vp, scrollY: number, altDeltaHours: number | null, altLabel: string | null, tlScroll: number) {
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
  items.push({ key: "ftopd", kind: "gridline", x: LABEL_W, y: f.bandY - 1, w: vp.w - LABEL_W, h: 1, opacity: reveal * 0.6, color: LINE, z: 11 });

  const tlTop = bandBottom + 18;
  const tlBottom = vp.h - 8;
  const hasTL = tlBottom > tlTop;
  const { hourH, scroll } = hasTL ? hourMetrics(tlTop, tlBottom, z, tlScroll) : { hourH: 0, scroll: 0 };

  // hour grid: every hour in week (even=dashed/odd=dotted), every 6h in month.
  // Lines/labels scroll by `scroll` and are culled outside the visible window.
  // Secondary timezone axis (week view only): alt-tz hour labels left of the main
  // labels, plus a vertical bar between them.
  const altOn = altDeltaHours != null && wide;
  if (hasTL) {
    for (let hr = 0; hr <= 24; hr += wide ? 1 : 6) {
      const y = tlTop + hr * hourH - scroll;
      if (y < tlTop - 0.5 || y > tlBottom + 0.5) continue; // scrolled out of view
      const even = hr % 2 === 0;
      items.push({ key: `hl-${hr}`, kind: "gridline", x: LABEL_W, y, w: vp.w - LABEL_W, h: 1, opacity: reveal * (even ? 0.22 : 0.12), color: LINE, z: 0, lineStyle: even ? "dashed" : "dotted" });
      if (hr % (wide ? 2 : 6) === 0) {
        items.push({ key: `ht-${hr}`, kind: "dayLabel", x: LABEL_W - 46, y: y - 7, w: 42, h: 14, opacity: reveal * 0.7, text: `${String(hr).padStart(2, "0")}:00`, fontSize: 9, align: "center", z: 9 });
        if (altOn) {
          const t = ((Math.round((hr + altDeltaHours!) * 60) % 1440) + 1440) % 1440;
          const txt = `${String(Math.floor(t / 60)).padStart(2, "0")}:${String(t % 60).padStart(2, "0")}`;
          items.push({ key: `hta-${hr}`, kind: "dayLabel", x: LABEL_W - 92, y: y - 7, w: 42, h: 14, opacity: reveal * 0.7, text: txt, fontSize: 9, align: "center", z: 9 });
        }
      }
    }
    if (altOn) {
      items.push({ key: "tzaxis", kind: "gridline", x: LABEL_W - 50, y: tlTop, w: 1, h: tlBottom - tlTop, opacity: reveal * 0.35, color: LINE, z: 9 });
      if (altLabel) items.push({ key: "tzhdr", kind: "dayLabel", x: LABEL_W - 92, y: tlTop - 16, w: 42, h: 12, opacity: reveal * 0.85, text: altLabel, fontSize: 9, align: "center", z: 9 });
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
