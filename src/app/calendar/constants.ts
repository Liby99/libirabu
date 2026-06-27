// Layout constants and small math helpers shared across the calendar.

export const TOP_PAD = 56; // breadcrumb + dates row above the band
export const BOTTOM_PAD = 28; // breathing room below the year-view content when fully scrolled
export const LABEL_W = 250; // left gutter: vertical month name + track-name editor
export const MNAME_W = 28; // width of the rotated month-name zone within the gutter
export const RIGHT_PAD = 24; // gap between the track-name editor and the day grid

export const TRACK_H = 35; // fixed lane height (GridCal topic-row height)
export const MONTH_H = TRACK_H * 4; // a month band = 4 lanes
export const Q_HEADER_H = 24; // day-number header row at the top of each quarter
export const Q_GAP = 32; // separation between quarters

export const lerp = (a: number, b: number, t: number) => a + (b - a) * t;
export const clamp = (v: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, v));
export const easeInOut = (t: number) => (t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2);
