import { useCallback, useEffect, useRef, useState } from "react";
import { BandEvent } from "./bandEventTypes";
import { apiToBand, fetchEvents, createBand, patchBand, deleteEvent } from "./apiClient";

let _seq = 0;
const nextId = () => `bev-${Date.now().toString(36)}-${_seq++}`;
const PATCH_DEBOUNCE = 400;

// All-day (band) events for the displayed year, persisted via /api/calendar. Optimistic
// local state; background sync. Stacking is by start day (see BandEventView), not order.
export function useBandEvents(year: number) {
  const [events, setEvents] = useState<BandEvent[]>([]);
  const eventsRef = useRef<BandEvent[]>([]);
  eventsRef.current = events;
  const timers = useRef<Map<string, ReturnType<typeof setTimeout>>>(new Map());

  useEffect(() => {
    let alive = true;
    fetchEvents(year, "band")
      .then((rows) => { if (alive) setEvents(rows.map(apiToBand)); })
      .catch((e) => console.error("[calendar] load band events", e));
    return () => { alive = false; };
  }, [year]);

  useEffect(() => () => { timers.current.forEach(clearTimeout); timers.current.clear(); }, []);

  const scheduleFlush = useCallback((id: string) => {
    const prev = timers.current.get(id);
    if (prev) clearTimeout(prev);
    timers.current.set(id, setTimeout(() => {
      timers.current.delete(id);
      const ev = eventsRef.current.find((e) => e.id === id);
      if (ev) patchBand(ev).catch((e) => console.error("[calendar] patch band", e));
    }, PATCH_DEBOUNCE));
  }, []);

  const addEvent = useCallback((ev: Omit<BandEvent, "id">): BandEvent => {
    const full: BandEvent = { ...ev, id: nextId() };
    setEvents((es) => [...es, full]);
    createBand(full).catch((e) => {
      console.error("[calendar] create band", e);
      setEvents((es) => es.filter((x) => x.id !== full.id)); // rollback on failure
    });
    return full;
  }, []);

  const updateEvent = useCallback((id: string, patch: Partial<BandEvent>) => {
    setEvents((es) => es.map((e) => (e.id === id ? { ...e, ...patch } : e)));
    scheduleFlush(id);
  }, [scheduleFlush]);

  const removeEvent = useCallback((id: string) => {
    if (!eventsRef.current.some((e) => e.id === id)) return; // not a band event — leave it to the right store
    const t = timers.current.get(id);
    if (t) { clearTimeout(t); timers.current.delete(id); }
    setEvents((es) => es.filter((e) => e.id !== id));
    deleteEvent(id).catch((e) => console.error("[calendar] delete band", e));
  }, []);

  return { events, addEvent, updateEvent, removeEvent };
}
