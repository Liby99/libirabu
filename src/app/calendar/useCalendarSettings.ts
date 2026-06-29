import { useCallback, useEffect, useRef, useState } from "react";
import { DEFAULT_MAIN_TZ, defaultTrackNames } from "@/lib/calendar/api";
import { AUTO_TZ, systemTz } from "./timezones";
import { fetchSettings, putSettings } from "./apiClient";

const PUT_DEBOUNCE = 500; // coalesce keystrokes while renaming a track lane

// Calendar preferences, persisted via /api/calendar/settings. Track-lane names are PER-YEAR
// (a map year→[12][4]); main/alt timezone are global. The whole map is fetched once and
// indexed by the active `year` on the client, so switching years re-derives instantly and a
// year with no saved names shows blank (cleared). Optimistic local state; debounced saves.
export function useCalendarSettings(year: number) {
  const [trackMap, setTrackMap] = useState<Record<string, string[][]>>({});
  // The stored MAIN-tz *setting* (a concrete zone id, or AUTO_TZ to follow the system zone).
  const [mainTzSetting, setMainTzState] = useState<string>(DEFAULT_MAIN_TZ);
  const [altTz, setAltTzState] = useState<string | null>(null);
  const mapRef = useRef<Record<string, string[][]>>(trackMap);
  mapRef.current = trackMap;
  const yearRef = useRef(year);
  yearRef.current = year;
  const trackTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    let alive = true;
    fetchSettings()
      .then((s) => { if (alive) { setTrackMap(s.trackNames ?? {}); setMainTzState(s.mainTz); setAltTzState(s.altTz); } })
      .catch((e) => console.error("[calendar] load settings", e));
    return () => { alive = false; };
  }, []);

  useEffect(() => () => { if (trackTimer.current) clearTimeout(trackTimer.current); }, []);

  // The active year's [12][4] grid — blank default when the year has no saved names.
  const trackNames = trackMap[String(year)] ?? defaultTrackNames();

  const editTrack = useCallback((m: number, i: number, val: string) => {
    setTrackMap((prev) => {
      const key = String(yearRef.current);
      const grid = (prev[key] ?? defaultTrackNames()).map((r) => r.slice());
      grid[m][i] = val;
      return { ...prev, [key]: grid };
    });
    if (trackTimer.current) clearTimeout(trackTimer.current);
    trackTimer.current = setTimeout(() => {
      putSettings({ trackNames: mapRef.current }).catch((e) => console.error("[calendar] save track names", e));
    }, PUT_DEBOUNCE);
  }, []);

  const setAltTz = useCallback((tz: string | null) => {
    setAltTzState(tz);
    putSettings({ altTz: tz }).catch((e) => console.error("[calendar] save altTz", e));
  }, []);

  const setMainTz = useCallback((tz: string) => {
    setMainTzState(tz);
    putSettings({ mainTz: tz }).catch((e) => console.error("[calendar] save mainTz", e));
  }, []);

  // The effective main zone consumers use — AUTO resolves to the live system zone.
  const mainTz = mainTzSetting === AUTO_TZ ? systemTz() : mainTzSetting;

  return { trackNames, editTrack, mainTz, mainTzSetting, altTz, setAltTz, setMainTz };
}
