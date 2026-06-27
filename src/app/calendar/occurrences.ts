// Expand a base date + recurrence config into the additional occurrence dates within the
// displayed year (the base itself is rendered by the event; these are the extra copies).
// Occurrence expansion across years isn't handled yet (events load per-year).

import { Repeat } from "@/lib/calendar/api";

export interface YMD { year: number; month: number; day: number }

const addDays = (d: Date, n: number) => { const x = new Date(d); x.setDate(x.getDate() + n); return x; };
const ymd = (d: Date): YMD => ({ year: d.getFullYear(), month: d.getMonth(), day: d.getDate() });
const MAX = 400; // safety cap

export function occurrenceDates(base: YMD, repeat: Repeat | undefined | null, year: number): YMD[] {
  if (!repeat || repeat.kind === "none") return [];
  const baseDate = new Date(base.year, base.month, base.day);
  const yearEnd = new Date(year, 11, 31);
  const until = repeat.until ? new Date(`${repeat.until}T00:00:00`) : yearEnd;
  const limit = until < yearEnd ? until : yearEnd;
  const ex = new Set(repeat.exdates ?? []);
  const out: YMD[] = [];
  const n = Math.max(1, repeat.n ?? 1);
  const add = (d: Date) => { const p = ymd(d); if (!ex.has(occDate(p))) out.push(p); };

  if (repeat.kind === "daily") {
    for (let d = addDays(baseDate, 1); d <= limit && out.length < MAX; d = addDays(d, 1)) add(d);
  } else if (repeat.kind === "weekly") {
    for (let d = addDays(baseDate, 7 * n); d <= limit && out.length < MAX; d = addDays(d, 7 * n)) add(d);
  } else { // weekdays: selected weekdays, every n weeks
    const days = repeat.days && repeat.days.length ? repeat.days : [baseDate.getDay()];
    const weekStart = addDays(baseDate, -baseDate.getDay()); // Sunday of the base week
    for (let ws = weekStart; ws <= limit && out.length < MAX; ws = addDays(ws, 7 * n)) {
      for (const dow of days) {
        const d = addDays(ws, dow);
        if (d <= baseDate || d > limit) continue; // base + earlier days excluded
        add(d);
      }
    }
  }
  return out;
}

export const occKey = (id: string, p: YMD) => `${id}@${p.year}-${p.month}-${p.day}`;
// "YYYY-MM-DD" — used as the element's data-occ and as the recurrence `until` value.
export const occDate = (p: YMD) => `${p.year}-${String(p.month + 1).padStart(2, "0")}-${String(p.day).padStart(2, "0")}`;
