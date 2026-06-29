// Expand a base date + recurrence config into the occurrence dates that fall within the
// displayed year (the base itself, when it's in that year, is rendered by the event; these
// are the extra copies). The window is the displayed year, so a base from ANOTHER year still
// yields its in-year occurrences — this is what makes recurrence cross years (the server
// loads cross-year recurring bases regardless of the year being viewed).

import { Repeat } from "@/lib/calendar/api";

export interface YMD { year: number; month: number; day: number }

const DAY = 86400000;
const addDays = (d: Date, n: number) => { const x = new Date(d); x.setDate(x.getDate() + n); return x; };
const ymd = (d: Date): YMD => ({ year: d.getFullYear(), month: d.getMonth(), day: d.getDate() });
const MAX = 400; // safety cap (per displayed year)

// First occurrence base + k·stepDays (k ≥ 1) that is ≥ winStart — jumps over whole years
// instead of stepping day-by-day from a far-back base.
function firstStepIn(base: Date, stepDays: number, winStart: Date): Date {
  const gap = winStart.getTime() - base.getTime();
  const k = gap > stepDays * DAY ? Math.floor(gap / (stepDays * DAY)) : 1;
  let d = addDays(base, stepDays * k);
  while (d < winStart) d = addDays(d, stepDays);
  return d;
}
// Largest in-phase week-start baseWeek + k·stepDays (k ≥ 0) that is ≤ winStart (so the days
// of the boundary week that land in-window aren't skipped); the base week if it's later.
function firstWeekIn(baseWeek: Date, stepDays: number, winStart: Date): Date {
  if (baseWeek >= winStart) return baseWeek;
  const k = Math.floor((winStart.getTime() - baseWeek.getTime()) / (stepDays * DAY));
  return addDays(baseWeek, stepDays * k);
}

// Memoized public entry. Expansion is a pure function of (base, repeat, year), and edits
// always REPLACE the repeat object (immutable state updates — e.g. deleteOccurrence builds
// a fresh {...repeat, exdates}), so a WeakMap keyed on the repeat object stays correct and
// self-invalidates: a changed repeat is a new object (cache miss), and a deleted/edited
// event drops its old repeat (entry GC'd). This matters because the render layers re-expand
// recurrences every animation frame; without this a handful of daily-repeat events cost
// several ms/frame (measured) re-deriving identical date lists. Callers never mutate the
// returned array, so sharing the cached instance across frames is safe.
const occCache = new WeakMap<Repeat, Map<string, YMD[]>>();

export function occurrenceDates(base: YMD, repeat: Repeat | undefined | null, year: number): YMD[] {
  if (!repeat || repeat.kind === "none") return [];
  let byKey = occCache.get(repeat);
  if (!byKey) { byKey = new Map(); occCache.set(repeat, byKey); }
  const key = `${base.year}-${base.month}-${base.day}-${year}`;
  let res = byKey.get(key);
  if (!res) { res = computeOccurrences(base, repeat, year); byKey.set(key, res); }
  return res;
}

function computeOccurrences(base: YMD, repeat: Repeat, year: number): YMD[] {
  const baseDate = new Date(base.year, base.month, base.day);
  const winStart = new Date(year, 0, 1);
  const yearEnd = new Date(year, 11, 31);
  const until = repeat.until ? new Date(`${repeat.until}T00:00:00`) : null;
  const winEnd = until && until < yearEnd ? until : yearEnd;
  if (winEnd < winStart) return []; // the series ended before the displayed year
  const ex = new Set(repeat.exdates ?? []);
  const out: YMD[] = [];
  const n = Math.max(1, repeat.n ?? 1);
  // Keep d only if it's a genuine occurrence: after the base, inside the window, not excluded.
  const add = (d: Date) => {
    if (d <= baseDate || d < winStart || d > winEnd) return;
    const p = ymd(d);
    if (!ex.has(occDate(p))) out.push(p);
  };

  if (repeat.kind === "daily") {
    let d = baseDate >= winStart ? addDays(baseDate, 1) : new Date(winStart);
    for (; d <= winEnd && out.length < MAX; d = addDays(d, 1)) add(d);
  } else if (repeat.kind === "weekly") {
    const step = 7 * n;
    for (let d = firstStepIn(baseDate, step, winStart); d <= winEnd && out.length < MAX; d = addDays(d, step)) add(d);
  } else if (repeat.kind === "yearly") { // same month/day every n years — at most one per window
    if (year > base.year && (year - base.year) % n === 0) add(new Date(year, base.month, base.day));
  } else { // weekdays: selected weekdays, every n weeks (phase anchored to the base week)
    const days = repeat.days && repeat.days.length ? repeat.days : [baseDate.getDay()];
    const baseWeek = addDays(baseDate, -baseDate.getDay()); // Sunday of the base week
    const step = 7 * n;
    for (let ws = firstWeekIn(baseWeek, step, winStart); ws <= winEnd && out.length < MAX; ws = addDays(ws, step)) {
      for (const dow of days) add(addDays(ws, dow));
    }
  }
  return out;
}

export const occKey = (id: string, p: YMD) => `${id}@${p.year}-${p.month}-${p.day}`;
// "YYYY-MM-DD" — used as the element's data-occ and as the recurrence `until` value.
export const occDate = (p: YMD) => `${p.year}-${String(p.month + 1).padStart(2, "0")}-${String(p.day).padStart(2, "0")}`;

// The base occurrence renders directly (not via occurrenceDates), so it must independently honor
// the same exclusions: its own date being an exdate ("delete just this") or past `until` ("delete
// this & all following" from the base). Lets per-occurrence deletes work on the first instance too.
export function baseHidden(dateStr: string, repeat: Repeat | null | undefined): boolean {
  if (!repeat || repeat.kind === "none") return false;
  if ((repeat.exdates ?? []).includes(dateStr)) return true;
  if (repeat.until && dateStr > repeat.until) return true; // YYYY-MM-DD compares chronologically
  return false;
}
