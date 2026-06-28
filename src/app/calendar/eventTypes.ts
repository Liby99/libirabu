// Client-side timed (hourly) calendar events. Stored in React state for now
// (no persistence); a later pass wires these to the CalEvent server actions.

export interface TimedEvent {
  id: string;
  year: number;
  month: number;     // 0–11
  day: number;       // 1–31 (real day-of-month within `month`)
  startHour: number; // decimal hours in [0, 24]
  endHour: number;
  title: string;
  color: string;     // palette key — see EVENT_COLORS
  notes?: string;
  tags?: string[];
  repeat?: import("@/lib/calendar/api").Repeat;
  createdByAI?: boolean; // provenance: created/edited by the AI assistant
}

export const EVENT_COLORS = ["default", "blue", "indigo", "cyan", "green", "darkgreen", "yellow", "orange", "red", "purple"] as const;
// Smaller curated set shown in the right-click callout (the drawer offers the full set).
export const MENU_COLORS = ["default", "blue", "green", "yellow", "red", "purple"] as const;

// Round a decimal hour to the nearest `stepMin` minutes, clamped to [0, 24].
export function snapHour(hour: number, stepMin: number): number {
  const step = stepMin / 60;
  return Math.max(0, Math.min(24, Math.round(hour / step) * step));
}

function hhmm(hour: number): string {
  const total = Math.round(hour * 60);
  return `${String(Math.floor(total / 60) % 24).padStart(2, "0")}:${String(total % 60).padStart(2, "0")}`;
}

export function fmtRange(startHour: number, endHour: number): string {
  return `${hhmm(startHour)} – ${hhmm(endHour)}`;
}

// Decimal hour ↔ "HH:MM" for <input type="time"> (which can't represent 24:00,
// so a midnight end clamps to 23:59 for display only — the model keeps 24).
export function hourToTimeInput(h: number): string {
  const total = Math.min(1439, Math.max(0, Math.round(h * 60)));
  return `${String(Math.floor(total / 60)).padStart(2, "0")}:${String(total % 60).padStart(2, "0")}`;
}

export function timeInputToHour(s: string): number | null {
  const m = /^(\d{1,2}):(\d{2})$/.exec(s);
  if (!m) return null;
  const h = +m[1], mm = +m[2];
  if (h > 24 || mm > 59) return null;
  return Math.min(24, h + mm / 60);
}
