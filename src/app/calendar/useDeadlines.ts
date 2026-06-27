import { useCallback, useEffect, useRef, useState } from "react";
import { Deadline } from "./deadlineTypes";
import { apiToDeadline, fetchEvents, createDeadline, patchDeadline, deleteEvent } from "./apiClient";

let _seq = 0;
const nextId = () => `ddl-${Date.now().toString(36)}-${_seq++}`;
const PATCH_DEBOUNCE = 400;

// Deadlines for the displayed year, persisted via /api/calendar. Optimistic local state
// + debounced background sync (mirrors useEvents / useBandEvents).
export function useDeadlines(year: number) {
  const [deadlines, setDeadlines] = useState<Deadline[]>([]);
  const ref = useRef<Deadline[]>([]);
  ref.current = deadlines;
  const timers = useRef<Map<string, ReturnType<typeof setTimeout>>>(new Map());

  useEffect(() => {
    let alive = true;
    fetchEvents(year, "deadline")
      .then((rows) => { if (alive) setDeadlines(rows.map(apiToDeadline)); })
      .catch((e) => console.error("[calendar] load deadlines", e));
    return () => { alive = false; };
  }, [year]);

  useEffect(() => () => { timers.current.forEach(clearTimeout); timers.current.clear(); }, []);

  const scheduleFlush = useCallback((id: string) => {
    const prev = timers.current.get(id);
    if (prev) clearTimeout(prev);
    timers.current.set(id, setTimeout(() => {
      timers.current.delete(id);
      const d = ref.current.find((x) => x.id === id);
      if (d) patchDeadline(d).catch((e) => console.error("[calendar] patch deadline", e));
    }, PATCH_DEBOUNCE));
  }, []);

  const addDeadline = useCallback((d: Omit<Deadline, "id">): Deadline => {
    const full: Deadline = { ...d, id: nextId() };
    setDeadlines((ds) => [...ds, full]);
    createDeadline(full).catch((e) => {
      console.error("[calendar] create deadline", e);
      setDeadlines((ds) => ds.filter((x) => x.id !== full.id));
    });
    return full;
  }, []);

  const updateDeadline = useCallback((id: string, patch: Partial<Deadline>) => {
    setDeadlines((ds) => ds.map((d) => (d.id === id ? { ...d, ...patch } : d)));
    scheduleFlush(id);
  }, [scheduleFlush]);

  const removeDeadline = useCallback((id: string) => {
    if (!ref.current.some((d) => d.id === id)) return; // not a deadline — leave it to the right store
    const t = timers.current.get(id);
    if (t) { clearTimeout(t); timers.current.delete(id); }
    setDeadlines((ds) => ds.filter((d) => d.id !== id));
    deleteEvent(id).catch((e) => console.error("[calendar] delete deadline", e));
  }, []);

  return { deadlines, addDeadline, updateDeadline, removeDeadline };
}
