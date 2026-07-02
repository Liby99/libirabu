// Apple Calendar source: invoke the native EventKit bridge (native/eventkit-bridge) and map its
// JSON into the shared RawSourceEvent shape (docs/calendar-import-design.md §5). Server-only
// (uses child_process) — import from service.ts, never from client code.

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import path from "node:path";
import type { RawSourceEvent, Attendee, AttendeeStatus } from "./types";

const execFileP = promisify(execFile);

/** Thrown when the bridge can't read calendars (permission or missing binary) — surfaced to the UI. */
export class AppleBridgeError extends Error {
  constructor(message: string, readonly code: "no-access" | "not-built" | "failed" = "failed") {
    super(message);
  }
}

// The bridge is run by a plain direct exec. Calendar access hinges on the TCC "responsible process"
// being a LaunchServices-launched app (see docs §5.2): in the packaged/dev Electron app the server
// is a child of Electron, so the bridge inherits Electron's grant. Running the Next server straight
// from a terminal makes the terminal responsible → access-denied (expected; use the Electron app).
// EVENTKIT_BRIDGE_PATH overrides the binary location (packaged app resources).
function bridgeBinary(): string {
  return process.env.EVENTKIT_BRIDGE_PATH
    || path.join(process.cwd(), "native/eventkit-bridge/EventKitBridge.app/Contents/MacOS/eventkit-bridge");
}

async function runBridge(args: string[]): Promise<unknown> {
  let raw: string;
  try {
    ({ stdout: raw } = await execFileP(bridgeBinary(), args, { maxBuffer: 64 * 1024 * 1024 }));
  } catch (e) {
    const out = (e as { stdout?: string })?.stdout; // non-zero exit still carries a JSON error
    if (out) raw = out;
    else if ((e as { code?: string })?.code === "ENOENT") throw new AppleBridgeError("EventKit bridge not built — run native/eventkit-bridge/build-app.sh", "not-built");
    else throw new AppleBridgeError((e as Error).message || "bridge failed", "failed");
  }

  let data: unknown;
  try { data = JSON.parse(raw); } catch { throw new AppleBridgeError("bridge returned no/!JSON output", "failed"); }
  if (data && typeof data === "object" && !Array.isArray(data) && "error" in data) {
    const msg = String((data as { error: unknown }).error);
    throw new AppleBridgeError(msg, /access|denied/.test(msg) ? "no-access" : "failed");
  }
  return data;
}

export interface AppleCalendar {
  id: string;
  title: string;
  source: string; // EKSource.title ("iCloud" / "Google" / account name)
  sourceType: string;
  color: string;
  allowsModify: boolean;
}

export async function listAppleCalendars(): Promise<AppleCalendar[]> {
  return (await runBridge(["list-calendars"])) as AppleCalendar[];
}

interface BridgeEvent {
  uid: string | null;
  localId: string;
  calendarId: string;
  title: string;
  start: string; // ISO instant, or "YYYY-MM-DD" when allDay
  end: string;
  allDay: boolean;
  location: string | null;
  notes: string | null;
  url: string | null;
  organizer: string;
  attendees: { name?: string; email?: string; status?: string }[];
  status: string;
  rrule: string | null;
  lastModified: string | null;
}

const STATUS: Record<string, AttendeeStatus> = {
  accepted: "accepted", declined: "declined", tentative: "tentative", "needs-action": "needs-action",
};

function mapAttendees(list: BridgeEvent["attendees"]): Attendee[] {
  return (list ?? []).map((a) => ({
    name: a.name || undefined,
    email: a.email || undefined,
    status: STATUS[a.status ?? ""] ?? "unknown",
  }));
}

export interface FetchAppleOptions {
  provenance: string; // human label ("Apple · iCloud · Work")
  connectionId: string;
  tags?: string[]; // tags stamped on every imported event ("imported", account, provider)
}

function bridgeToRaw(e: BridgeEvent, opts: FetchAppleOptions): RawSourceEvent {
  return {
    source: "apple",
    uid: e.uid ?? e.localId, // external identifier preferred; fall back to the Apple-local id
    nativeId: e.localId,
    url: e.url ?? null,
    etag: e.lastModified ?? null,
    connectionId: opts.connectionId,
    provenance: opts.provenance,
    title: e.title || "(untitled)",
    start: { value: e.start, dateOnly: e.allDay },
    end: e.end ? { value: e.end, dateOnly: e.allDay } : null,
    tags: opts.tags,
    rrule: e.rrule ?? null,
    exdates: [], // EXDATE handling lands with occurrence overrides (later); series import is faithful enough
    vendor: {
      location: e.location,
      meetingUrl: e.url,
      organizer: e.organizer || null,
      attendees: mapAttendees(e.attendees),
      description: e.notes,
      status: e.status,
    },
  };
}

// EventKit expands a recurring event into one EKEvent PER occurrence in the window (all sharing the
// iCalUID). We want the SERIES, not 50 copies: keep the earliest occurrence per uid for events that
// carry an RRULE, and let libirabu re-expand from its start. Non-recurring events pass through.
function collapseSeries(raws: RawSourceEvent[]): RawSourceEvent[] {
  const series = new Map<string, RawSourceEvent>();
  const singles: RawSourceEvent[] = [];
  for (const r of raws) {
    if (r.rrule && r.uid) {
      const prev = series.get(r.uid);
      if (!prev || new Date(r.start.value) < new Date(prev.start.value)) series.set(r.uid, r);
    } else {
      singles.push(r);
    }
  }
  return [...singles, ...series.values()];
}

/** Fetch events in [fromISO, toISO) for one calendar → RawSourceEvent[] (tagged with the connection). */
export async function fetchAppleEvents(
  calendarId: string,
  fromISO: string,
  toISO: string,
  opts: FetchAppleOptions,
): Promise<RawSourceEvent[]> {
  const evs = (await runBridge(["events", "--from", fromISO, "--to", toISO, "--calendars", calendarId])) as BridgeEvent[];
  return collapseSeries(evs.map((e) => bridgeToRaw(e, opts)));
}
