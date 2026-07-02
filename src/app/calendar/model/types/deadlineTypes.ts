// A deadline: a single moment shown as a line (with end circles) on the weekly/monthly
// timeline. Stored in the MAIN timezone (year/month/day/hour); `originTz` (if set) is the
// timezone it was originally specified in — the canonical side whose time the label also
// shows, e.g. "18:59 (AOE 11:59)". null/undefined → main tz is canonical.

export interface Deadline {
  id: string;
  year: number;
  month: number; // 0–11 (main tz)
  day: number;   // 1..31
  hour: number;  // 0–24 fractional (main tz)
  title: string;
  color: string;
  notes?: string;
  originTz?: string | null;
  tags?: string[];
  repeat?: import("@/lib/calendar/api").Repeat;
  createdByAI?: boolean; // provenance: created/edited by the AI assistant
  imported?: boolean; // provenance: pulled from an external calendar (Apple/.ics)
  hidden?: boolean; // soft-deleted (imported events) — hidden from the calendar unless "Show hidden" is on
  externalUrl?: string | null; // "open at source" deep link, when imported
  promoteTrack?: number | null; // promoted to a ghost band on this lane 0–3; null = not promoted
  occurrenceNotes?: Record<string, string>; // recurring: per-occurrence notes keyed by date
}
