import { useCallback, useEffect, useRef, useState } from "react";
import { TimedEvent } from "./eventTypes";
import { apiToTimed, fetchEvents, createTimed, patchTimed, deleteEvent } from "./apiClient";

let _seq = 0;
const nextId = () => `tev-${Date.now().toString(36)}-${_seq++}`;
const PATCH_DEBOUNCE = 400; // coalesce the flood of updates during a drag into one PATCH

// Timed events for the displayed year, persisted via /api/calendar. Local state is the
// source of truth for snappy UI; writes are optimistic and synced in the background.
export function useEvents(year: number) {
  const [events, setEvents] = useState<TimedEvent[]>([]);
  const eventsRef = useRef<TimedEvent[]>([]);
  eventsRef.current = events;
  const timers = useRef<Map<string, ReturnType<typeof setTimeout>>>(new Map());

  useEffect(() => {
    let alive = true;
    fetchEvents(year, "timed")
      .then((rows) => { if (alive) setEvents(rows.map(apiToTimed)); })
      .catch((e) => console.error("[calendar] load timed events", e));
    return () => { alive = false; };
  }, [year]);

  useEffect(() => () => { timers.current.forEach(clearTimeout); timers.current.clear(); }, []);

  // PATCH the event's latest full state (idempotent), debounced per id.
  const scheduleFlush = useCallback((id: string) => {
    const prev = timers.current.get(id);
    if (prev) clearTimeout(prev);
    timers.current.set(id, setTimeout(() => {
      timers.current.delete(id);
      const ev = eventsRef.current.find((e) => e.id === id);
      if (ev) patchTimed(ev).catch((e) => console.error("[calendar] patch timed", e));
    }, PATCH_DEBOUNCE));
  }, []);

  const addEvent = useCallback((ev: Omit<TimedEvent, "id">): TimedEvent => {
    const full: TimedEvent = { ...ev, id: nextId() };
    setEvents((es) => [...es, full]);
    createTimed(full).catch((e) => {
      console.error("[calendar] create timed", e);
      setEvents((es) => es.filter((x) => x.id !== full.id)); // rollback on failure
    });
    return full;
  }, []);

  const updateEvent = useCallback((id: string, patch: Partial<TimedEvent>) => {
    setEvents((es) => es.map((e) => (e.id === id ? { ...e, ...patch } : e)));
    scheduleFlush(id);
  }, [scheduleFlush]);

  const removeEvent = useCallback((id: string) => {
    if (!eventsRef.current.some((e) => e.id === id)) return; // not a timed event — leave it to the right store
    const t = timers.current.get(id);
    if (t) { clearTimeout(t); timers.current.delete(id); }
    setEvents((es) => es.filter((e) => e.id !== id));
    deleteEvent(id).catch((e) => console.error("[calendar] delete timed", e));
  }, []);

  return { events, addEvent, updateEvent, removeEvent };
}
