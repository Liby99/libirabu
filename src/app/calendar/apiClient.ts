// Client-side bridge between the calendar UI's value types (TimedEvent / BandEvent /
// settings) and the /api/calendar REST endpoints. Conversions live here so the hooks stay
// small. See src/app/api/calendar/README.md for the wire contract.

import { ApiEvent, ApiSettings, EventKind } from "@/lib/calendar/api";
import { TimedEvent } from "./eventTypes";
import { BandEvent } from "./bandEventTypes";
import { Deadline } from "./deadlineTypes";

const pad = (n: number) => String(n).padStart(2, "0");
const HOUR_MS = 3600_000;

// ── Wall-clock parsing (mirrors the server; all arithmetic in UTC) ──────
function msOf(s: string): number {
  const [datePart, timePart] = s.split("T");
  const [y, mo, d] = datePart.split("-").map(Number);
  let h = 0, mi = 0;
  if (timePart) { const p = timePart.split(":").map(Number); h = p[0]; mi = p[1] || 0; }
  return Date.UTC(y, mo - 1, d, h, mi);
}
const fmtDateTime = (ms: number): string => {
  const d = new Date(ms);
  return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}T${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}:00`;
};

// ── TimedEvent ↔ API ────────────────────────────────────────────────────
export function apiToTimed(e: ApiEvent): TimedEvent {
  const [dp] = e.start.split("T");
  const [y, mo, d] = dp.split("-").map(Number);
  const startMid = Date.UTC(y, mo - 1, d);
  return {
    id: e.id, year: y, month: mo - 1, day: d,
    startHour: (msOf(e.start) - startMid) / HOUR_MS,
    endHour: (msOf(e.end) - startMid) / HOUR_MS, // 24 → next-day midnight
    title: e.title, color: e.color, notes: e.notes ?? undefined, tags: e.tags ?? [], repeat: e.repeat,
  };
}
function timedBody(ev: TimedEvent) {
  const startMid = Date.UTC(ev.year, ev.month, ev.day);
  return {
    id: ev.id, kind: "timed" as EventKind, title: ev.title, color: ev.color, notes: ev.notes ?? null, tags: ev.tags ?? [], repeat: ev.repeat,
    start: fmtDateTime(startMid + ev.startHour * HOUR_MS),
    end: fmtDateTime(startMid + ev.endHour * HOUR_MS),
  };
}

// ── BandEvent ↔ API ─────────────────────────────────────────────────────
export function apiToBand(e: ApiEvent): BandEvent {
  const [sy, smo, sd] = e.start.split("-").map(Number);
  const [, , ed] = e.end.split("-").map(Number);
  return {
    id: e.id, year: sy, month: smo - 1, track: e.track ?? 0, startDay: sd, endDay: ed,
    title: e.title, color: e.color, notes: e.notes ?? undefined, tags: e.tags ?? [], repeat: e.repeat,
  };
}
function bandBody(ev: BandEvent) {
  const date = (day: number) => `${ev.year}-${pad(ev.month + 1)}-${pad(day)}`;
  return {
    id: ev.id, kind: "band" as EventKind, title: ev.title, color: ev.color, notes: ev.notes ?? null, tags: ev.tags ?? [], repeat: ev.repeat,
    track: ev.track, start: date(ev.startDay), end: date(ev.endDay),
  };
}

// ── Deadline ↔ API ──────────────────────────────────────────────────────
export function apiToDeadline(e: ApiEvent): Deadline {
  const [dp] = e.start.split("T");
  const [y, mo, d] = dp.split("-").map(Number);
  const startMid = Date.UTC(y, mo - 1, d);
  return {
    id: e.id, year: y, month: mo - 1, day: d,
    hour: (msOf(e.start) - startMid) / HOUR_MS,
    title: e.title, color: e.color, notes: e.notes ?? undefined, tags: e.tags ?? [], repeat: e.repeat, originTz: e.originTz ?? null,
  };
}
function deadlineBody(d: Deadline) {
  const mid = Date.UTC(d.year, d.month, d.day);
  return {
    id: d.id, kind: "deadline" as EventKind, title: d.title, color: d.color, notes: d.notes ?? null, tags: d.tags ?? [], repeat: d.repeat,
    start: fmtDateTime(mid + d.hour * HOUR_MS), // always main-tz wall-clock
    originTz: d.originTz ?? null,
  };
}

// ── HTTP ────────────────────────────────────────────────────────────────
async function send(method: string, url: string, body?: unknown): Promise<Response> {
  const res = await fetch(url, {
    method,
    headers: body !== undefined ? { "content-type": "application/json" } : undefined,
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  if (!res.ok && res.status !== 204) {
    const detail = await res.text().catch(() => "");
    throw new Error(`${method} ${url} → ${res.status} ${detail}`);
  }
  return res;
}

export async function fetchEvents(year: number, kind: EventKind): Promise<ApiEvent[]> {
  const res = await send("GET", `/api/calendar/events?year=${year}&kind=${kind}`);
  return (await res.json()).events as ApiEvent[];
}
export const createTimed = (ev: TimedEvent) => send("POST", "/api/calendar/events", timedBody(ev));
export const createBand = (ev: BandEvent) => send("POST", "/api/calendar/events", bandBody(ev));
export const patchTimed = (ev: TimedEvent) => send("PATCH", `/api/calendar/events/${ev.id}`, timedBody(ev));
export const patchBand = (ev: BandEvent) => send("PATCH", `/api/calendar/events/${ev.id}`, bandBody(ev));
export const createDeadline = (d: Deadline) => send("POST", "/api/calendar/events", deadlineBody(d));
export const patchDeadline = (d: Deadline) => send("PATCH", `/api/calendar/events/${d.id}`, deadlineBody(d));
export const deleteEvent = (id: string) => send("DELETE", `/api/calendar/events/${id}`);

export async function fetchSettings(): Promise<ApiSettings> {
  const res = await send("GET", "/api/calendar/settings");
  return (await res.json()) as ApiSettings;
}
export async function putSettings(patch: Partial<ApiSettings>): Promise<ApiSettings> {
  const res = await send("PUT", "/api/calendar/settings", patch);
  return (await res.json()) as ApiSettings;
}
