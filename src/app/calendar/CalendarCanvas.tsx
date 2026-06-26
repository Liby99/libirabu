"use client";

import { memo, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import {
  buildScene, easeInOut, Vp, Item, weeksInMonth, yearMaxScroll, yearMonthBandY,
  monthAtPoint, weekAtPointInMonth, dayAtPointInWeek,
  LABEL_W, MNAME_W, TRACK_H, TOP_PAD,
} from "./scene";

const RIGHT_PAD = 24; // gap between the track inputs and the grid lane
import { MONTH_LONG } from "./labels";

const TRACK_KEY = "libirabu-calendar-tracknames";
const DEFAULT_TRACK_NAMES = ["Teaching", "Research", "Service", "Travel"];

// Safari's GestureEvent isn't in the standard DOM lib types.
type GestureLikeEvent = { scale: number; clientX: number; clientY: number; preventDefault: () => void };

export default function CalendarCanvas() {
  const wrapRef = useRef<HTMLDivElement>(null);
  const [vp, setVp] = useState<Vp>({ w: 0, h: 0 });
  const [z, setZ] = useState(0);
  const [focus, setFocus] = useState(new Date().getMonth());
  const [week, setWeek] = useState(0);
  const [scrollY, setScrollY] = useState(0);
  const [hoverMonth, setHoverMonth] = useState<number | null>(null);
  const [hoverWeek, setHoverWeek] = useState<number | null>(null);
  // Per-month track names (year-view editor), persisted to localStorage.
  const [trackNames, setTrackNames] = useState<string[][]>(() =>
    Array.from({ length: 12 }, () => [...DEFAULT_TRACK_NAMES]));

  useEffect(() => {
    try {
      const s = localStorage.getItem(TRACK_KEY);
      if (s) setTrackNames(JSON.parse(s));
    } catch { /* ignore */ }
  }, []);

  const editTrack = useCallback((m: number, i: number, val: string) => {
    setTrackNames((prev) => {
      const next = prev.map((r) => r.slice());
      next[m][i] = val;
      try { localStorage.setItem(TRACK_KEY, JSON.stringify(next)); } catch { /* ignore */ }
      return next;
    });
  }, []);

  // Memoized track-name inputs — rebuilt only on layout/data change, NOT on zoom,
  // so an active pinch doesn't re-reconcile 48 inputs every frame (which delayed
  // gesturechange past the settle watchdog and snapped the zoom mid-flight).
  const trackInputs = useMemo(() => {
    if (vp.w === 0) return null;
    const left = MNAME_W + 2;
    const width = LABEL_W - MNAME_W - 2 - RIGHT_PAD;
    return Array.from({ length: 12 }, (_, m) => m).map((m) => {
      const by = yearMonthBandY(m, vp, scrollY);
      if (by + TRACK_H * 4 < 0 || by > vp.h) return null;
      return [0, 1, 2, 3].map((i) => (
        <div
          key={`tn-${m}-${i}`}
          className={`cc-track-cell${i === 0 ? " cc-tc-first" : ""}${i === 3 ? " cc-tc-last" : ""}`}
          style={{ top: by + i * TRACK_H, left, width, height: TRACK_H }}
        >
          <input
            className="cc-track-input"
            value={trackNames[m]?.[i] ?? ""}
            placeholder="track…"
            onChange={(e) => editTrack(m, i, e.target.value)}
            onClick={(e) => e.stopPropagation()}
            onMouseDown={(e) => e.stopPropagation()}
          />
        </div>
      ));
    });
  }, [vp, scrollY, trackNames, editTrack]);

  // Focused month's track names, pinned to the band at the top — shown in month/week
  // views (where only the focus month is visible), like frozen spreadsheet columns.
  const focusTrackInputs = useMemo(() => {
    const left = MNAME_W + 2;
    const width = LABEL_W - MNAME_W - 2 - RIGHT_PAD;
    return [0, 1, 2, 3].map((i) => (
      <div
        key={`ftn-${i}`}
        className={`cc-track-cell${i === 0 ? " cc-tc-first" : ""}${i === 3 ? " cc-tc-last" : ""}`}
        style={{ top: TOP_PAD + i * TRACK_H, left, width, height: TRACK_H }}
      >
        <input
          className="cc-track-input"
          value={trackNames[focus]?.[i] ?? ""}
          placeholder="track…"
          onChange={(e) => editTrack(focus, i, e.target.value)}
          onClick={(e) => e.stopPropagation()}
          onMouseDown={(e) => e.stopPropagation()}
        />
      </div>
    ));
  }, [focus, trackNames, editTrack]);

  const zRef = useRef(z); zRef.current = z;
  const focusRef = useRef(focus); focusRef.current = focus;
  const weekRef = useRef(week); weekRef.current = week;
  const scrollYRef = useRef(scrollY); scrollYRef.current = scrollY;
  const hoverMonthRef = useRef(hoverMonth); hoverMonthRef.current = hoverMonth;
  const hoverWeekRef = useRef(hoverWeek); hoverWeekRef.current = hoverWeek;
  const tweenRef = useRef<number | null>(null);
  const weekTweenRef = useRef<number | null>(null);
  const snapRef = useRef<number | null>(null);

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

  // Click a spillover day → zoom all the way out to year, briefly hold, then
  // zoom back into that week (slow enough to read the motion).
  const chainTo = useCallback((newMonth: number, newWeek: number) => {
    tweenTo(0, 800, () => {
      setFocus(newMonth);
      setWeek(newWeek);
      window.setTimeout(() => tweenTo(2, 1050), 200);
    });
  }, [tweenTo]);

  // Snap to the nearest level (0/1/2) only after the pinch has been idle for IDLE
  // ms. We re-check the real elapsed time and re-arm if a wheel event arrived
  // recently, so a slow gesture never gets yanked toward a level mid-pinch.
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

  // wheel → continuous zoom; pick month in year phase, week in month phase
  // Safari trackpad PINCH → zoom, via native gesture events. e.scale is cumulative
  // (1 at start). We snap ONLY on gestureend (finger lifted), so an in-progress
  // pinch — even held still — never fights a snap.
  useEffect(() => {
    const el = wrapRef.current;
    if (!el) return;
    let startZ = 0, cx = 0, cy = 0, idle = 0;
    // Fallback: if gesturechange stops arriving and no gestureend came (Safari
    // occasionally drops it), settle anyway so the zoom never sticks mid-transition.
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
      // Sensitivity: lower = slower. ~one comfortable pinch ≈ one zoom level.
      const nz = Math.max(0, Math.min(2, startZ + Math.log2(e.scale) * 0.6));
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

  // Two-finger horizontal scroll → page weeks, iPhone-homescreen style: the week
  // follows the fingers during the swipe and COMMITS immediately on a decisive
  // drag (past ~half) or a flick — snapping back if it was only a nudge. There's no
  // pan "lift" event, so after a commit we absorb the remaining momentum events.
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
      // Year view: vertical two-finger scroll scrolls the (tall) year.
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
        // Momentum only decays; a sudden rising delta = a fresh swipe → page again now.
        if (ax > lastAbs * 1.4 + 5) {
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

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") tweenTo(0); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [tweenTo]);

  const onMove = (e: React.MouseEvent) => {
    const el = wrapRef.current!;
    const rect = el.getBoundingClientRect();
    const px = e.clientX - rect.left, py = e.clientY - rect.top;
    const z = zRef.current;
    if (z < 0.5) {
      setHoverMonth(monthAtPoint(px, py, vp, scrollYRef.current));
      if (hoverWeekRef.current != null) setHoverWeek(null);
    } else if (z < 1.5) {
      setHoverWeek(weekAtPointInMonth(px, focusRef.current, vp));
      if (hoverMonthRef.current != null) setHoverMonth(null);
    } else if (hoverMonthRef.current != null || hoverWeekRef.current != null) {
      setHoverMonth(null); setHoverWeek(null);
    }
  };

  const onClick = (e: React.MouseEvent) => {
    const z = zRef.current;
    if (z < 0.5 && hoverMonthRef.current != null) {
      setFocus(hoverMonthRef.current);
      tweenTo(1);
    } else if (z < 1.5 && hoverWeekRef.current != null) {
      setWeek(hoverWeekRef.current);
      tweenTo(2);
    } else if (z >= 1.5) {
      const el = wrapRef.current!;
      const rect = el.getBoundingClientRect();
      const hit = dayAtPointInWeek(e.clientX - rect.left, focusRef.current, Math.round(weekRef.current), vp);
      if (hit && hit.month !== focusRef.current) chainTo(hit.month, hit.week);
    }
  };

  if (vp.w === 0) return <div ref={wrapRef} className="cc-wrap" />;

  const scene = buildScene(z, focus, week, vp, scrollY);
  const level = z < 0.5 ? 0 : z < 1.5 ? 1 : 2;

  const hint =
    level === 0 ? (hoverMonth != null ? "click to open month · or pinch to zoom" : "pinch to zoom in")
    : level === 1 ? (hoverWeek != null ? "click to open week · or pinch to zoom" : "hover a week · pinch to zoom")
    : "scroll sideways to change week · pinch to zoom out";

  return (
    <div ref={wrapRef} className="cc-wrap" onMouseMove={onMove} onMouseLeave={() => { setHoverMonth(null); setHoverWeek(null); }} onClick={onClick}>
      <div className="cc-bar">
        <nav className="cc-crumbs" onClick={(e) => e.stopPropagation()}>
          <button className={`cc-crumb${level === 0 ? " current" : ""}`} onClick={() => tweenTo(0)}>Year 2026</button>
          {level >= 1 && (
            <>
              <span className="cc-sep">›</span>
              <button className={`cc-crumb${level === 1 ? " current" : ""}`} onClick={() => tweenTo(1)}>{MONTH_LONG[focus]}</button>
            </>
          )}
          {level >= 2 && (
            <>
              <span className="cc-sep">›</span>
              <button className="cc-crumb current" onClick={() => tweenTo(2)}>Week {Math.round(week) + 1}</button>
            </>
          )}
        </nav>
        <span className="cc-hint">{hint}</span>
      </div>

      {/* solid left gutter — occludes lane content that slides under it (week view) */}
      <div className="cc-gutter" style={{ width: LABEL_W }} />

      <div className="cc-layer">
        {scene.items.map((it) => <ItemView key={it.key} it={it} />)}

        {/* per-month track-name editor — year view (gated by style, not remount) */}
        <div
          className="cc-track-edit"
          style={{
            opacity: Math.max(0, 1 - z / 0.3),
            pointerEvents: z < 0.12 ? "auto" : "none",
            visibility: z < 0.35 ? "visible" : "hidden",
          }}
        >
          {trackInputs}
        </div>
        {/* focused month's track names, pinned at the band — month/week views */}
        <div
          className="cc-track-edit"
          style={{
            opacity: Math.max(0, Math.min(1, (z - 0.85) / 0.15)),
            pointerEvents: z > 0.9 ? "auto" : "none",
            visibility: z > 0.85 ? "visible" : "hidden",
          }}
        >
          {focusTrackInputs}
        </div>
      </div>
    </div>
  );
}

// Renders one calendar primitive. Structural styling lives in CSS classes
// (calendar.css); only per-item geometry, opacity, and dynamic colors (as CSS
// custom properties) are inline — so each element is inspectable. 2D translate
// (not translate3d) avoids forcing a GPU layer per element.
const ItemView = memo(function ItemView({ it }: { it: Item }) {
  const style = {
    transform: `translate(${it.x}px, ${it.y}px)`,
    width: it.w,
    height: it.h,
    opacity: it.opacity,
    zIndex: it.z,
  } as React.CSSProperties;

  if (it.kind === "row") {
    return <div className="cc-item cc-row" style={{ ...style, ["--dayw"]: `${it.cols ? it.w / it.cols : it.w}px` } as React.CSSProperties} />;
  }

  if (it.kind === "gridline") {
    const dash = it.dashed ? (it.h >= it.w ? " cc-dash-v" : " cc-dash-h") : "";
    return <div className={`cc-item cc-gridline${dash}`} style={style} />;
  }

  if (it.kind === "event") {
    return (
      <div className={`cc-item cc-event cc-ev-${it.color}`} style={style}>
        {it.text && <span style={{ fontSize: it.fontSize }}>{it.text}</span>}
      </div>
    );
  }

  const cls = it.kind === "monthLabel" ? "cc-monthlabel" : `cc-daylabel ${it.align === "center" ? "cc-center" : "cc-left"}`;
  return <div className={`cc-item ${cls}`} style={{ ...style, fontSize: it.fontSize } as React.CSSProperties}>{it.text}</div>;
}, (p, n) => {
  // Skip re-render when this item's values are unchanged (e.g. a render triggered
  // only by editing a track name shouldn't re-render every calendar item).
  const a = p.it, b = n.it;
  return a.x === b.x && a.y === b.y && a.w === b.w && a.h === b.h && a.opacity === b.opacity &&
    a.z === b.z && a.color === b.color && a.text === b.text && a.fontSize === b.fontSize &&
    a.dashed === b.dashed && a.cols === b.cols && a.align === b.align && a.kind === b.kind;
});
