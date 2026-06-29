// Shared formatting for a deadline's label time line.
import { convertWallClock, tzShortLabel } from "@/lib/calendar/api";
import { Deadline } from "../model/types/deadlineTypes";

const pad = (n: number) => String(n).padStart(2, "0");

export function hhmm(hour: number): string {
  let h = Math.floor(hour); let m = Math.round((hour - h) * 60);
  if (m === 60) { m = 0; h += 1; }
  return `${pad(h)}:${pad(m)}`;
}

// "HH:MM" (main tz) plus "(ABBR HH:MM)" of the origin tz when one is set.
export function deadlineTimeLabel(d: Deadline, mainTz: string): string {
  const main = hhmm(d.hour);
  if (!d.originTz) return main;
  const wall = `${d.year}-${pad(d.month + 1)}-${pad(d.day)}T${main}`;
  const origHHMM = convertWallClock(wall, mainTz, d.originTz).split("T")[1].slice(0, 5);
  const date = new Date(Date.UTC(d.year, d.month, d.day, Math.floor(d.hour), Math.round((d.hour % 1) * 60)));
  return `${main} (${tzShortLabel(d.originTz, date)} ${origHHMM})`;
}
