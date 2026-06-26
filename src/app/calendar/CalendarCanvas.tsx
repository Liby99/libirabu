"use client";

import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import {
  buildScene, easeInOut, Vp, Item, weeksInMonth,
  monthAtPoint, weekAtPointInMonth, dayAtPointInWeek, monthOutlineRect, weekOutlineRect,
} from "./scene";
import { MONTH_LONG } from "./labels";

function hexToRgba(hex: string, a: number): string {
  const n = parseInt(hex.slice(1), 16);
  return `rgba(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}, ${a})`;
}

export default function CalendarCanvas() {
  const wrapRef = useRef<HTMLDivElement>(null);
  const [vp, setVp] = useState<Vp>({ w: 0, h: 0 });
  const [z, setZ] = useState(0);
  const [focus, setFocus] = useState(new Date().getMonth());
  const [week, setWeek] = useState(0);
  const [hoverMonth, setHoverMonth] = useState<number | null>(null);
  const [hoverWeek, setHoverWeek] = useState<number | null>(null);

  const zRef = useRef(z); zRef.current = z;
  const focusRef = useRef(focus); focusRef.current = focus;
  const weekRef = useRef(week); weekRef.current = week;
  const hoverMonthRef = useRef(hoverMonth); hoverMonthRef.current = hoverMonth;
  const hoverWeekRef = useRef(hoverWeek); hoverWeekRef.current = hoverWeek;
  const tweenRef = useRef<number | null>(null);
  const weekTweenRef = useRef<number | null>(null);
  const snapRef = useRef<number | null>(null);
  const lastWheelTs = useRef(0);

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
  const scheduleSnap = useCallback(() => {
    clearSnap();
    const IDLE = 220;
    const tick = () => {
      const since = performance.now() - lastWheelTs.current;
      if (since < IDLE) { snapRef.current = window.setTimeout(tick, IDLE - since + 5); return; }
      snapRef.current = null;
      const target = Math.max(0, Math.min(2, Math.round(zRef.current)));
      if (Math.abs(target - zRef.current) > 0.004) tweenTo(target, 260);
      // at week level, also snap the horizontal week position to the nearest week
      if (Math.round(zRef.current) === 2) {
        const lastWeek = weeksInMonth(focusRef.current) - 1;
        const wt = Math.max(0, Math.min(lastWeek, Math.round(weekRef.current)));
        if (Math.abs(wt - weekRef.current) > 0.004) tweenWeek(wt, 260);
      }
    };
    snapRef.current = window.setTimeout(tick, IDLE);
  }, [tweenTo, tweenWeek]);

  // wheel → continuous zoom; pick month in year phase, week in month phase
  useEffect(() => {
    const el = wrapRef.current;
    if (!el) return;
    let pending: number | null = null, raf = 0; // coalesce z updates → one/frame
    let pendingW: number | null = null, rafW = 0; // coalesce week updates → one/frame
    const flush = () => { raf = 0; if (pending != null) { setZ(pending); pending = null; } };
    const flushW = () => { rafW = 0; if (pendingW != null) { setWeek(pendingW); pendingW = null; } };
    const onWheel = (e: WheelEvent) => {
      // Trackpad PINCH (ctrlKey wheel) → zoom.
      if (e.ctrlKey) {
        e.preventDefault();
        cancelTween(); cancelWeekTween();
        lastWheelTs.current = performance.now();
        const cur = pending != null ? pending : zRef.current;
        const rect = el.getBoundingClientRect();
        const px = e.clientX - rect.left, py = e.clientY - rect.top;
        const vpNow = { w: el.clientWidth, h: el.clientHeight };
        // Only (re)select focus/week when STARTING a zoom-in from a settled level.
        const zoomingIn = e.deltaY < 0;
        if (zoomingIn && cur < 0.15) {
          const m = monthAtPoint(px, py, vpNow);
          if (m != null) setFocus(m);
        } else if (zoomingIn && cur >= 0.85 && cur < 1.15) {
          const w = weekAtPointInMonth(px, focusRef.current, vpNow);
          if (w != null) setWeek(w);
        }
        pending = Math.max(0, Math.min(2, cur - e.deltaY * 0.01));
        if (!raf) raf = requestAnimationFrame(flush);
        scheduleSnap();
        return;
      }
      // In week view, horizontal scroll pages between weeks (clamped to the month).
      if (zRef.current >= 1.5 && Math.abs(e.deltaX) > Math.abs(e.deltaY)) {
        e.preventDefault();
        cancelWeekTween();
        lastWheelTs.current = performance.now();
        const lastWeek = weeksInMonth(focusRef.current) - 1;
        const curW = pendingW != null ? pendingW : weekRef.current;
        pendingW = Math.max(0, Math.min(lastWeek, curW + e.deltaX / el.clientWidth));
        if (!rafW) rafW = requestAnimationFrame(flushW);
        scheduleSnap();
      }
      // (plain vertical scroll is left alone)
    };
    el.addEventListener("wheel", onWheel, { passive: false });
    return () => { el.removeEventListener("wheel", onWheel); if (raf) cancelAnimationFrame(raf); if (rafW) cancelAnimationFrame(rafW); };
  }, [scheduleSnap]);

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
      setHoverMonth(monthAtPoint(px, py, vp));
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

  const scene = buildScene(z, focus, week, vp);
  const level = z < 0.5 ? 0 : z < 1.5 ? 1 : 2;

  let outline: { x: number; y: number; w: number; h: number } | null = null;
  if (z < 0.5 && hoverMonth != null) outline = monthOutlineRect(hoverMonth, vp);
  else if (z >= 0.6 && z <= 1.4 && hoverWeek != null) outline = weekOutlineRect(focus, hoverWeek, vp);

  const hint =
    level === 0 ? (hoverMonth != null ? "click to open month · or pinch to zoom" : "pinch to zoom in")
    : level === 1 ? (hoverWeek != null ? "click to open week · or pinch to zoom" : "hover a week · pinch to zoom")
    : "pinch to zoom out · esc to reset";

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

      <div className="cc-layer">
        {scene.items.map((it) => <ItemView key={it.key} it={it} />)}
      </div>

      {outline && (
        <svg className="cc-svg" width={vp.w} height={vp.h}>
          <rect x={outline.x} y={outline.y} width={outline.w} height={outline.h} rx={4} className="cc-outline" />
        </svg>
      )}
    </div>
  );
}

function ItemView({ it }: { it: Item }) {
  const base: React.CSSProperties = {
    position: "absolute",
    transform: `translate3d(${it.x}px, ${it.y}px, 0)`,
    width: it.w,
    height: it.h,
    opacity: it.opacity,
  };

  if (it.kind === "row") {
    const dayW = it.cols ? it.w / it.cols : it.w;
    return (
      <div
        style={{
          ...base,
          background: hexToRgba(it.color!, 0.1),
          backgroundImage: `repeating-linear-gradient(to right, ${hexToRgba("#4c2d14", 0.12)} 0 1px, transparent 1px ${dayW}px)`,
          borderTop: `1px solid ${hexToRgba("#4c2d14", 0.12)}`,
        }}
      />
    );
  }

  if (it.kind === "gridline") {
    return <div style={{ ...base, background: it.color }} />;
  }

  if (it.kind === "event") {
    return (
      <div className="cc-event" style={{ ...base, background: it.color }}>
        {it.text && <span style={{ fontSize: it.fontSize }}>{it.text}</span>}
      </div>
    );
  }

  return (
    <div
      style={{
        ...base,
        fontSize: it.fontSize,
        display: "flex",
        alignItems: "center",
        justifyContent: it.align === "center" ? "center" : "flex-start",
        color: it.kind === "monthLabel" ? "var(--accent-dark)" : "var(--accent-grey)",
        fontWeight: it.kind === "monthLabel" ? 600 : 400,
        pointerEvents: "none",
        textTransform: it.kind === "monthLabel" ? "uppercase" : "none",
        letterSpacing: it.kind === "monthLabel" ? "0.05em" : 0,
      }}
    >
      {it.text}
    </div>
  );
}
