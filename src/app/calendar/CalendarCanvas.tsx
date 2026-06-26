"use client";

import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import {
  buildScene, easeInOut, Vp, Item,
  monthAtPoint, weekAtPointInMonth, monthOutlineRect, weekOutlineRect,
} from "./scene";
import { MONTH_LONG } from "./labels";

function hexToRgba(hex: string, a: number): string {
  const n = parseInt(hex.slice(1), 16);
  return `rgba(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}, ${a})`;
}

const LEVELS = ["Year", "Month", "Week"];

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
  const hoverMonthRef = useRef(hoverMonth); hoverMonthRef.current = hoverMonth;
  const hoverWeekRef = useRef(hoverWeek); hoverWeekRef.current = hoverWeek;
  const tweenRef = useRef<number | null>(null);
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

  const tweenTo = useCallback((targetZ: number, dur = 520) => {
    cancelTween(); clearSnap();
    const startZ = zRef.current;
    let t0 = 0;
    const step = (ts: number) => {
      if (!t0) t0 = ts;
      const p = Math.min(1, (ts - t0) / dur);
      setZ(startZ + (targetZ - startZ) * easeInOut(p));
      tweenRef.current = p < 1 ? requestAnimationFrame(step) : null;
    };
    tweenRef.current = requestAnimationFrame(step);
  }, []);

  const scheduleSnap = useCallback(() => {
    clearSnap();
    snapRef.current = window.setTimeout(() => {
      const target = Math.max(0, Math.min(2, Math.round(zRef.current)));
      if (Math.abs(target - zRef.current) > 0.004) tweenTo(target, 240);
    }, 150);
  }, [tweenTo]);

  // wheel → continuous zoom; pick month in year phase, week in month phase
  useEffect(() => {
    const el = wrapRef.current;
    if (!el) return;
    const onWheel = (e: WheelEvent) => {
      // Only hijack the trackpad PINCH gesture (delivered as a ctrlKey wheel event);
      // leave plain scrolling alone.
      if (!e.ctrlKey) return;
      e.preventDefault();
      cancelTween();
      const cur = zRef.current;
      const rect = el.getBoundingClientRect();
      const px = e.clientX - rect.left, py = e.clientY - rect.top;
      const vpNow = { w: el.clientWidth, h: el.clientHeight };
      if (cur < 0.5) {
        const m = monthAtPoint(px, py, vpNow);
        if (m != null) setFocus(m);
      } else if (cur < 1.5) {
        const w = weekAtPointInMonth(px, focusRef.current, vpNow);
        if (w != null) setWeek(w);
      }
      setZ(Math.max(0, Math.min(2, cur - e.deltaY * 0.01)));
      scheduleSnap();
    };
    el.addEventListener("wheel", onWheel, { passive: false });
    return () => el.removeEventListener("wheel", onWheel);
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

  const onClick = () => {
    const z = zRef.current;
    if (z < 0.5 && hoverMonthRef.current != null) {
      setFocus(hoverMonthRef.current);
      tweenTo(1);
    } else if (z < 1.5 && hoverWeekRef.current != null) {
      setWeek(hoverWeekRef.current);
      tweenTo(2);
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
        <span className="cc-level">{LEVELS[level]}</span>
        {z >= 0.5 && <span className="cc-focus">{MONTH_LONG[focus]} 2026{level === 2 ? ` · week ${week + 1}` : ""}</span>}
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
