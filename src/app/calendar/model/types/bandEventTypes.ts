// All-day (band) events: multi-day bars on a track lane. Single month for now.

export interface BandEvent {
  id: string;
  year: number;
  month: number;   // 0–11
  track: number;   // 0–3 (lane)
  startDay: number; // 1..daysInMonth
  endDay: number;   // 1..daysInMonth (inclusive, >= startDay)
  title: string;
  color: string;    // palette key — shares EVENT_COLORS with timed events
  notes?: string;
  tags?: string[];
  repeat?: import("@/lib/calendar/api").Repeat;
  createdByAI?: boolean; // provenance: created/edited by the AI assistant
  imported?: boolean; // provenance: pulled from an external calendar (Apple/.ics)
  hidden?: boolean; // soft-deleted (imported events) — hidden from the calendar unless "Show hidden" is on
  externalUrl?: string | null; // "open at source" deep link, when imported
  occurrenceNotes?: Record<string, string>; // recurring: per-occurrence notes keyed by date
}
