// Screen geometry for all-day (band) events, using each month's frame.

import { Vp } from "./types";
import { LABEL_W } from "./constants";
import { frameFor, type MonthAnim } from "./frames";
import { daysInMonth } from "./mock";
import { BandEvent } from "./bandEventTypes";

// clipStart/clipEnd flag a bar whose true start/end edge sits off-screen (week-view
// spillover) — so the bar stays clamped to the visible band and we hide the resize
// handle for the off-screen edge.
export interface BandRect { x: number; y: number; w: number; h: number; clipStart: boolean; clipEnd: boolean }

const bandOnScreen = (bandY: number, trackH: number, vp: Vp) =>
  bandY <= vp.h + 10 && bandY + 4 * trackH >= -10;

export function bandEventRect(ev: BandEvent, z: number, focus: number, week: number, vp: Vp, scrollY: number, anim?: MonthAnim | null): BandRect | null {
  const f = frameFor(ev.month, z, focus, week, vp, scrollY, anim);
  if (f.opacity < 0.02 || !bandOnScreen(f.bandY, f.trackH, vp)) return null;
  const x = f.x0 + (ev.startDay - 1) * f.dayW;
  const w = (ev.endDay - ev.startDay + 1) * f.dayW;
  const leftRaw = x + 1;
  const rightRaw = x + w - 1;
  // Clamp horizontally to the visible band [LABEL_W, vp.w]; in week view this keeps a
  // spilled-over bar (and its title) anchored in-view instead of hidden behind the gutter.
  const left = Math.max(leftRaw, LABEL_W);
  const right = Math.min(rightRaw, vp.w);
  if (right - left < 2) return null;
  return {
    x: left,
    y: f.bandY + ev.track * f.trackH + 2, // 2px top/bottom margin within the lane
    w: Math.max(2, right - left),
    h: Math.max(3, f.trackH - 4),
    clipStart: leftRaw < LABEL_W - 0.5,
    clipEnd: rightRaw > vp.w + 0.5,
  };
}

// Which month band / track lane / day is under the cursor (for create-start + move).
export function bandSlotAtPoint(px: number, py: number, z: number, focus: number, week: number, vp: Vp, scrollY: number): { month: number; track: number; day: number } | null {
  if (px < LABEL_W) return null;
  for (let m = 0; m < 12; m++) {
    const f = frameFor(m, z, focus, week, vp, scrollY);
    if (f.opacity < 0.02 || !bandOnScreen(f.bandY, f.trackH, vp)) continue;
    if (py < f.bandY || py >= f.bandY + 4 * f.trackH) continue;
    const dim = daysInMonth(m);
    const day = Math.floor((px - f.x0) / f.dayW) + 1;
    if (day < 1 || day > dim) continue;
    return { month: m, track: Math.min(3, Math.max(0, Math.floor((py - f.bandY) / f.trackH))), day };
  }
  return null;
}

// Clamped day within a fixed month (for the moving endpoint of a create/move drag).
export function dayInMonth(px: number, month: number, z: number, focus: number, week: number, vp: Vp, scrollY: number): number {
  const f = frameFor(month, z, focus, week, vp, scrollY);
  return Math.min(daysInMonth(month), Math.max(1, Math.floor((px - f.x0) / f.dayW) + 1));
}
