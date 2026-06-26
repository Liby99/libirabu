// Calendar date helpers + label arrays. Weeks are Sunday-aligned.

import { YEAR, daysInMonth } from "./mock";

export const MONTH_NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
export const MONTH_LONG = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
export const WD = ["S", "M", "T", "W", "T", "F", "S"]; // single-letter weekday
export const WD3 = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

export function firstDOW(m: number): number { return new Date(YEAR, m, 1).getDay(); } // 0=Sun

// Day-of-month of a week's Sunday; may be ≤0 or >daysInMonth when the week spills
// into the adjacent month.
export function weekStartDOM(m: number, week: number): number { return 1 - firstDOW(m) + week * 7; }

export function weeksInMonth(m: number): number { return Math.ceil((firstDOW(m) + daysInMonth(m)) / 7); }

export function weekOfDate(month: number, day: number): number { return Math.floor((firstDOW(month) + day - 1) / 7); }

// Resolve a (focus month, day-of-month-that-may-spill) into a real {month, day}.
export function resolveDate(focus: number, dom: number): { month: number; day: number } | null {
  if (dom >= 1 && dom <= daysInMonth(focus)) return { month: focus, day: dom };
  if (dom < 1) {
    const m = focus - 1;
    if (m < 0) return null;
    return { month: m, day: daysInMonth(m) + dom };
  }
  const m = focus + 1;
  if (m > 11) return null;
  return { month: m, day: dom - daysInMonth(focus) };
}
