// Timezone infrastructure for the calendar. The timeline's hours (0–24) are in the
// MAIN timezone; an optional ALTERNATIVE timezone is shown as a secondary axis whose
// labels are the main hours shifted by the (DST-aware) offset between the two zones.

export const DEFAULT_MAIN_TZ = "America/New_York";

// Sentinel stored for the MAIN timezone when it should follow the system/browser zone.
// Resolved to a concrete zone (systemTz) wherever the main zone is actually used.
export const AUTO_TZ = "auto";

// The browser/OS timezone (falls back to the default if the platform won't report it).
export function systemTz(): string {
  try { return Intl.DateTimeFormat().resolvedOptions().timeZone || DEFAULT_MAIN_TZ; }
  catch { return DEFAULT_MAIN_TZ; }
}

export interface TzOption { id: string; label: string }

// Alternative-timezone options offered in the top-bar selector.
export const COMMON_TZS: TzOption[] = [
  { id: "Asia/Shanghai", label: "Beijing Time" },
  { id: "Asia/Tokyo", label: "Tokyo Time" },
  { id: "America/Los_Angeles", label: "US West" },
  { id: "Europe/London", label: "London" },
];

// Main-timezone options offered in the Edit menu (the timeline's hours run in this zone).
export const MAIN_TZS: TzOption[] = [
  { id: "America/New_York", label: "US Eastern" },
  { id: "America/Chicago", label: "US Central" },
  { id: "America/Denver", label: "US Mountain" },
  { id: "America/Los_Angeles", label: "US Pacific" },
  { id: "Europe/London", label: "London" },
  { id: "Asia/Shanghai", label: "Beijing Time" },
  { id: "Asia/Tokyo", label: "Tokyo Time" },
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

// "UTC-5" / "UTC+8" / "UTC+5:30" — the zone's current offset from UTC (DST-aware).
export function tzUtcOffset(tz: string, date: Date): string {
  const off = tzOffsetMinutes(tz, date);
  const a = Math.abs(off);
  const h = Math.floor(a / 60), m = a % 60;
  return `UTC${off < 0 ? "-" : "+"}${h}${m ? `:${String(m).padStart(2, "0")}` : ""}`;
}

// "EST · UTC-5" — the zone's short acronym plus its current UTC offset (for menu rows).
export function tzShortInfo(tz: string, date: Date): string {
  return `${tzAbbrev(tz, date)} · ${tzUtcOffset(tz, date)}`;
}
