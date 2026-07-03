// Calendar-wide undo/redo stack + per-store edit coalescing (useHistory, useTxnRecorder).

import { useCallback, useEffect, useMemo, useReducer, useRef } from "react";

// ── Calendar-level undo/redo ──────────────────────────────────────────────
// A single shared stack of inverse-command entries. Entries are pushed at logical
// COMMIT boundaries (a finished drag, a discrete click, a settled text edit), never per
// React state change — see useTxnRecorder for the coalescing that makes a whole gesture
// one entry. undo()/redo() replay the closures with recording SUSPENDED, so re-issuing a
// mutation through the same store (which also persists it) doesn't record a second time.
//
// This is deliberately one level ABOVE the browser's native per-field text history: while
// a text input/textarea is focused, Cmd+Z is left to the browser (the key handler bails on
// INPUT/TEXTAREA), and the net text change lands here as one coalesced entry once it settles.

export interface HistoryEntry {
  label: string;
  undo: () => void;
  redo: () => void;
}

export interface History {
  push: (e: HistoryEntry) => void;
  undo: () => void;
  redo: () => void;
  clear: () => void;
  suspended: () => boolean;
  /** Run `fn` with recording SUSPENDED (sub-mutations don't self-record), returning its result.
   *  Lets a composite action (e.g. "isolate") perform several store mutations yet push ONE entry. */
  run: <T>(fn: () => T) => T;
  /** Register a pending-edit flush, run before any undo/redo so in-flight edits commit first. */
  register: (flush: () => void) => () => void;
  canUndo: boolean;
  canRedo: boolean;
}

export function useHistory(limit = 100): History {
  const undoS = useRef<HistoryEntry[]>([]);
  const redoS = useRef<HistoryEntry[]>([]);
  const suspendedRef = useRef(false);
  const flushes = useRef<Set<() => void>>(new Set());
  const [, force] = useReducer((x) => x + 1, 0);

  const runFlushes = useCallback(() => { flushes.current.forEach((f) => f()); }, []);

  const push = useCallback((e: HistoryEntry) => {
    if (suspendedRef.current) return; // replaying an undo/redo — don't record the replay
    undoS.current.push(e);
    if (undoS.current.length > limit) undoS.current.shift();
    redoS.current = [];
    force();
  }, [limit]);

  const undo = useCallback(() => {
    runFlushes();
    const e = undoS.current.pop();
    if (!e) return;
    suspendedRef.current = true;
    try { e.undo(); } finally { suspendedRef.current = false; }
    redoS.current.push(e);
    force();
  }, [runFlushes]);

  const redo = useCallback(() => {
    runFlushes();
    const e = redoS.current.pop();
    if (!e) return;
    suspendedRef.current = true;
    try { e.redo(); } finally { suspendedRef.current = false; }
    undoS.current.push(e);
    force();
  }, [runFlushes]);

  const clear = useCallback(() => { undoS.current = []; redoS.current = []; force(); }, []);
  const suspended = useCallback(() => suspendedRef.current, []);
  const run = useCallback(<T,>(fn: () => T): T => {
    const prev = suspendedRef.current;
    suspendedRef.current = true;
    try { return fn(); } finally { suspendedRef.current = prev; }
  }, []);
  const register = useCallback((flush: () => void) => {
    flushes.current.add(flush);
    return () => { flushes.current.delete(flush); };
  }, []);

  const canUndo = undoS.current.length > 0;
  const canRedo = redoS.current.length > 0;
  // Stable identity except when undo/redo availability actually flips, so consumers (the
  // stores) don't churn their callbacks on every render.
  return useMemo<History>(
    () => ({ push, undo, redo, clear, suspended, run, register, canUndo, canRedo }),
    [push, undo, redo, clear, suspended, run, register, canUndo, canRedo],
  );
}

// ── Per-store edit coalescer ──────────────────────────────────────────────
// note(id) is called at the start of every updateX(): the FIRST note for an id (since the
// last flush) snapshots the pre-edit object; subsequent notes to the same id extend a short
// timer. When it settles (or a different id is touched, or an undo/redo is about to run, or
// the component unmounts) one entry is pushed for the net before→after change. So a drag's
// flood of updates, or a burst of typing, becomes a single undo step.
const COALESCE_MS = 500; // slightly longer than the PATCH debounce so a gesture settles first

export function useTxnRecorder<T extends { id: string }>(
  history: History,
  getById: (id: string) => T | undefined,
  apply: (full: T) => void, // restore a full snapshot (used by both undo and redo)
  label = "Edit event",
) {
  const pend = useRef<{ id: string; before: T } | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const flush = useCallback(() => {
    if (timer.current) { clearTimeout(timer.current); timer.current = null; }
    const p = pend.current;
    if (!p) return;
    pend.current = null;
    const after = getById(p.id);
    if (!after) return; // gone (deleted) — its own delete entry covers the removal
    if (JSON.stringify(p.before) === JSON.stringify(after)) return; // no net change
    const before = p.before;
    const afterSnap = { ...after };
    history.push({ label, undo: () => apply(before), redo: () => apply(afterSnap) });
  }, [history, getById, apply, label]);

  const note = useCallback((id: string) => {
    if (history.suspended()) return; // replaying — the patch itself isn't a new edit
    if (pend.current && pend.current.id !== id) flush(); // switched targets → commit the old one
    if (!pend.current) {
      const cur = getById(id);
      if (!cur) return;
      pend.current = { id, before: { ...cur } };
    }
    if (timer.current) clearTimeout(timer.current);
    timer.current = setTimeout(flush, COALESCE_MS);
  }, [history, getById, flush]);

  useEffect(() => history.register(flush), [history, flush]); // commit before any undo/redo
  useEffect(() => () => { if (timer.current) clearTimeout(timer.current); }, []);

  return { note, flush };
}
