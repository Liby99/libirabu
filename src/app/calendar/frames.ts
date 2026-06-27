// Per-month geometry as a function of the zoom scalar `z`:
//   z = 0  → Year   (months stacked, 3/quarter, 4 quarters)
//   z = 1  → Month  (focused month's band on top, full width)
//   z = 2  → Week   (focused week's 7 days widened; tracks = all-day band)
// Year→Month is a vertical accordion (day width constant); Month→Week is horizontal.

import { Vp, Frame } from "./types";
import {
  TOP_PAD, BOTTOM_PAD, LABEL_W, TRACK_H, MONTH_H, Q_HEADER_H, Q_GAP, lerp, clamp, easeInOut,
} from "./constants";
import { weekStartDOM } from "./dates";

function quarterBlock(): number { return Q_HEADER_H + 3 * MONTH_H; }
export function yearContentH(): number { return 4 * quarterBlock() + 3 * Q_GAP; }
export function yearMaxScroll(vp: Vp): number {
  return Math.max(0, yearContentH() - (vp.h - TOP_PAD - BOTTOM_PAD));
}

// GridCal-style year layout: 4 quarters separated by Q_GAP; within a quarter the 3
// months are flush (no gap); each quarter has a day-number header at its top.
export function yearFrame(m: number, vp: Vp, scrollY: number): Frame {
  const dayW = (vp.w - LABEL_W) / 31;
  const q = Math.floor(m / 3);
  const within = m % 3;
  const quarterTop = q * (quarterBlock() + Q_GAP);
  const bandY = TOP_PAD - scrollY + quarterTop + Q_HEADER_H + within * MONTH_H;
  return { x0: LABEL_W, dayW, bandY, trackH: TRACK_H, opacity: 1 };
}

// Geometry of a month's band at Month level (also used for hit-testing).
export function focusGeom(vp: Vp) {
  return { x0: LABEL_W, dayW: (vp.w - LABEL_W) / 31, bandY: TOP_PAD, trackH: TRACK_H };
}

// Height the day-detail occupies below the focus band at Month level.
function detailFullH(vp: Vp): number { return vp.h - TOP_PAD - MONTH_H - 30; }

// Year→Month accordion: the focus lane scrolls to the top and a detail space opens
// BELOW it (pushing the months below down). Lanes keep their FIXED height and their
// year spacing — above lanes slide up, below lanes get pushed off the bottom.
function yearToMonthFrame(m: number, t: number, focus: number, vp: Vp, scrollY: number): Frame {
  const yf = yearFrame(m, vp, scrollY);
  const yfocus = yearFrame(focus, vp, scrollY);
  const PAD = 80;
  const scroll = (yfocus.bandY - TOP_PAD) * t;
  let bandY = yf.bandY - scroll;
  if (m < focus) bandY -= PAD * t;
  else if (m > focus) bandY += detailFullH(vp) * t + PAD * t;
  return { x0: LABEL_W, dayW: yf.dayW, bandY, trackH: TRACK_H, opacity: 1 };
}

function weekFrame(m: number, focus: number, week: number, vp: Vp): Frame {
  const dayW = (vp.w - LABEL_W) / 7;
  if (m === focus) {
    const startDOM = weekStartDOM(focus, week);
    const x0 = LABEL_W - (startDOM - 1) * dayW; // day=startDOM lands at LABEL_W
    return { x0, dayW, bandY: TOP_PAD, trackH: TRACK_H, opacity: 1 };
  }
  const dir = m < focus ? -1 : 1;
  const off = dir < 0 ? -MONTH_H - 80 : vp.h + 80;
  return { x0: LABEL_W, dayW, bandY: off, trackH: TRACK_H, opacity: 0 };
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

export function frameFor(m: number, z: number, focus: number, week: number, vp: Vp, scrollY: number): Frame {
  if (z <= 1) return yearToMonthFrame(m, easeInOut(clamp(z, 0, 1)), focus, vp, scrollY);
  // month→week: blend the settled Month layout with the Week layout
  const mf = yearToMonthFrame(m, 1, focus, vp, scrollY);
  return blend(mf, weekFrame(m, focus, week, vp), easeInOut(clamp(z - 1, 0, 1)));
}

// Live top of a month's band at the current zoom (so the track-name editor's inputs
// travel with the band instead of disappearing/reappearing).
export function bandYFor(m: number, z: number, focus: number, week: number, vp: Vp, scrollY: number): number {
  return frameFor(m, z, focus, week, vp, scrollY).bandY;
}
