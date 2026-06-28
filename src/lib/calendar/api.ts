// Shared contract for the calendar REST API (/api/calendar). Pure + dependency-light
// (only zod) so it is safe to import from both the server routes and the client hooks.
//
// Times are a "floating" wall-clock in the user's main timezone: we build Dates with
// Date.UTC(...) and always read them back with UTC getters, so storage introduces no
// timezone/DST drift. The alt-timezone feature is a pure display concern.

import { z } from "zod";

export const EVENT_KINDS = ["timed", "band", "deadline"] as const;
export type EventKind = (typeof EVENT_KINDS)[number];

// Recurrence config (null/none = single occurrence). `n` = every N weeks (1–4);
// `days` (0=Sun..6=Sat) for "weekdays"; `until` = inclusive YYYY-MM-DD or null.
export type RepeatKind = "none" | "daily" | "weekly" | "weekdays" | "yearly";
export interface Repeat {
  kind: RepeatKind;
  n?: number;
  until?: string | null;
  days?: number[];
  exdates?: string[]; // "YYYY-MM-DD" occurrences removed individually
}
export const repeatSchema = z.object({
  kind: z.enum(["none", "daily", "weekly", "weekdays", "yearly"]),
  n: z.number().int().min(1).max(4).optional(),
  until: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).nullish(),
  days: z.array(z.number().int().min(0).max(6)).max(7).optional(),
  exdates: z.array(z.string().regex(/^\d{4}-\d{2}-\d{2}$/)).max(400).optional(),
});
export const NO_REPEAT: Repeat = { kind: "none" };

export const DEFAULT_MAIN_TZ = "America/New_York";
export const TRACK_LANES = 4;

// ── Deadline origin timezones ───────────────────────────────────────────
// Curated set conferences actually use. "AOE" (Anywhere on Earth = UTC-12) is a
// pseudo-id mapped to the fixed IANA zone Etc/GMT+12 with a custom abbreviation.
export interface TzChoice { id: string; label: string }
export const DEADLINE_TZS: TzChoice[] = [
  { id: "AOE", label: "AOE (Anywhere on Earth)" },
  { id: "UTC", label: "UTC" },
  { id: "America/New_York", label: "US Eastern" },
  { id: "America/Chicago", label: "US Central" },
  { id: "America/Denver", label: "US Mountain" },
  { id: "America/Los_Angeles", label: "US Pacific" },
  { id: "Europe/London", label: "London / UK" },
  { id: "Europe/Paris", label: "Central Europe (CET)" },
  { id: "Asia/Shanghai", label: "China (CST)" },
  { id: "Asia/Tokyo", label: "Japan (JST)" },
  { id: "Asia/Kolkata", label: "India (IST)" },
];
// Map a deadline tz id to a real IANA zone (AOE → Etc/GMT+12).
export const tzIana = (tz: string): string => (tz === "AOE" ? "Etc/GMT+12" : tz);
// Short label shown in the deadline label's "(ABBR HH:MM)" part.
export function tzShortLabel(tz: string, date: Date): string {
  if (tz === "AOE") return "AOE";
  try {
    const parts = new Intl.DateTimeFormat("en-US", { timeZone: tzIana(tz), timeZoneName: "short" }).formatToParts(date);
    return parts.find((p) => p.type === "timeZoneName")?.value ?? tz;
  } catch { return tz; }
}
// Minutes east of UTC for `tz` at `date` (DST-aware).
function tzOffsetMin(tz: string, date: Date): number {
  const z = tzIana(tz);
  const asTz = new Date(date.toLocaleString("en-US", { timeZone: z }));
  const asUtc = new Date(date.toLocaleString("en-US", { timeZone: "UTC" }));
  return Math.round((asTz.getTime() - asUtc.getTime()) / 60000);
}
// Re-express a wall-clock string from one tz to the equivalent wall-clock in another
// (same instant). Used to translate a deadline between its origin tz and the main tz.
export function convertWallClock(wall: string, tzFrom: string, tzTo: string): string {
  const base = parseWallClock(wall);                       // floating UTC-encoded
  const deltaMin = tzOffsetMin(tzTo, base) - tzOffsetMin(tzFrom, base);
  return formatWallClock(new Date(base.getTime() + deltaMin * 60000), false);
}
export const DEFAULT_TRACK_NAMES = ["", "", "", ""]; // lanes start unnamed
// 12 months × 4 lanes of editable names.
export const defaultTrackNames = (): string[][] =>
  Array.from({ length: 12 }, () => [...DEFAULT_TRACK_NAMES]);

// ── Wire shapes ────────────────────────────────────────────────────────
/**
 * A calendar event as returned by the API.
 *  - `kind:"timed"` → an hourly event on a single day; `start`/`end` are
 *    `"YYYY-MM-DDTHH:MM:SS"` wall-clock strings on the same day, `track` is null.
 *  - `kind:"band"`  → an all-day event spanning a day range on one lane of a single
 *    month; `start`/`end` are `"YYYY-MM-DD"` (inclusive), `track` is the lane 0–3.
 *  - `kind:"deadline"` → a single moment; `start`==`end` are `"YYYY-MM-DDTHH:MM:SS"` in
 *    the MAIN tz; `originTz` (or null) is the tz it was originally specified in. The
 *    origin-tz time is `convertWallClock(start, mainTz, originTz)`.
 */
export interface ApiEvent {
  id: string;
  kind: EventKind;
  title: string;
  color: string;
  notes: string | null;
  allDay: boolean; // false for timed/deadline, true for band
  start: string;
  end: string;
  track: number | null;
  originTz: string | null; // deadline only
  tags: string[];
  repeat: Repeat; // {kind:"none"} when not recurring
  createdAt: string; // ISO-8601 UTC
  updatedAt: string;
}

export interface ApiSettings {
  mainTz: string;
  altTz: string | null;
  // Track-lane names are PER-YEAR: a map from 4-digit year → [12][4] grid. Years absent
  // from the map have no custom names (lanes render blank). mainTz/altTz stay global.
  trackNames: Record<string, string[][]>;
}

// ── Validation (shape) ─────────────────────────────────────────────────
const DATE_ONLY = /^\d{4}-\d{2}-\d{2}$/;
const DATE_TIME = /^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2})?$/;

export const eventCreateSchema = z.object({
  id: z.string().min(1).max(64).optional(), // client-supplied id allowed (else server cuid)
  kind: z.enum(EVENT_KINDS),
  title: z.string().min(1).max(200),
  notes: z.string().max(4000).nullish(),
  color: z.string().min(1).max(40).optional(),
  start: z.string().min(1).optional(),       // main-tz wall-clock; for deadlines may be derived from origin
  end: z.string().min(1).optional(),         // timed/band only
  track: z.number().int().min(0).max(TRACK_LANES - 1).nullish(),
  originTz: z.string().min(1).max(64).nullish(),  // deadline only
  originAt: z.string().min(1).nullish(),          // deadline only: wall-clock in originTz (server → main)
  tags: z.array(z.string().min(1).max(40)).max(50).optional(),
  repeat: repeatSchema.optional(),
});
export type EventCreate = z.infer<typeof eventCreateSchema>;

// Patch: any subset of mutable fields. `kind` is immutable (re-create to change it).
export const eventUpdateSchema = z.object({
  title: z.string().min(1).max(200).optional(),
  notes: z.string().max(4000).nullish(),
  color: z.string().min(1).max(40).optional(),
  start: z.string().min(1).optional(),
  end: z.string().min(1).optional(),
  track: z.number().int().min(0).max(TRACK_LANES - 1).nullish(),
  originTz: z.string().min(1).max(64).nullish(),
  originAt: z.string().min(1).nullish(),
  tags: z.array(z.string().min(1).max(40)).max(50).optional(),
  repeat: repeatSchema.optional(),
});
export type EventUpdate = z.infer<typeof eventUpdateSchema>;

export const settingsUpdateSchema = z.object({
  mainTz: z.string().min(1).max(64).optional(),
  altTz: z.string().min(1).max(64).nullable().optional(),
  // per-year map: { "2026": [12][4], … }; keys are 4-digit years
  trackNames: z.record(z.string().regex(/^\d{4}$/), z.array(z.array(z.string().max(80)).length(TRACK_LANES)).length(12)).optional(),
});
export type SettingsUpdate = z.infer<typeof settingsUpdateSchema>;

// ── Cross-field semantics (shared by create + patch) ───────────────────
/** Returns a list of human-readable problems with a fully-resolved event, or [] if valid. */
export function eventSemanticIssues(kind: EventKind, start: string | undefined, end: string | undefined, track: number | null | undefined): string[] {
  const out: string[] = [];
  if (kind === "deadline") {
    if (!start || !DATE_TIME.test(start)) out.push("deadline start must be 'YYYY-MM-DDTHH:MM' (resolved from origin if given)");
    if (track != null) out.push("deadlines must not have a track");
    return out;
  }
  if (kind === "timed") {
    if (!start || !end || !DATE_TIME.test(start) || !DATE_TIME.test(end)) {
      out.push("timed start/end must be 'YYYY-MM-DDTHH:MM' wall-clock strings");
    } else {
      const s = parseWallClock(start), e = parseWallClock(end);
      const startMidnight = Date.UTC(s.getUTCFullYear(), s.getUTCMonth(), s.getUTCDate());
      if (e.getTime() <= s.getTime()) out.push("timed end must be after start");
      // single-day event: end may run up to (but not past) midnight of the start day
      if (e.getTime() > startMidnight + 24 * 3600_000) out.push("a timed event must end by midnight of its start day");
    }
    if (track != null) out.push("timed events must not have a track");
  } else {
    if (!start || !end || !DATE_ONLY.test(start) || !DATE_ONLY.test(end)) {
      out.push("band start/end must be 'YYYY-MM-DD' dates");
    } else {
      const s = parseWallClock(start), e = parseWallClock(end);
      if (s.getUTCFullYear() !== e.getUTCFullYear() || s.getUTCMonth() !== e.getUTCMonth()) {
        out.push("a band event must stay within a single month");
      }
      if (e.getTime() < s.getTime()) out.push("band end day must be on or after start day");
    }
    if (track == null) out.push("band events require a track lane (0–3)");
  }
  return out;
}

// ── Wall-clock helpers ─────────────────────────────────────────────────
const pad = (n: number) => String(n).padStart(2, "0");

/** Build a UTC-encoded Date from local wall-clock components (month is 0-based). */
export function wallClock(year: number, month0: number, day: number, hour = 0, min = 0): Date {
  return new Date(Date.UTC(year, month0, day, hour, min, 0, 0));
}

/** Parse `"YYYY-MM-DD"` or `"YYYY-MM-DDTHH:MM[:SS]"` into a UTC-encoded Date. */
export function parseWallClock(s: string): Date {
  const m = s.match(/^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}))?)?$/);
  if (!m) throw new Error(`invalid wall-clock string: ${s}`);
  return new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +(m[4] ?? 0), +(m[5] ?? 0), +(m[6] ?? 0)));
}

/** Format a UTC-encoded Date back to a wall-clock string (date-only when allDay). */
export function formatWallClock(d: Date, allDay: boolean): string {
  const date = `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}`;
  return allDay ? date : `${date}T${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}:${pad(d.getUTCSeconds())}`;
}

// ── Row ↔ API converters (pure; structurally typed so no Prisma import) ─
export interface EventRow {
  id: string;
  kind: string;
  title: string;
  notes: string | null;
  color: string;
  start: Date;
  end: Date;
  track: number | null;
  originTz: string | null;
  tags: string[];
  repeat: unknown; // Prisma Json
  createdAt: Date;
  updatedAt: Date;
}

export function toApiEvent(row: EventRow): ApiEvent {
  const allDay = row.kind === "band";
  return {
    id: row.id,
    kind: row.kind as EventKind,
    title: row.title,
    color: row.color,
    notes: row.notes ?? null,
    allDay,
    start: formatWallClock(row.start, allDay),
    end: formatWallClock(row.end, allDay),
    track: row.track ?? null,
    originTz: row.originTz ?? null,
    tags: row.tags ?? [],
    repeat: (row.repeat as Repeat | null) ?? NO_REPEAT,
    createdAt: row.createdAt.toISOString(),
    updatedAt: row.updatedAt.toISOString(),
  };
}

/**
 * Resolve a deadline's main-tz wall-clock from the create/patch input: prefer an explicit
 * main-tz `start`; otherwise convert `originAt` (in `originTz`) to the main tz. Returns
 * undefined if neither is available. For timed/band, just returns `start`.
 */
export function resolveStartWall(
  input: { kind?: EventKind; start?: string | null; originAt?: string | null; originTz?: string | null },
  mainTz: string,
): string | undefined {
  if (input.start) return input.start;
  if (input.originAt && input.originTz) return convertWallClock(input.originAt, input.originTz, mainTz);
  return undefined;
}

/** Build the Prisma create payload from a validated input + resolved main-tz wall-clocks. */
export function eventCreateData(input: EventCreate, startWall: string, endWall: string) {
  return {
    kind: input.kind,
    title: input.title,
    notes: input.notes ?? null,
    color: input.color ?? "default",
    start: parseWallClock(startWall),
    end: parseWallClock(endWall),
    track: input.kind === "band" ? input.track ?? null : null,
    originTz: input.kind === "deadline" ? input.originTz ?? null : null,
    tags: input.tags ?? [],
    repeat: input.repeat ?? NO_REPEAT, // stored as a JSON object (never DB-null)
  };
}

/**
 * Build the Prisma update payload from a validated patch. `startWall` (if provided) is the
 * resolved new main-tz wall-clock; for deadlines `end` tracks `start`.
 */
export function eventUpdateData(patch: EventUpdate, kind: EventKind, startWall: string | undefined): Record<string, unknown> {
  const data: Record<string, unknown> = {};
  if (patch.title !== undefined) data.title = patch.title;
  if (patch.notes !== undefined) data.notes = patch.notes ?? null;
  if (patch.color !== undefined) data.color = patch.color;
  if (startWall !== undefined) {
    data.start = parseWallClock(startWall);
    if (kind === "deadline") data.end = parseWallClock(startWall);
  }
  if (patch.end !== undefined && kind !== "deadline") data.end = parseWallClock(patch.end);
  if (patch.track !== undefined) data.track = patch.track ?? null;
  if (patch.originTz !== undefined) data.originTz = patch.originTz ?? null;
  if (patch.tags !== undefined) data.tags = patch.tags ?? [];
  if (patch.repeat !== undefined) data.repeat = patch.repeat ?? NO_REPEAT;
  return data;
}
