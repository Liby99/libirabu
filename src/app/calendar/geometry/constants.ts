// Layout constants and small math helpers shared across the calendar.
//
// This file is the single source of truth for the calendar's LAYOUT geometry —
// the fixed pixel dimensions every frame is built from. A few of these numbers are
// mirrored in calendar.css; those are bridged at runtime (see styles/) so the value
// only ever lives here. If you add a layout number, prefer putting it here over
// hardcoding it in a component.
//
// (Interaction tuning — gesture thresholds, animation durations — lives next to the
// gesture code in interactions/useCalendarInteractions.ts, where locality matters more
// than central tuning. Pure per-draw offsets live next to their draw call.)

// ── Outer chrome & left gutter ───────────────────────────────────────────────
export const TOP_PAD = 56; // breadcrumb + dates row above the band
export const BAR_H = 32; // top nav bar height — MIRRORED in calendar.css (.cc-bar); keeps its hover/clicks off the canvas
export const BOTTOM_PAD = 28; // breathing room below the year-view content when fully scrolled
export const LABEL_W = 250; // left gutter: vertical month name + track-name editor
export const MNAME_W = 28; // width of the rotated month-name zone within the gutter
export const RIGHT_PAD = 24; // gap between the track-name editor and the day grid

// ── Month band grid ──────────────────────────────────────────────────────────
export const TRACK_H = 35; // fixed lane height (GridCal topic-row height)
export const MONTH_H = TRACK_H * 4; // a month band = 4 lanes
export const Q_HEADER_H = 24; // day-number header row at the top of each quarter
export const Q_GAP = 32; // separation between quarters

// ── Math / easing helpers ────────────────────────────────────────────────────
export const lerp = (a: number, b: number, t: number) => a + (b - a) * t;
export const clamp = (v: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, v));
export const easeInOut = (t: number) => (t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2);

// ── View toggles ─────────────────────────────────────────────────────────────
// Opacity multiplier for events that have already happened, when the "dim past events"
// view toggle (Edit menu) is on.
export const PAST_DIM = 0.4;
