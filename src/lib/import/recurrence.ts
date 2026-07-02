// RFC 5545 RRULE → libirabu's small Repeat shape (docs/calendar-import-design.md §8).
//
// One mapper for every source: the .ics parser passes node-ical's `rrule.toString()` body, and the
// Apple bridge (P2) re-serializes EKRecurrenceRule to the same RRULE syntax. libirabu's Repeat only
// models none|daily|weekly|weekdays|yearly with an interval n∈1..4, so anything richer (MONTHLY,
// BYSETPOS, COUNT, interval>4, …) is reported as "simplified" — the caller flags it in the preview
// and falls back to a best-effort (or single occurrence) rather than importing something wrong.

import type { Repeat } from "@/lib/calendar/api";

export interface MappedRepeat {
  repeat: Repeat;
  /** true when the source RRULE couldn't be represented faithfully (→ preview "recurrence simplified"). */
  simplified: boolean;
}

const NONE: MappedRepeat = { repeat: { kind: "none" }, simplified: false };

// RRULE BYDAY tokens → JS weekday index (0=Sun..6=Sat), matching Repeat.days.
const DAY_INDEX: Record<string, number> = { SU: 0, MO: 1, TU: 2, WE: 3, TH: 4, FR: 5, SA: 6 };
const WEEKDAYS = [1, 2, 3, 4, 5]; // Mon–Fri

/** Parse an RRULE body ("FREQ=WEEKLY;BYDAY=MO,WE;INTERVAL=2") into a key→value map (keys upper-cased). */
function parseRule(body: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const part of body.replace(/^RRULE:/i, "").split(";")) {
    const [k, v] = part.split("=");
    if (k && v != null) out[k.trim().toUpperCase()] = v.trim();
  }
  return out;
}

/** UNTIL ("20261231T235959Z" or "20261231") → "YYYY-MM-DD". */
function untilToDate(until: string): string | null {
  const m = until.match(/^(\d{4})(\d{2})(\d{2})/);
  return m ? `${m[1]}-${m[2]}-${m[3]}` : null;
}

/** BYDAY ("MO,WE,FR") → sorted unique weekday indices; null if any token is unrecognized/positional. */
function parseByDay(byday: string): number[] | null {
  const days: number[] = [];
  for (const tok of byday.split(",")) {
    const t = tok.trim().toUpperCase();
    if (!(t in DAY_INDEX)) return null; // positional like "2MO" → not representable
    days.push(DAY_INDEX[t]);
  }
  return Array.from(new Set(days)).sort((a, b) => a - b);
}

const sameSet = (a: number[], b: number[]) => a.length === b.length && a.every((x, i) => x === b[i]);

/**
 * Map an RRULE body to a Repeat. `exdates` (YYYY-MM-DD[]) are attached when the kind recurs.
 * Returns {kind:"none"} for an empty/absent rule.
 */
export function rruleToRepeat(rruleBody: string | null | undefined, exdates: string[] = []): MappedRepeat {
  if (!rruleBody || !rruleBody.trim()) return NONE;
  const r = parseRule(rruleBody);
  const freq = r.FREQ?.toUpperCase();
  if (!freq) return NONE;

  const interval = r.INTERVAL ? parseInt(r.INTERVAL, 10) : 1;
  const until = r.UNTIL ? untilToDate(r.UNTIL) : null;
  const hasCount = r.COUNT != null; // libirabu has no occurrence-count → can't represent faithfully
  const ex = exdates.length ? { exdates: Array.from(new Set(exdates)).sort() } : {};

  // interval out of representable range, or a COUNT limit → simplify.
  let simplified = hasCount || interval < 1 || interval > 4;
  const n = Math.min(4, Math.max(1, interval));

  const withFlag = (repeat: Repeat): MappedRepeat => ({ repeat, simplified });

  switch (freq) {
    case "DAILY":
      return withFlag({ kind: "daily", n, until, ...ex });

    case "WEEKLY": {
      if (r.BYDAY) {
        const days = parseByDay(r.BYDAY);
        if (!days) { simplified = true; return withFlag({ kind: "weekly", n, until, ...ex }); }
        if (sameSet(days, WEEKDAYS) && n === 1) return withFlag({ kind: "weekdays", until, ...ex });
        return withFlag({ kind: "weekly", n, days, until, ...ex });
      }
      return withFlag({ kind: "weekly", n, until, ...ex }); // weekly on the start's own weekday
    }

    case "YEARLY":
      if (interval !== 1) simplified = true; // yearly has no interval in Repeat
      return withFlag({ kind: "yearly", until, ...ex });

    // MONTHLY and anything else aren't representable → single occurrence, flagged.
    default:
      return { repeat: { kind: "none" }, simplified: true };
  }
}
