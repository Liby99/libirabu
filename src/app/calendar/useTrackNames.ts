import { useCallback, useEffect, useState } from "react";

// Per-month editable track names (4 per month), persisted to localStorage.
const KEY = "libirabu-calendar-tracknames";
const DEFAULTS = ["Teaching", "Research", "Service", "Travel"];

export function useTrackNames() {
  const [trackNames, setTrackNames] = useState<string[][]>(() =>
    Array.from({ length: 12 }, () => [...DEFAULTS]));

  useEffect(() => {
    try {
      const s = localStorage.getItem(KEY);
      if (s) setTrackNames(JSON.parse(s));
    } catch { /* ignore */ }
  }, []);

  const editTrack = useCallback((m: number, i: number, val: string) => {
    setTrackNames((prev) => {
      const next = prev.map((r) => r.slice());
      next[m][i] = val;
      try { localStorage.setItem(KEY, JSON.stringify(next)); } catch { /* ignore */ }
      return next;
    });
  }, []);

  return { trackNames, editTrack };
}
