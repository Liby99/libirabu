// Per-month geometry as a function of the zoom scalar `z`:
//   z = 0  → Year   (months stacked, 3/quarter, 4 quarters)
//   z = 1  → Month  (focused month's band on top, full width)
//   z = 2  → Week   (focused week's 7 days widened; tracks = all-day band)
//   z = 3  → Day    (one day's column at the left + the daily-dashboard on the right)
// Year→Month is a vertical accordion (day width constant); Month→Week→Day are horizontal.

import { Vp, Frame } from "./types";
import {
  TOP_PAD, BOTTOM_PAD, LABEL_W, TRACK_H, MONTH_H, Q_HEADER_H, Q_GAP, lerp, clamp, easeInOut,
} from "./constants";
import { weekStartDOM } from "../util/dates";

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
  const PAD = 80; // vertical gap opened above/below the focused month as the year view expands into it
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

// Vertical month-to-month paging (month view). `dir` +1 = swipe up → next month, −1 = swipe
// down → prev; `p` ∈ [0,1] is the transition progress. The current month's band and the target
// month's band slide vertically like stacked pages; every other month is hidden. (The daily
// timeline cross-fades separately via detailMul — see scene.ts / eventGeom.ts.)
export interface MonthAnim { dir: 1 | -1; p: number }

function monthSwipeFrame(m: number, anim: MonthAnim, focus: number, vp: Vp): Frame {
  const { dir, p } = anim;
  const to = focus + dir;
  const base = { x0: LABEL_W, dayW: (vp.w - LABEL_W) / 31, trackH: TRACK_H };
  const OFF_TOP = -MONTH_H - 40; // a band fully above the viewport
  const OFF_BOT = vp.h + 40;     // a band fully below the viewport
  if (m === focus) {
    // Current band: swipe-up → hold at top then exit the TOP in the back half; swipe-down →
    // move straight down and out the BOTTOM.
    const bandY = dir > 0
      ? lerp(TOP_PAD, OFF_TOP, easeInOut(clamp((p - 0.5) / 0.5, 0, 1)))
      : lerp(TOP_PAD, OFF_BOT, easeInOut(p));
    return { ...base, bandY, opacity: 1 };
  }
  if (m === to) {
    // Target band: swipe-up → rise from the BOTTOM to the top; swipe-down → descend from the
    // TOP and settle at the top (~65% through, then hold).
    const bandY = dir > 0
      ? lerp(OFF_BOT, TOP_PAD, easeInOut(p))
      : lerp(OFF_TOP, TOP_PAD, easeInOut(clamp(p / 0.65, 0, 1)));
    return { ...base, bandY, opacity: 1 };
  }
  return { ...base, bandY: OFF_BOT, opacity: 0 };
}

// ── Daily view (z = 3) ──────────────────────────────────────────────────────
// The chosen day (focus-relative day-of-month) and the fraction of the content area its timeline
// occupies (the rest is the daily-dashboard). Held at module level — synced from React each render
// (same pattern as YEAR in mock.ts / the week hour-height in eventGeom.ts) — so dayFrame/dailyFade
// stay param-free across their many call sites. `_dailyFrac` is a single dial today; later it can
// be driven by a resize handle and everything (timeline width + dashboard) re-solves from it.
// Daily↔daily paging: the page-turn direction (+1 = next day) and progress 0→1. While active, the
// whole day column pans by one column-width so the current day slides out and the next slides in.
export interface DayAnim { dir: 1 | -1; p: number }

let _dailyDom = 1;
let _dailyFrac = 0.45;
let _dayAnim: DayAnim | null = null;
let _dayOver = 0; // overscroll rubber-band offset (px) at a month boundary — nudges the day column only
export function setDaily(dom: number, frac: number, anim: DayAnim | null = null, over = 0) { _dailyDom = dom; _dailyFrac = clamp(frac, 1 / 7, 0.6); _dayAnim = anim; _dayOver = over; }
export function getDailyDom() { return _dailyDom; }
export function getDailyFrac() { return _dailyFrac; }
// Day-detail opacity for a focus-relative day-of-month at zoom z. In a day page-turn it cross-fades
// the outgoing day out and the incoming day in; otherwise 1 in week view, fading the non-chosen
// days to 0 as z → 3 so only the chosen day's content remains in daily view.
export function dailyFade(dom: number, z: number): number {
  if (_dayAnim) {
    if (dom === _dailyDom) return 1 - _dayAnim.p;            // outgoing day fades out as it slides
    if (dom === _dailyDom + _dayAnim.dir) return _dayAnim.p; // incoming day fades in as it slides
    return 0;
  }
  if (z <= 2) return 1;
  return dom === _dailyDom ? 1 : 1 - clamp(z - 2, 0, 1);
}

// Week→Day: the chosen day's column widens to `_dailyFrac` of the content area and pans so it
// lands at the left edge (LABEL_W) — the old left-most day slot. Other days widen/pan the same
// way but fade out (dailyFade); the freed right area becomes the daily-dashboard. During a day
// page-turn the column additionally pans by one width (−dir·p·colW) so the days slide across.
function dayFrame(m: number, focus: number, vp: Vp): Frame {
  const dayW = _dailyFrac * (vp.w - LABEL_W);
  const pan = (_dayAnim ? -_dayAnim.dir * _dayAnim.p * dayW : 0) + _dayOver; // day-paging slide + boundary overscroll
  if (m === focus) {
    const x0 = LABEL_W - (_dailyDom - 1) * dayW + pan; // day=_dailyDom lands at LABEL_W (panned during paging)
    return { x0, dayW, bandY: TOP_PAD, trackH: TRACK_H, opacity: 1 };
  }
  // Park off-screen on the SAME side weekFrame does, so the week→day blend keeps a hidden band
  // hidden (rather than sweeping it vertically across the viewport during the transition).
  const off = m < focus ? -MONTH_H - 80 : vp.h + 80;
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

export function frameFor(m: number, z: number, focus: number, week: number, vp: Vp, scrollY: number, anim?: MonthAnim | null): Frame {
  if (anim) return monthSwipeFrame(m, anim, focus, vp); // month↕month paging overrides (z held at 1)
  if (z <= 1) return yearToMonthFrame(m, easeInOut(clamp(z, 0, 1)), focus, vp, scrollY);
  const wf = weekFrame(m, focus, week, vp);
  // month→week: blend the settled Month layout with the Week layout
  if (z <= 2) {
    const mf = yearToMonthFrame(m, 1, focus, vp, scrollY);
    return blend(mf, wf, easeInOut(clamp(z - 1, 0, 1)));
  }
  // week→day: blend the Week layout with the single-day layout
  return blend(wf, dayFrame(m, focus, vp), easeInOut(clamp(z - 2, 0, 1)));
}

// Live top of a month's band at the current zoom (so the track-name editor's inputs
// travel with the band instead of disappearing/reappearing).
export function bandYFor(m: number, z: number, focus: number, week: number, vp: Vp, scrollY: number, anim?: MonthAnim | null): number {
  return frameFor(m, z, focus, week, vp, scrollY, anim).bandY;
}
