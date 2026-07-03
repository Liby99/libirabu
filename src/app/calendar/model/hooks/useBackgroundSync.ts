import { useEffect, useRef } from "react";

// Poll the background auto-sync status so changes applied server-side (docs §12.3) aren't silent:
// when a new tick has landed with created/updated events, fire the same "calendar:changed" event the
// manual import uses, so every calendar hook refetches and the new events appear in the open view.
export function useBackgroundSync(pollMs = 60_000): void {
  const lastSeen = useRef<string | null>(null);
  useEffect(() => {
    let alive = true;
    const check = async () => {
      try {
        const res = await fetch("/api/calendar/sync-status");
        if (!res.ok) return;
        const s = (await res.json()) as { lastRunAt: string | null; created: number; merged: number };
        if (!s.lastRunAt || s.lastRunAt === lastSeen.current) return;
        const first = lastSeen.current === null;
        lastSeen.current = s.lastRunAt;
        // Skip the mount read (don't refetch for a sync that happened before this session); only
        // react to ticks that land while the page is open and actually changed something.
        if (!first && (s.created > 0 || s.merged > 0) && typeof window !== "undefined") {
          window.dispatchEvent(new CustomEvent("calendar:changed"));
        }
      } catch { /* offline / not signed in — ignore */ }
    };
    void check();
    const id = setInterval(() => { if (alive) void check(); }, pollMs);
    return () => { alive = false; clearInterval(id); };
  }, [pollMs]);
}
