// Timezone infrastructure for the calendar. The timeline's hours (0–24) are in the
// MAIN timezone; an optional ALTERNATIVE timezone is shown as a secondary axis whose
// labels are the main hours shifted by the (DST-aware) offset between the two zones.

export const DEFAULT_MAIN_TZ = "America/New_York";

export interface TzOption { id: string; label: string }

// Alternative-timezone options offered in the top-bar selector.
export const COMMON_TZS: TzOption[] = [
  { id: "Asia/Shanghai", label: "Beijing Time" },
  { id: "Asia/Tokyo", label: "Tokyo Time" },
  { id: "America/Los_Angeles", label: "US West" },
  { id: "Europe/London", label: "London" },
];

// Offset in minutes east of UTC for `tz` at the given instant (DST-aware).
export function tzOffsetMinutes(tz: string, date: Date): number {
  const asTz = new Date(date.toLocaleString("en-US", { timeZone: tz }));
  const asUtc = new Date(date.toLocaleString("en-US", { timeZone: "UTC" }));
  return Math.round((asTz.getTime() - asUtc.getTime()) / 60000);
}

// Hours that `altTz` leads `mainTz` by at `date` (e.g. New York → Los Angeles = -3).
export function tzDeltaHours(mainTz: string, altTz: string, date: Date): number {
  return (tzOffsetMinutes(altTz, date) - tzOffsetMinutes(mainTz, date)) / 60;
}

// Short zone label like "EST" / "PDT" for an axis header.
export function tzAbbrev(tz: string, date: Date): string {
  const parts = new Intl.DateTimeFormat("en-US", { timeZone: tz, timeZoneName: "short" }).formatToParts(date);
  return parts.find((p) => p.type === "timeZoneName")?.value ?? tz;
}
