import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { Vp } from "./types";
import { easeInOut } from "./constants";
import { yearMaxScroll } from "./frames";
import { weeksInMonth } from "./dates";
import { monthAtPoint, monthNameAtPoint, weekAtPointInMonth, dayAtPointInWeek } from "./hittest";

// Safari's GestureEvent isn't in the standard DOM lib types.
type GestureLikeEvent = { scale: number; clientX: number; clientY: number; preventDefault: () => void };

// Owns all zoom/pan/scroll state and the gesture handling: pinch-zoom (Safari
// gesture events), iPhone-style horizontal week paging, vertical year scroll,
// click-to-open, and the tween/snap animations.
export function useCalendarInteractions() {
  const wrapRef = useRef<HTMLDivElement>(null);
  const [vp, setVp] = useState<Vp>({ w: 0, h: 0 });
  const [z, setZ] = useState(0);
  const [focus, setFocus] = useState(new Date().getMonth());
  const [week, setWeek] = useState(0);
  const [scrollY, setScrollY] = useState(0);
  const [hoverMonth, setHoverMonth] = useState<number | null>(null);
  const [hoverWeek, setHoverWeek] = useState<number | null>(null);

  const zRef = useRef(z); zRef.current = z;
  const focusRef = useRef(focus); focusRef.current = focus;
  const weekRef = useRef(week); weekRef.current = week;
  const scrollYRef = useRef(scrollY); scrollYRef.current = scrollY;
  const hoverMonthRef = useRef(hoverMonth); hoverMonthRef.current = hoverMonth;
  const hoverWeekRef = useRef(hoverWeek); hoverWeekRef.current = hoverWeek;
  const tweenRef = useRef<number | null>(null);
  const weekTweenRef = useRef<number | null>(null);
  const snapRef = useRef<number | null>(null);

  // measure the viewport
  useLayoutEffect(() => {
    const el = wrapRef.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setVp({ w: el.clientWidth, h: el.clientHeight }));
    ro.observe(el);
    setVp({ w: el.clientWidth, h: el.clientHeight });
    return () => ro.disconnect();
  }, []);

  const clearSnap = () => { if (snapRef.current != null) { clearTimeout(snapRef.current); snapRef.current = null; } };
  const cancelTween = () => { if (tweenRef.current != null) cancelAnimationFrame(tweenRef.current); tweenRef.current = null; };
  const cancelWeekTween = () => { if (weekTweenRef.current != null) cancelAnimationFrame(weekTweenRef.current); weekTweenRef.current = null; };

  const tweenWeek = useCallback((target: number, dur = 240) => {
    cancelWeekTween();
    const start = weekRef.current;
    let t0 = 0;
    const step = (ts: number) => {
      if (!t0) t0 = ts;
      const p = Math.min(1, (ts - t0) / dur);
      setWeek(start + (target - start) * easeInOut(p));
      if (p < 1) weekTweenRef.current = requestAnimationFrame(step);
      else weekTweenRef.current = null;
    };
    weekTweenRef.current = requestAnimationFrame(step);
  }, []);

  const tweenTo = useCallback((targetZ: number, dur = 520, onComplete?: () => void) => {
    cancelTween(); clearSnap();
    const startZ = zRef.current;
    let t0 = 0;
    const step = (ts: number) => {
      if (!t0) t0 = ts;
      const p = Math.min(1, (ts - t0) / dur);
      setZ(startZ + (targetZ - startZ) * easeInOut(p));
      if (p < 1) tweenRef.current = requestAnimationFrame(step);
      else { tweenRef.current = null; onComplete?.(); }
    };
    tweenRef.current = requestAnimationFrame(step);
  }, []);

  // Click a spillover day → zoom out to year, briefly hold, then back into that week.
  const chainTo = useCallback((newMonth: number, newWeek: number) => {
    tweenTo(0, 800, () => {
      setFocus(newMonth);
      setWeek(newWeek);
      window.setTimeout(() => tweenTo(2, 1050), 200);
    });
  }, [tweenTo]);

  // Snap z to the nearest level and (at week level) the week to the nearest week.
  const snapNow = useCallback(() => {
    clearSnap();
    const zt = Math.max(0, Math.min(2, Math.round(zRef.current)));
    if (Math.abs(zt - zRef.current) > 0.004) tweenTo(zt, 260);
    if (Math.round(zRef.current) === 2) {
      const lastWeek = weeksInMonth(focusRef.current) - 1;
      const wt = Math.max(0, Math.min(lastWeek, Math.round(weekRef.current)));
      if (Math.abs(wt - weekRef.current) > 0.004) tweenWeek(wt, 260);
    }
  }, [tweenTo, tweenWeek]);

  // Safari trackpad PINCH → zoom (native gesture events; e.scale is cumulative).
  // Snap only on gestureend, with an idle fallback in case Safari drops it.
  useEffect(() => {
    const el = wrapRef.current;
    if (!el) return;
    let startZ = 0, cx = 0, cy = 0, idle = 0;
    const arm = () => { clearTimeout(idle); idle = window.setTimeout(() => { idle = 0; snapNow(); }, 240); };
    const onStart = (e: GestureLikeEvent) => {
      e.preventDefault();
      cancelTween(); cancelWeekTween(); clearSnap();
      startZ = zRef.current;
      const rect = el.getBoundingClientRect();
      cx = e.clientX - rect.left; cy = e.clientY - rect.top;
      arm();
    };
    const onChange = (e: GestureLikeEvent) => {
      e.preventDefault();
      const vpNow = { w: el.clientWidth, h: el.clientHeight };
      const nz = Math.max(0, Math.min(2, startZ + Math.log2(e.scale) * 0.6)); // lower = slower
      // Lock focus/week once, based on the level we STARTED at + the gesture origin.
      if (nz > startZ && startZ < 0.15) {
        const m = monthAtPoint(cx, cy, vpNow, scrollYRef.current);
        if (m != null) setFocus(m);
      } else if (nz > startZ && startZ >= 0.85 && startZ < 1.15) {
        const w = weekAtPointInMonth(cx, focusRef.current, vpNow);
        if (w != null) setWeek(w);
      }
      setZ(nz);
      arm();
    };
    const onEnd = (e: GestureLikeEvent) => { e.preventDefault(); clearTimeout(idle); idle = 0; snapNow(); };
    const a = el as unknown as {
      addEventListener: (t: string, h: (e: GestureLikeEvent) => void) => void;
      removeEventListener: (t: string, h: (e: GestureLikeEvent) => void) => void;
    };
    a.addEventListener("gesturestart", onStart);
    a.addEventListener("gesturechange", onChange);
    a.addEventListener("gestureend", onEnd);
    return () => {
      clearTimeout(idle);
      a.removeEventListener("gesturestart", onStart);
      a.removeEventListener("gesturechange", onChange);
      a.removeEventListener("gestureend", onEnd);
    };
  }, [snapNow]);

  // Wheel: vertical scroll in year view; horizontal week paging in week view
  // (iPhone-homescreen style — follow, commit on a decisive drag/flick, absorb
  // momentum, page again on a rising-edge swipe).
  useEffect(() => {
    const el = wrapRef.current;
    if (!el) return;
    let session = false, committed = false, startWeek = 0, curWeek = 0, committedTarget = 0, lastAbs = 0;
    let idleTimer = 0;
    const lastIdx = () => weeksInMonth(focusRef.current) - 1;
    const endSession = () => {
      if (session && !committed) { cancelWeekTween(); tweenWeek(Math.max(0, Math.min(lastIdx(), startWeek)), 220); }
      session = false; committed = false;
    };
    const onWheel = (e: WheelEvent) => {
      if (e.ctrlKey) return; // pinch handled via gesture events
      if (zRef.current < 0.5 && Math.abs(e.deltaY) >= Math.abs(e.deltaX)) {
        e.preventDefault();
        const max = yearMaxScroll({ w: el.clientWidth, h: el.clientHeight });
        setScrollY(Math.max(0, Math.min(max, scrollYRef.current + e.deltaY)));
        return;
      }
      if (zRef.current < 1.5 || Math.abs(e.deltaX) <= Math.abs(e.deltaY)) return;
      e.preventDefault();
      clearTimeout(idleTimer);
      idleTimer = window.setTimeout(endSession, 90);
      const ax = Math.abs(e.deltaX);
      if (committed) {
        if (ax > lastAbs * 1.4 + 5) { // rising delta = fresh swipe → page again now
          startWeek = committedTarget; curWeek = committedTarget; committed = false; session = true;
        } else {
          lastAbs = ax;
          return; // absorb decaying momentum
        }
      }
      if (!session) { session = true; committed = false; startWeek = Math.round(weekRef.current); curWeek = weekRef.current; }
      lastAbs = ax;
      cancelWeekTween();
      const last = lastIdx();
      curWeek = Math.max(0, Math.min(last, curWeek + e.deltaX / el.clientWidth));
      setWeek(curWeek);
      const drag = curWeek - startWeek;
      const flick = ax > 12;
      if (Math.abs(drag) >= 0.5 || (flick && Math.abs(drag) > 0.06)) {
        const dir = drag !== 0 ? Math.sign(drag) : (e.deltaX > 0 ? 1 : -1);
        committed = true;
        committedTarget = Math.max(0, Math.min(last, startWeek + dir));
        tweenWeek(committedTarget, 260);
      }
    };
    el.addEventListener("wheel", onWheel, { passive: false });
    return () => { el.removeEventListener("wheel", onWheel); clearTimeout(idleTimer); };
  }, [tweenWeek]);

  // Esc → zoom out to year.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") tweenTo(0); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [tweenTo]);

  const onMove = useCallback((e: React.MouseEvent) => {
    const el = wrapRef.current!;
    const rect = el.getBoundingClientRect();
    const px = e.clientX - rect.left, py = e.clientY - rect.top;
    const cur = zRef.current;
    if (cur < 0.5) {
      setHoverMonth(monthNameAtPoint(px, py, { w: el.clientWidth, h: el.clientHeight }, scrollYRef.current));
      if (hoverWeekRef.current != null) setHoverWeek(null);
    } else if (cur < 1.5) {
      setHoverWeek(weekAtPointInMonth(px, focusRef.current, { w: el.clientWidth, h: el.clientHeight }));
      if (hoverMonthRef.current != null) setHoverMonth(null);
    } else if (hoverMonthRef.current != null || hoverWeekRef.current != null) {
      setHoverMonth(null); setHoverWeek(null);
    }
  }, []);

  const onClick = useCallback((e: React.MouseEvent) => {
    const el = wrapRef.current!;
    const cur = zRef.current;
    if (cur < 0.5 && hoverMonthRef.current != null) {
      setFocus(hoverMonthRef.current);
      tweenTo(1);
    } else if (cur < 1.5 && hoverWeekRef.current != null) {
      setWeek(hoverWeekRef.current);
      tweenTo(2);
    } else if (cur >= 1.5) {
      const rect = el.getBoundingClientRect();
      const hit = dayAtPointInWeek(e.clientX - rect.left, focusRef.current, Math.round(weekRef.current), { w: el.clientWidth, h: el.clientHeight });
      if (hit && hit.month !== focusRef.current) chainTo(hit.month, hit.week);
    }
  }, [tweenTo, chainTo]);

  const clearHover = useCallback(() => { setHoverMonth(null); setHoverWeek(null); }, []);

  return { wrapRef, vp, z, focus, week, scrollY, hoverMonth, hoverWeek, tweenTo, onMove, onClick, clearHover };
}
