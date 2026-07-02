// Deadline store: optimistic local state + debounced PATCH + undo/redo integration.

import { useCallback, useEffect, useRef, useState } from "react";
import { Deadline } from "../types/deadlineTypes";
import { apiToDeadline, fetchEvents, createDeadline, patchDeadline, deleteEvent } from "../api/apiClient";
import { History, useTxnRecorder } from "../history";

let _seq = 0;
const nextId = () => `ddl-${Date.now().toString(36)}-${_seq++}`;
const PATCH_DEBOUNCE = 400;

// Deadlines for the displayed year, persisted via /api/calendar. Optimistic local state
// + debounced background sync (mirrors useEvents / useBandEvents), and feeds the shared
// undo/redo History the same way.
export function useDeadlines(year: number, history: History, includeHidden = false) {
  const [deadlines, setDeadlines] = useState<Deadline[]>([]);
  const ref = useRef<Deadline[]>([]);
  ref.current = deadlines;
  const timers = useRef<Map<string, ReturnType<typeof setTimeout>>>(new Map());

  useEffect(() => {
    let alive = true;
    const load = () => fetchEvents(year, "deadline", includeHidden)
      .then((rows) => { if (alive) setDeadlines(rows.map(apiToDeadline)); })
      .catch((e) => console.error("[calendar] load deadlines", e));
    load();
    window.addEventListener("calendar:changed", load);
    return () => { alive = false; window.removeEventListener("calendar:changed", load); };
  }, [year, includeHidden]);

  useEffect(() => () => { timers.current.forEach(clearTimeout); timers.current.clear(); }, []);

  const scheduleFlush = useCallback((id: string) => {
    const prev = timers.current.get(id);
    if (prev) clearTimeout(prev);
    timers.current.set(id, setTimeout(() => {
      timers.current.delete(id);
      const d = ref.current.find((x) => x.id === id);
      if (d) patchDeadline(d).then(() => window.dispatchEvent(new Event("calendar:todos-changed"))).catch((e) => console.error("[calendar] patch deadline", e));
    }, PATCH_DEBOUNCE));
  }, []);

  const getById = useCallback((id: string) => ref.current.find((d) => d.id === id), []);
  const applyFull = useCallback((full: Deadline) => {
    setDeadlines((ds) => ds.map((d) => (d.id === full.id ? full : d)));
    scheduleFlush(full.id);
  }, [scheduleFlush]);
  const rec = useTxnRecorder<Deadline>(history, getById, applyFull, "Edit deadline");

  const restoreDeadline = useCallback((full: Deadline) => {
    setDeadlines((ds) => (ds.some((d) => d.id === full.id) ? ds : [...ds, full]));
    createDeadline(full).catch((e) => {
      console.error("[calendar] restore deadline", e);
      setDeadlines((ds) => ds.filter((x) => x.id !== full.id));
    });
  }, []);

  const removeDeadline = useCallback((id: string) => {
    const full = ref.current.find((d) => d.id === id);
    if (!full) return; // not a deadline — leave it to the right store
    rec.flush();
    const t = timers.current.get(id);
    if (t) { clearTimeout(t); timers.current.delete(id); }
    setDeadlines((ds) => ds.filter((d) => d.id !== id));
    deleteEvent(id).catch((e) => console.error("[calendar] delete deadline", e));
    history.push({ label: "Delete deadline", undo: () => restoreDeadline(full), redo: () => removeDeadline(id) });
  }, [rec, history, restoreDeadline]);

  const addDeadline = useCallback((d: Omit<Deadline, "id">): Deadline => {
    rec.flush();
    const full: Deadline = { ...d, id: nextId() };
    setDeadlines((ds) => [...ds, full]);
    createDeadline(full).catch((e) => {
      console.error("[calendar] create deadline", e);
      setDeadlines((ds) => ds.filter((x) => x.id !== full.id));
    });
    history.push({ label: "Create deadline", undo: () => removeDeadline(full.id), redo: () => restoreDeadline(full) });
    return full;
  }, [rec, history, removeDeadline, restoreDeadline]);

  const updateDeadline = useCallback((id: string, patch: Partial<Deadline>) => {
    rec.note(id);
    setDeadlines((ds) => ds.map((d) => (d.id === id ? { ...d, ...patch } : d)));
    scheduleFlush(id);
  }, [rec, scheduleFlush]);

  return { deadlines, addDeadline, updateDeadline, removeDeadline };
}
