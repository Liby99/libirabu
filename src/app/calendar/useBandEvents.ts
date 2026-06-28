import { useCallback, useEffect, useRef, useState } from "react";
import { BandEvent } from "./bandEventTypes";
import { apiToBand, fetchEvents, createBand, patchBand, deleteEvent } from "./apiClient";
import { History, useTxnRecorder } from "./history";

let _seq = 0;
const nextId = () => `bev-${Date.now().toString(36)}-${_seq++}`;
const PATCH_DEBOUNCE = 400;

// All-day (band) events for the displayed year, persisted via /api/calendar. Optimistic
// local state; background sync. Stacking is by start day (see BandEventView), not order.
// Mutations also feed the shared undo/redo History (see useEvents for the pattern).
export function useBandEvents(year: number, history: History) {
  const [events, setEvents] = useState<BandEvent[]>([]);
  const eventsRef = useRef<BandEvent[]>([]);
  eventsRef.current = events;
  const timers = useRef<Map<string, ReturnType<typeof setTimeout>>>(new Map());

  useEffect(() => {
    let alive = true;
    const load = () => fetchEvents(year, "band")
      .then((rows) => { if (alive) setEvents(rows.map(apiToBand)); })
      .catch((e) => console.error("[calendar] load band events", e));
    load();
    window.addEventListener("calendar:changed", load);
    return () => { alive = false; window.removeEventListener("calendar:changed", load); };
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

  const getById = useCallback((id: string) => eventsRef.current.find((e) => e.id === id), []);
  const applyFull = useCallback((full: BandEvent) => {
    setEvents((es) => es.map((e) => (e.id === full.id ? full : e)));
    scheduleFlush(full.id);
  }, [scheduleFlush]);
  const rec = useTxnRecorder<BandEvent>(history, getById, applyFull, "Edit event");

  const restoreEvent = useCallback((full: BandEvent) => {
    setEvents((es) => (es.some((e) => e.id === full.id) ? es : [...es, full]));
    createBand(full).catch((e) => {
      console.error("[calendar] restore band", e);
      setEvents((es) => es.filter((x) => x.id !== full.id));
    });
  }, []);

  const removeEvent = useCallback((id: string) => {
    const full = eventsRef.current.find((e) => e.id === id);
    if (!full) return; // not a band event — leave it to the right store
    rec.flush();
    const t = timers.current.get(id);
    if (t) { clearTimeout(t); timers.current.delete(id); }
    setEvents((es) => es.filter((e) => e.id !== id));
    deleteEvent(id).catch((e) => console.error("[calendar] delete band", e));
    history.push({ label: "Delete event", undo: () => restoreEvent(full), redo: () => removeEvent(id) });
  }, [rec, history, restoreEvent]);

  const addEvent = useCallback((ev: Omit<BandEvent, "id">): BandEvent => {
    rec.flush();
    const full: BandEvent = { ...ev, id: nextId() };
    setEvents((es) => [...es, full]);
    createBand(full).catch((e) => {
      console.error("[calendar] create band", e);
      setEvents((es) => es.filter((x) => x.id !== full.id)); // rollback on failure
    });
    history.push({ label: "Create event", undo: () => removeEvent(full.id), redo: () => restoreEvent(full) });
    return full;
  }, [rec, history, removeEvent, restoreEvent]);

  const updateEvent = useCallback((id: string, patch: Partial<BandEvent>) => {
    rec.note(id);
    setEvents((es) => es.map((e) => (e.id === id ? { ...e, ...patch } : e)));
    scheduleFlush(id);
  }, [rec, scheduleFlush]);

  return { events, addEvent, updateEvent, removeEvent };
}
