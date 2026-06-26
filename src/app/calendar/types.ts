// Shared types for the calendar layout.

export interface Vp { w: number; h: number }

// A month's geometry at the current zoom: where day 1 sits, day width, band top,
// track-row height, and overall opacity.
export interface Frame { x0: number; dayW: number; bandY: number; trackH: number; opacity: number }

// One positioned visual primitive produced by buildScene().
export interface Item {
  key: string;
  kind: "row" | "event" | "monthLabel" | "dayLabel" | "gridline" | "dim";
  x: number; y: number; w: number; h: number;
  opacity: number;
  z: number; // stacking order (CSS z-index)
  color?: string; // event color key (red/blue/yellow/green) — events only
  text?: string;
  fontSize?: number;
  align?: "left" | "center";
  cols?: number; // row gridlines: number of day cells (for the dotted verticals)
  lineStyle?: "dashed" | "dotted"; // gridline style; absent = solid separator
  inner?: boolean; // row: an inner lane (t>0) → gets the dotted top separator
}

export interface Scene { items: Item[] }
