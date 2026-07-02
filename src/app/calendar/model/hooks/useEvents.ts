// Timed-event store: optimistic local state + debounced PATCH + undo/redo integration.

import { useCallback, useEffect, useRef, useState } from "react";
import { TimedEvent } from "../types/eventTypes";
import { apiToTimed, fetchEvents, createTimed, patchTimed, deleteEvent } from "../api/apiClient";
import { History, useTxnRecorder } from "../history";

let _seq = 0;
const nextId = () => `tev-${Date.now().toString(36)}-${_seq++}`;
const PATCH_DEBOUNCE = 400; // coalesce the flood of updates during a drag into one PATCH

// Timed events for the displayed year, persisted via /api/calendar. Local state is the
// source of truth for snappy UI; writes are optimistic and synced in the background.
// All mutations also feed the shared undo/redo History (edits coalesce per id; create and
// delete push explicit inverse entries; undo/redo replay through these same paths so they
// persist too).
export function useEvents(year: number, history: History, includeHidden = false) {
  const [events, setEvents] = useState<TimedEvent[]>([]);
  const eventsRef = useRef<TimedEvent[]>([]);
  eventsRef.current = events;
  const timers = useRef<Map<string, ReturnType<typeof setTimeout>>>(new Map());

  useEffect(() => {
    let alive = true;
    const load = () => fetchEvents(year, "timed", includeHidden)
      .then((rows) => { if (alive) setEvents(rows.map(apiToTimed)); })
      .catch((e) => console.error("[calendar] load timed events", e));
    load();
    // The AI assistant dispatches this after a server-side write so the canvas refreshes.
    window.addEventListener("calendar:changed", load);
    return () => { alive = false; window.removeEventListener("calendar:changed", load); };
  }, [year, includeHidden]);

  useEffect(() => () => { timers.current.forEach(clearTimeout); timers.current.clear(); }, []);

  // PATCH the event's latest full state (idempotent), debounced per id.
  const scheduleFlush = useCallback((id: string) => {
    const prev = timers.current.get(id);
    if (prev) clearTimeout(prev);
    timers.current.set(id, setTimeout(() => {
      timers.current.delete(id);
      const ev = eventsRef.current.find((e) => e.id === id);
      // notify the TODO index (notes may have changed) — a dedicated event the stores DON'T listen
      // to, so this never reloads the stores (which would disrupt a note being edited in the drawer).
      if (ev) patchTimed(ev).then(() => window.dispatchEvent(new Event("calendar:todos-changed"))).catch((e) => console.error("[calendar] patch timed", e));
    }, PATCH_DEBOUNCE));
  }, []);

  // History plumbing: snapshot-restore by id, and the per-id edit coalescer.
  const getById = useCallback((id: string) => eventsRef.current.find((e) => e.id === id), []);
  const applyFull = useCallback((full: TimedEvent) => {
    setEvents((es) => es.map((e) => (e.id === full.id ? full : e)));
    scheduleFlush(full.id);
  }, [scheduleFlush]);
  const rec = useTxnRecorder<TimedEvent>(history, getById, applyFull, "Edit event");

  // Re-insert a previously-removed event with its ORIGINAL id (the POST route accepts a
  // client id), so undo-of-delete / redo-of-create round-trip cleanly.
  const restoreEvent = useCallback((full: TimedEvent) => {
    setEvents((es) => (es.some((e) => e.id === full.id) ? es : [...es, full]));
    createTimed(full).catch((e) => {
      console.error("[calendar] restore timed", e);
      setEvents((es) => es.filter((x) => x.id !== full.id));
    });
  }, []);

  const removeEvent = useCallback((id: string) => {
    const full = eventsRef.current.find((e) => e.id === id);
    if (!full) return; // not a timed event — leave it to the right store
    rec.flush();
    const t = timers.current.get(id);
    if (t) { clearTimeout(t); timers.current.delete(id); }
    setEvents((es) => es.filter((e) => e.id !== id));
    deleteEvent(id).catch((e) => console.error("[calendar] delete timed", e));
    history.push({ label: "Delete event", undo: () => restoreEvent(full), redo: () => removeEvent(id) });
  }, [rec, history, restoreEvent]);

  const addEvent = useCallback((ev: Omit<TimedEvent, "id">): TimedEvent => {
    rec.flush(); // close any pending edit so the create is its own step
    const full: TimedEvent = { ...ev, id: nextId() };
    setEvents((es) => [...es, full]);
    createTimed(full).catch((e) => {
      console.error("[calendar] create timed", e);
      setEvents((es) => es.filter((x) => x.id !== full.id)); // rollback on failure
    });
    history.push({ label: "Create event", undo: () => removeEvent(full.id), redo: () => restoreEvent(full) });
    return full;
  }, [rec, history, removeEvent, restoreEvent]);

  const updateEvent = useCallback((id: string, patch: Partial<TimedEvent>) => {
    rec.note(id); // snapshot pre-edit state (coalesces a gesture into one undo step)
    setEvents((es) => es.map((e) => (e.id === id ? { ...e, ...patch } : e)));
    scheduleFlush(id);
  }, [rec, scheduleFlush]);

  return { events, addEvent, updateEvent, removeEvent };
}
