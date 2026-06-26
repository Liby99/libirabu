// Shared client-side types + timeline layout for week/day views.

export interface CalEventDTO {
  id: string;
  title: string;
  notes: string | null;
  start: string; // ISO
  end: string; // ISO
  allDay: boolean;
  type: string;
  color: string | null;
  trackId: string | null;
  trackName: string | null;
  trackColor: string | null;
}

export interface TrackDTO {
  id: string;
  key: string;
  name: string;
  color: string;
}

export const HOUR_HEIGHT = 48; // px per hour
export const DAY_HOURS = 24;
export const DEFAULT_SCROLL_HOUR = 7;

/** Effective color for an event: explicit color → track color → neutral. */
export function eventColor(e: CalEventDTO): string {
  return e.color || e.trackColor || "#6b7280";
}

interface Positioned {
  e: CalEventDTO;
  top: number;
  height: number;
  col: number;
  cols: number;
}

/**
 * Lay out timed events for a single day [dayStart, dayEnd]. Returns pixel
 * top/height plus a column assignment so overlapping events sit side by side.
 */
export function layoutDay(
  events: CalEventDTO[],
  dayStart: Date,
  dayEnd: Date,
): Positioned[] {
  const timed = events
    .filter((e) => !e.allDay)
    .map((e) => {
      const s = new Date(e.start);
      const en = new Date(e.end);
      const clampedStart = s < dayStart ? dayStart : s;
      const clampedEnd = en > dayEnd ? dayEnd : en;
      const startMin = (clampedStart.getTime() - dayStart.getTime()) / 60000;
      const endMin = (clampedEnd.getTime() - dayStart.getTime()) / 60000;
      return { e, startMin, endMin: Math.max(endMin, startMin + 15) };
    })
    .sort((a, b) => a.startMin - b.startMin || a.endMin - b.endMin);

  // Greedy column packing over overlap groups.
  const out: Positioned[] = [];
  let group: typeof timed = [];
  let groupEnd = -1;

  const flush = () => {
    if (!group.length) return;
    const colEnds: number[] = []; // last endMin per column
    const assigned = group.map((item) => {
      let col = colEnds.findIndex((end) => end <= item.startMin);
      if (col === -1) {
        col = colEnds.length;
        colEnds.push(item.endMin);
      } else {
        colEnds[col] = item.endMin;
      }
      return { item, col };
    });
    const cols = colEnds.length;
    for (const { item, col } of assigned) {
      out.push({
        e: item.e,
        top: (item.startMin / 60) * HOUR_HEIGHT,
        height: Math.max(((item.endMin - item.startMin) / 60) * HOUR_HEIGHT, 16),
        col,
        cols,
      });
    }
    group = [];
    groupEnd = -1;
  };

  for (const item of timed) {
    if (group.length && item.startMin >= groupEnd) flush();
    group.push(item);
    groupEnd = Math.max(groupEnd, item.endMin);
  }
  flush();
  return out;
}
