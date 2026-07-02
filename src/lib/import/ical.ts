// Parse an .ics file (emailed invite / exported calendar) into RawSourceEvent[] via node-ical
// (docs/calendar-import-design.md §8). This is the .ics "fetch" step; normalize.ts takes it from
// here. Grounded in node-ical's observed runtime shapes (see import/ical.test.ts).

import * as ical from "node-ical";
import type { RawInstant, RawSourceEvent, Attendee, AttendeeStatus } from "./types";

// node-ical typing is loose (ParameterValue can be a string or {val, params}); narrow at runtime.
type ParamObj = { val?: unknown; params?: Record<string, unknown> };
const isParamObj = (v: unknown): v is ParamObj => typeof v === "object" && v !== null && "val" in v;

/** A node-ical string-ish property → plain string (handles bare strings and {val,params}). */
function asText(v: unknown): string | null {
  if (v == null) return null;
  if (typeof v === "string") return v;
  if (isParamObj(v)) return typeof v.val === "string" ? v.val : null;
  return null;
}

/** A node-ical Date (Date & {tz?, dateOnly?}) → RawInstant. Date-only uses LOCAL getters because
 *  node-ical builds VALUE=DATE as local-midnight; timed uses the absolute ISO instant. */
function toRawInstant(d: Date & { dateOnly?: boolean }): RawInstant {
  if (d.dateOnly) {
    const p = (n: number) => String(n).padStart(2, "0");
    return { value: `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`, dateOnly: true };
  }
  return { value: d.toISOString(), dateOnly: false };
}

/** node-ical's rrule.toString() returns DTSTART + RRULE lines; pull the RRULE body (sans prefix). */
function extractRruleBody(rruleStringified: string): string | null {
  for (const line of rruleStringified.split(/\r?\n/)) {
    const m = line.match(/^RRULE:(.+)$/i);
    if (m) return m[1].trim();
  }
  return null;
}

const PARTSTAT: Record<string, AttendeeStatus> = {
  ACCEPTED: "accepted",
  DECLINED: "declined",
  TENTATIVE: "tentative",
  "NEEDS-ACTION": "needs-action",
  DELEGATED: "tentative",
};

const stripMailto = (s: string | null): string | undefined => s?.replace(/^mailto:/i, "").trim() || undefined;

function mapAttendees(att: unknown): Attendee[] {
  const list = Array.isArray(att) ? att : att ? [att] : [];
  const out: Attendee[] = [];
  for (const a of list) {
    if (!isParamObj(a)) {
      const email = stripMailto(asText(a));
      if (email) out.push({ email, status: "unknown" });
      continue;
    }
    const params = (a.params ?? {}) as Record<string, unknown>;
    const cn = typeof params.CN === "string" ? params.CN : undefined;
    const ps = typeof params.PARTSTAT === "string" ? params.PARTSTAT.toUpperCase() : "";
    out.push({ name: cn, email: stripMailto(typeof a.val === "string" ? a.val : null), status: PARTSTAT[ps] ?? "unknown" });
  }
  return out;
}

/** Map EXDATE record → sorted unique "YYYY-MM-DD". */
function mapExdates(exdate: unknown): string[] {
  if (!exdate || typeof exdate !== "object") return [];
  const dates = new Set<string>();
  for (const v of Object.values(exdate as Record<string, Date>)) {
    if (v instanceof Date) dates.add(toRawInstant(v as Date & { dateOnly?: boolean }).value.slice(0, 10));
  }
  return Array.from(dates).sort();
}

export interface ParseIcsOptions {
  /** Human provenance label for these events (e.g. the filename). */
  provenance?: string;
}

/** Parse .ics text → RawSourceEvent[]. Non-VEVENT components and untitled/timeless rows are skipped. */
export function parseIcs(icsText: string, opts: ParseIcsOptions = {}): RawSourceEvent[] {
  const provenance = opts.provenance?.trim() || "Imported .ics file";
  const data = ical.parseICS(icsText);
  const out: RawSourceEvent[] = [];

  for (const comp of Object.values(data)) {
    if (!comp || (comp as { type?: string }).type !== "VEVENT") continue;
    const e = comp as ical.VEvent & { exdate?: unknown; url?: unknown; organizer?: unknown; attendee?: unknown; lastmodified?: Date };
    if (!e.start) continue;

    const title = asText(e.summary)?.trim() || "(untitled)";
    const rrule = e.rrule ? extractRruleBody(e.rrule.toString()) : null;

    out.push({
      source: "ical",
      uid: typeof e.uid === "string" ? e.uid : null,
      nativeId: typeof e.uid === "string" ? e.uid : null,
      url: asText(e.url),
      etag: e.lastmodified instanceof Date ? e.lastmodified.toISOString() : null,
      connectionId: null,
      provenance,
      title,
      start: toRawInstant(e.start as Date & { dateOnly?: boolean }),
      end: e.end ? toRawInstant(e.end as Date & { dateOnly?: boolean }) : null,
      tags: ["imported"],
      rrule,
      exdates: mapExdates(e.exdate),
      vendor: {
        location: asText(e.location),
        meetingUrl: asText(e.url),
        organizer: stripMailto(asText(e.organizer)) ?? null,
        attendees: mapAttendees(e.attendee),
        description: asText((e as { description?: unknown }).description),
        status: typeof e.status === "string" ? e.status : null,
      },
    });
  }
  return out;
}
