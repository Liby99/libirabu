// RawSourceEvent → NormalizedEvent (docs/calendar-import-design.md §8). Source-agnostic: once a
// fetch produces RawSourceEvent[], everything downstream (diff/preview/commit) is identical for
// .ics and the Apple bridge. Times become the app's floating main-tz wall-clock (same convention as
// ApiEvent); the managed note itself is rendered later, at commit, from the carried vendor details.

import type { EventKind } from "@/lib/calendar/api";
import type { NormalizedEvent, RawSourceEvent } from "./types";
import { rruleToRepeat } from "./recurrence";

// Imported all-day events become bands, which need a lane 0–3. Default to lane 0 (a per-connection
// default lane is a possible later refinement — see §11).
const DEFAULT_BAND_TRACK = 0;

/** Format an absolute instant in `mainTz` as a "YYYY-MM-DDTHH:MM:SS" floating wall-clock.
 *  Defensive: an invalid tz (Intl throws) falls back to UTC rather than dropping the event —
 *  callers should pass a resolved zone (see getMainTz), but a bad value must never lose data. */
export function instantToMainWall(iso: string, mainTz: string): string {
  const d = new Date(iso);
  const opts: Intl.DateTimeFormatOptions = {
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false,
  };
  let parts: Intl.DateTimeFormatPart[];
  try {
    parts = new Intl.DateTimeFormat("en-CA", { timeZone: mainTz, ...opts }).formatToParts(d);
  } catch {
    parts = new Intl.DateTimeFormat("en-CA", { timeZone: "UTC", ...opts }).formatToParts(d);
  }
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "00";
  const hour = get("hour") === "24" ? "00" : get("hour"); // some engines emit "24" for midnight
  return `${get("year")}-${get("month")}-${get("day")}T${hour}:${get("minute")}:${get("second")}`;
}

/** Add `delta` days to a "YYYY-MM-DD" string (UTC math; no tz drift). */
function addDays(dateStr: string, delta: number): string {
  const [y, m, d] = dateStr.split("-").map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d));
  dt.setUTCDate(dt.getUTCDate() + delta);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${dt.getUTCFullYear()}-${p(dt.getUTCMonth() + 1)}-${p(dt.getUTCDate())}`;
}

const dayOf = (wall: string) => wall.slice(0, 10);

/**
 * Normalize one source event. Mapping rules (§8):
 *  - all-day → `band` (RFC exclusive end → inclusive last day); needs a lane → DEFAULT_BAND_TRACK.
 *  - timed single-day → `timed`.
 *  - timed multi-day (libirabu `timed` is single-day) → promoted to a `band` over the day span.
 * Imports never produce `deadline` (that's an assistant/CFP concern, not calendar import).
 */
export function normalizeEvent(raw: RawSourceEvent, mainTz: string): NormalizedEvent {
  const { repeat, simplified } = rruleToRepeat(raw.rrule, raw.exdates);

  let kind: EventKind;
  let start: string;
  let end: string;
  let allDay: boolean;
  let track: number | null;

  if (raw.start.dateOnly) {
    kind = "band";
    allDay = true;
    track = DEFAULT_BAND_TRACK;
    start = raw.start.value;
    const exclusiveEnd = raw.end?.value ?? null;
    end = exclusiveEnd ? addDays(exclusiveEnd, -1) : start; // RFC end is exclusive → inclusive
    if (end < start) end = start;
  } else {
    const sWall = instantToMainWall(raw.start.value, mainTz);
    const eWall = raw.end ? instantToMainWall(raw.end.value, mainTz) : sWall;
    if (dayOf(sWall) === dayOf(eWall)) {
      kind = "timed";
      allDay = false;
      track = null;
      start = sWall;
      end = eWall;
    } else {
      // multi-day timed → promote to an all-day band over the span
      kind = "band";
      allDay = true;
      track = DEFAULT_BAND_TRACK;
      start = dayOf(sWall);
      end = dayOf(eWall);
    }
  }

  return {
    source: raw.source,
    externalUid: raw.uid,
    externalId: raw.nativeId,
    externalEtag: raw.etag,
    externalUrl: raw.url,
    connectionId: raw.connectionId,
    provenance: raw.provenance,
    kind,
    title: raw.title,
    start,
    end,
    allDay,
    track,
    color: raw.color ?? null,
    tags: raw.tags ?? [],
    repeat,
    repeatSimplified: simplified || undefined,
    vendor: raw.vendor,
  };
}

export interface NormalizeResult {
  /** Timed events (and promoted multi-day spans) — the ones imported by default. */
  events: NormalizedEvent[];
  /** Source all-day events, partitioned out. The user rarely wants these (birthdays/holidays), so
   *  by default the caller IGNORES them; surfacing them as an "inbox" later is just reading this. */
  allDay: NormalizedEvent[];
}

/**
 * Normalize a batch. Source all-day events (raw.start.dateOnly — birthdays, holidays, …) are split
 * into `allDay` so the import policy can drop them; timed events go to `events`. Anything that throws
 * is skipped (one bad event can't sink an import).
 */
export function normalizeEvents(raws: RawSourceEvent[], mainTz: string): NormalizeResult {
  const events: NormalizedEvent[] = [];
  const allDay: NormalizedEvent[] = [];
  for (const raw of raws) {
    try {
      const ev = normalizeEvent(raw, mainTz);
      (raw.start.dateOnly ? allDay : events).push(ev);
    } catch {
      // skip malformed source event
    }
  }
  return { events, allDay };
}
