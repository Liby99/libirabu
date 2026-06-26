// Cursor → calendar-element hit-tests, per zoom phase.

import { Vp } from "./types";
import { LABEL_W, MNAME_W } from "./constants";
import { yearFrame, focusGeom } from "./frames";
import { firstDOW, weeksInMonth, weekStartDOM, weekOfDate, resolveDate } from "./dates";
import { daysInMonth } from "./mock";

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
