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
  occurrenceNotes?: Record<string, string>; // recurring: per-occurrence notes keyed by date
}
