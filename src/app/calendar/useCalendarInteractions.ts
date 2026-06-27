import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { Vp, Hover } from "./types";
import { easeInOut, TOP_PAD, TRACK_H } from "./constants";
import { yearMaxScroll } from "./frames";
import { hourMetrics, clampHourH, setWeekHourH as syncWeekHourH } from "./eventGeom";
import { weeksInMonth } from "./dates";
import {
  monthAtPoint, monthNameAtPoint, monthRowAtPoint, weekAtPointInMonth, dayAtPointInWeek,
  domInMonthBand, domInFocus, cellInWeek,
} from "./hittest";

const NO_HOVER: Hover = { month: null, dom: null, week: null, hour: null, hourFrac: null, nameMonth: null, nearLeft: null };
const sameHover = (a: Hover, b: Hover) =>
  a.month === b.month && a.dom === b.dom && a.week === b.week && a.hour === b.hour &&
  a.hourFrac === b.hourFrac && a.nameMonth === b.nameMonth && a.nearLeft === b.nearLeft;

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
  const [tlScroll, setTlScroll] = useState(0); // week-view timeline vertical scroll
  const [weekHourH, setWeekHourHState] = useState(60); // week-view per-hour height (slider)
  syncWeekHourH(weekHourH); // keep the module value (read by hourMetrics) in sync
  const setWeekHourH = useCallback((h: number) => setWeekHourHState(clampHourH(h)), []);
  const [hoverMonth, setHoverMonth] = useState<number | null>(null);
  const [hoverWeek, setHoverWeek] = useState<number | null>(null);
  const [hover, setHover] = useState<Hover>(NO_HOVER);
  const [now, setNow] = useState(() => Date.now());
  const [year, setYearState] = useState(() => new Date().getFullYear());
  const currentYear = new Date().getFullYear();

  const zRef = useRef(z); zRef.current = z;
  const yearRef = useRef(year); yearRef.current = year;
  const focusRef = useRef(focus); focusRef.current = focus;
  const weekRef = useRef(week); weekRef.current = week;
  const scrollYRef = useRef(scrollY); scrollYRef.current = scrollY;
  const tlScrollRef = useRef(tlScroll); tlScrollRef.current = tlScroll;
  const hoverMonthRef = useRef(hoverMonth); hoverMonthRef.current = hoverMonth;
  const hoverWeekRef = useRef(hoverWeek); hoverWeekRef.current = hoverWeek;
  const hoverRef = useRef(hover); hoverRef.current = hover;
  const lastPtRef = useRef<{ x: number; y: number } | null>(null);
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

  // Navigate to a month (month view) — used by the drawer's "Go to first event".
  const goToMonth = useCallback((m: number) => { setFocus(m); tweenTo(1); }, [tweenTo]);

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
      // week view: vertical wheel scrolls the hourly timeline
      if (zRef.current >= 1.5 && Math.abs(e.deltaY) >= Math.abs(e.deltaX)) {
        const tlTop = TOP_PAD + 4 * TRACK_H + 18;
        const { maxScroll } = hourMetrics(tlTop, el.clientHeight - 8, zRef.current, tlScrollRef.current);
        if (maxScroll <= 0) return; // nothing to scroll (tall window)
        e.preventDefault();
        setTlScroll(Math.max(0, Math.min(maxScroll, tlScrollRef.current + e.deltaY)));
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

  // Tick once a minute so the current-time line advances while idle.
  useEffect(() => {
    const id = window.setInterval(() => setNow(Date.now()), 60_000);
    return () => window.clearInterval(id);
  }, []);

  // Esc → zoom out to year.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") tweenTo(0); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [tweenTo]);

  // Resolve the cursor → hover targets for the CURRENT zoom bucket. Drives both the
  // breadcrumb hint (hoverMonth/hoverWeek = click targets) and the hierarchical
  // highlight layers (hover). Called on mouse-move AND whenever the view changes
  // under a stationary cursor (scroll/zoom/focus/week) so highlights stay aligned.
  const recomputeHover = useCallback((px: number, py: number) => {
    const el = wrapRef.current;
    if (!el) return;
    const vpNow = { w: el.clientWidth, h: el.clientHeight };
    const sY = scrollYRef.current;
    const cur = zRef.current;
    let next: Hover;
    if (cur < 0.5) {
      const m = monthRowAtPoint(px, py, vpNow, sY); // includes the left gutter (name + track fields)
      const nm = monthNameAtPoint(px, py, vpNow, sY); // the clickable month-name strip
      next = { month: m, dom: m != null ? domInMonthBand(px, m, vpNow, sY) : null, week: null, hour: null, hourFrac: null, nameMonth: nm, nearLeft: null };
      setHoverMonth(nm);
      if (hoverWeekRef.current != null) setHoverWeek(null);
    } else if (cur < 1.5) {
      const wk = weekAtPointInMonth(px, focusRef.current, vpNow);
      next = { month: focusRef.current, dom: domInFocus(px, focusRef.current, vpNow), week: wk, hour: null, hourFrac: null, nameMonth: null, nearLeft: null };
      setHoverWeek(wk);
      if (hoverMonthRef.current != null) setHoverMonth(null);
    } else {
      const c = cellInWeek(px, py, zRef.current, focusRef.current, Math.round(weekRef.current), vpNow, sY, tlScrollRef.current);
      next = { month: focusRef.current, dom: c.dom, week: Math.round(weekRef.current), hour: c.hour, hourFrac: c.hourFrac, nameMonth: null, nearLeft: c.nearLeft };
      if (hoverMonthRef.current != null) setHoverMonth(null);
      if (hoverWeekRef.current != null) setHoverWeek(null);
    }
    if (!sameHover(hoverRef.current, next)) setHover(next);
  }, []);

  const onMove = useCallback((e: React.MouseEvent) => {
    const el = wrapRef.current!;
    const rect = el.getBoundingClientRect();
    const px = e.clientX - rect.left, py = e.clientY - rect.top;
    lastPtRef.current = { x: px, y: py };
    recomputeHover(px, py);
  }, [recomputeHover]);

  // Re-resolve hover when the scene shifts under a still cursor (year scroll, zoom
  // tween, week paging) so the highlight tracks the content it was over.
  useEffect(() => {
    const p = lastPtRef.current;
    if (p) recomputeHover(p.x, p.y);
  }, [z, scrollY, focus, week, tlScroll, recomputeHover]);

  const onClick = useCallback((e: React.MouseEvent) => {
    const el = wrapRef.current!;
    const cur = zRef.current;
    if (cur < 0.5) {
      // Open the month when clicking its name (gutter) OR anywhere in its day grid.
      const rect = el.getBoundingClientRect();
      const vpNow = { w: el.clientWidth, h: el.clientHeight };
      const m = hoverMonthRef.current ?? monthAtPoint(e.clientX - rect.left, e.clientY - rect.top, vpNow, scrollYRef.current);
      if (m != null) { setFocus(m); tweenTo(1); }
    } else if (cur < 1.5 && hoverWeekRef.current != null) {
      setWeek(hoverWeekRef.current);
      tweenTo(2);
    } else if (cur >= 1.5) {
      const rect = el.getBoundingClientRect();
      const hit = dayAtPointInWeek(e.clientX - rect.left, focusRef.current, Math.round(weekRef.current), { w: el.clientWidth, h: el.clientHeight });
      if (hit && hit.month !== focusRef.current) chainTo(hit.month, hit.week);
    }
  }, [tweenTo, chainTo]);

  const clearHover = useCallback(() => {
    lastPtRef.current = null;
    setHoverMonth(null); setHoverWeek(null); setHover(NO_HOVER);
  }, []);

  // Select a year (from the breadcrumb dropdown) — reset the year scroll to the top.
  const selectYear = useCallback((y: number) => { setYearState(y); setScrollY(0); }, []);

  // "Back to Current Year": load the current year and show its yearly view.
  const goToCurrentYear = useCallback(() => {
    setYearState(new Date().getFullYear());
    setScrollY(0);
    tweenTo(0);
  }, [tweenTo]);

  // "Current Week": animate to the current week, taking the shortest path from where
  // we are (scroll within a week / zoom in one or two levels / zoom out then in).
  const goToCurrentWeek = useCallback(() => {
    const d = new Date();
    const cy = d.getFullYear(), cm = d.getMonth(), cd = d.getDate();
    const cw = Math.floor((new Date(cy, cm, 1).getDay() + cd - 1) / 7); // current week index
    const sameYear = yearRef.current === cy;
    const lvl = Math.round(zRef.current);
    if (!sameYear) { setYearState(cy); setScrollY(0); }

    if (sameYear && lvl === 2 && focusRef.current === cm) {
      tweenWeek(cw);                       // weekly view, same month → scroll across
    } else if (sameYear && lvl === 1 && focusRef.current === cm) {
      setWeek(cw); tweenTo(2);             // monthly view, same month → zoom into the week
    } else if (lvl === 0) {
      setFocus(cm); setWeek(cw); tweenTo(2); // yearly view → zoom two levels in
    } else {
      // anything else → zoom out to yearly, then into the current week
      tweenTo(0, 600, () => {
        setFocus(cm); setWeek(cw);
        window.setTimeout(() => tweenTo(2, 1050), 180);
      });
    }
  }, [tweenTo, tweenWeek]);

  return { wrapRef, vp, z, focus, week, scrollY, tlScroll, setTlScroll, weekHourH, setWeekHourH, hoverMonth, hoverWeek, hover, now, year, currentYear, selectYear, goToCurrentYear, goToCurrentWeek, goToMonth, tweenTo, onMove, onClick, clearHover };
}
