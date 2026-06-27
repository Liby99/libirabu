// Mock data for the animated calendar prototype. Deterministic (no RNG) so SSR is stable.
// Year keyframe mirrors GridCal: 4 fixed tracks per month, events painted across days.

// The displayed year. Mutable so the calendar can switch years; importers read it
// via ES live bindings, so updating it here updates the grid's weekday alignment
// everywhere (firstDOW, today checks). daysInMonth is a fixed table (no leap-year
// handling), so only weekday alignment changes between years.
export let YEAR = 2026;
export function setCalendarYear(y: number) { YEAR = y; }

export interface Track {
  id: number;
  name: string;
  color: string;
}

// Track colors are GridCal palette keys (red/blue/yellow/green) → mapped to the
// theme's --event-* CSS variables so they follow light/dark automatically.
export const TRACKS: Track[] = [
  { id: 0, name: "Teaching", color: "red" },
  { id: 1, name: "Research", color: "blue" },
  { id: 2, name: "Service", color: "yellow" },
  { id: 3, name: "Travel", color: "green" },
];

export function daysInMonth(month: number): number {
  return [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month];
}
