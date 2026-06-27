// Shared types for the calendar layout.

export interface Vp { w: number; h: number }

// A month's geometry at the current zoom: where day 1 sits, day width, band top,
// track-row height, and overall opacity.
export interface Frame { x0: number; dayW: number; bandY: number; trackH: number; opacity: number }

// Cursor-driven hover targets, resolved per zoom bucket. Drives the hierarchical
// hover highlight (a coarse L1 region + a finer L2 cell within it).
export interface Hover {
  month: number | null;     // year view: month band under cursor (focus for month/week views)
  dom: number | null;       // day-of-month under cursor, in `month`'s numbering (may be spillover in week view)
  week: number | null;      // month view: week index under cursor
  hour: number | null;      // week view: hour 0..23 under cursor (snapped, for the cell highlight)
  hourFrac: number | null;  // week view: exact fractional hour 0..24 at the cursor (for the time cursor line)
  nameMonth: number | null; // year view: cursor over the clickable month-name strip → strong highlight + pointer
  nearLeft: boolean | null; // week view: cursor within a threshold of the day column's left edge (deadline + button)
}

// One positioned visual primitive produced by buildScene().
export interface Item {
  key: string;
  kind: "row" | "event" | "monthLabel" | "dayLabel" | "gridline" | "dim" | "hl" | "today" | "now" | "todaytag" | "nowlabel" | "timetag" | "cursor" | "weekdaytag";
  x: number; y: number; w: number; h: number;
  opacity: number;
  z: number; // stacking order (CSS z-index)
  color?: string; // event color key (red/blue/yellow/green) — events only
  text?: string;
  fontSize?: number;
  align?: "left" | "center" | "right";
  cols?: number; // row gridlines: number of day cells (for the dotted verticals)
  lineStyle?: "dashed" | "dotted"; // gridline style; absent = solid separator
  inner?: boolean; // row: an inner lane (t>0) → gets the dotted top separator
}

export interface Scene { items: Item[] }
