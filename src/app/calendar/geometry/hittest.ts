// Cursor → calendar-element hit-tests, per zoom phase.

import { Vp } from "./types";
import { LABEL_W, MNAME_W } from "./constants";
import { yearFrame, focusGeom, frameFor } from "./frames";
import { timelineInfo, pointToSlot } from "./eventGeom";
import { firstDOW, weeksInMonth, weekOfDate, resolveDate } from "../util/dates";
import { daysInMonth } from "../model/api/mock";

// Year phase: which month's NAME (left gutter zone) is under the cursor — so only
// clicking the month name opens month view (not clicking the lane).
export function monthNameAtPoint(px: number, py: number, vp: Vp, scrollY: number): number | null {
  if (px < 0 || px > MNAME_W) return null;
  for (let m = 0; m < 12; m++) {
    const f = yearFrame(m, vp, scrollY);
    if (py >= f.bandY && py <= f.bandY + 4 * f.trackH) return m;
  }
  return null;
}

// Year phase: which month is under the cursor (anywhere in its band).
export function monthAtPoint(px: number, py: number, vp: Vp, scrollY: number): number | null {
  for (let m = 0; m < 12; m++) {
    const f = yearFrame(m, vp, scrollY);
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

// Year phase (hover): which month's full band ROW is under the cursor, including the
// left gutter (month name + track-name inputs), so hovering those highlights the month.
export function monthRowAtPoint(px: number, py: number, vp: Vp, scrollY: number): number | null {
  if (px < 0) return null;
  for (let m = 0; m < 12; m++) {
    const f = yearFrame(m, vp, scrollY);
    const dim = daysInMonth(m);
    if (py >= f.bandY && py <= f.bandY + 4 * f.trackH && px <= f.x0 + dim * f.dayW) return m;
  }
  return null;
}

// Year phase (hover): day-of-month under the cursor within month m's band (1..dim).
export function domInMonthBand(px: number, m: number, vp: Vp, scrollY: number): number | null {
  const f = yearFrame(m, vp, scrollY);
  const dim = daysInMonth(m);
  if (px < f.x0 || px > f.x0 + dim * f.dayW) return null;
  return Math.min(Math.max(Math.floor((px - f.x0) / f.dayW) + 1, 1), dim);
}

// Month phase (hover): day-of-month under the cursor in the focused month (1..dim).
export function domInFocus(px: number, focus: number, vp: Vp): number | null {
  const g = focusGeom(vp);
  const dim = daysInMonth(focus);
  if (px < g.x0 || px > g.x0 + dim * g.dayW) return null;
  return Math.min(Math.max(Math.floor((px - g.x0) / g.dayW) + 1, 1), dim);
}

// Week phase (hover): the day column (focus-relative dom, may be spillover) and the
// hour row (0..23) under the cursor. Mirrors the scene's week-view timeline geometry.
const ADD_EDGE_THRESHOLD = 26; // px from a day column's left edge that reveals the deadline + button

export function cellInWeek(px: number, py: number, z: number, focus: number, week: number, vp: Vp, scrollY: number, tlScroll: number): { dom: number | null; hour: number | null; hourFrac: number | null; nearLeft: boolean } {
  const tl = timelineInfo(z, focus, week, vp, scrollY, tlScroll);
  const { dom, hourFrac } = pointToSlot(px, py, tl); // hourFrac already accounts for scroll
  const inTL = tl.hourH > 0 && py >= tl.tlTop && py <= tl.tlBottom;
  const edgePx = dom != null ? px - (tl.x0 + (dom - 1) * tl.colW) : Infinity; // distance right of the column's left edge
  return {
    dom,
    hour: inTL ? Math.min(23, Math.max(0, Math.floor(hourFrac))) : null,
    hourFrac: inTL ? Math.round(hourFrac * 60) / 60 : null, // snap to the minute
    nearLeft: inTL && edgePx >= 0 && edgePx < ADD_EDGE_THRESHOLD,
  };
}

// Week phase: which day column is under the cursor (may be a spillover day). Uses the LIVE
// frame (fractional `week` → arbitrary day-aligned start), matching the rendered columns and
// the create path's `pointToSlot` — `dom = floor((px - x0)/colW) + 1`.
export function dayAtPointInWeek(px: number, z: number, focus: number, week: number, vp: Vp, scrollY: number): { month: number; day: number; week: number } | null {
  if (px < LABEL_W) return null;
  const f = frameFor(focus, z, focus, week, vp, scrollY);
  if (f.dayW <= 0) return null;
  const dom = Math.floor((px - f.x0) / f.dayW) + 1; // focus-relative; may be a spillover day
  const r = resolveDate(focus, dom);
  if (!r) return null;
  return { month: r.month, day: r.day, week: weekOfDate(r.month, r.day) };
}
