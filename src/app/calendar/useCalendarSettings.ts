import { useCallback, useEffect, useRef, useState } from "react";
import { DEFAULT_MAIN_TZ, defaultTrackNames } from "@/lib/calendar/api";
import { fetchSettings, putSettings } from "./apiClient";

const PUT_DEBOUNCE = 500; // coalesce keystrokes while renaming a track lane

// Calendar preferences (per-month track lane names + main/alt timezone), persisted via
// /api/calendar/settings. Replaces the old localStorage useTrackNames + in-memory
// useTimezones. Optimistic local state; debounced background saves.
export function useCalendarSettings() {
  const [trackNames, setTrackNames] = useState<string[][]>(defaultTrackNames());
  const [mainTz, setMainTzState] = useState<string>(DEFAULT_MAIN_TZ);
  const [altTz, setAltTzState] = useState<string | null>(null);
  const trackRef = useRef<string[][]>(trackNames);
  trackRef.current = trackNames;
  const trackTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    let alive = true;
    fetchSettings()
      .then((s) => { if (alive) { setTrackNames(s.trackNames); setMainTzState(s.mainTz); setAltTzState(s.altTz); } })
      .catch((e) => console.error("[calendar] load settings", e));
    return () => { alive = false; };
  }, []);

  useEffect(() => () => { if (trackTimer.current) clearTimeout(trackTimer.current); }, []);

  const editTrack = useCallback((m: number, i: number, val: string) => {
    setTrackNames((prev) => {
      const next = prev.map((r) => r.slice());
      next[m][i] = val;
      return next;
    });
    if (trackTimer.current) clearTimeout(trackTimer.current);
    trackTimer.current = setTimeout(() => {
      putSettings({ trackNames: trackRef.current }).catch((e) => console.error("[calendar] save track names", e));
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

  return { trackNames, editTrack, mainTz, altTz, setAltTz, setMainTz };
}
