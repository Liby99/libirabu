"use client";

import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { buildScene, weekAtPoint, easeInOut, Vp, Item } from "./scene";
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
  const [hover, setHover] = useState<{ month: number; week: number } | null>(null);

  const zRef = useRef(z);
  zRef.current = z;
  const hoverRef = useRef(hover);
  hoverRef.current = hover;
  const tweenRef = useRef<number | null>(null);

  // measure
  useLayoutEffect(() => {
    const el = wrapRef.current;
    if (!el) return;
    const ro = new ResizeObserver(() => {
      setVp({ w: el.clientWidth, h: el.clientHeight });
    });
    ro.observe(el);
    setVp({ w: el.clientWidth, h: el.clientHeight });
    return () => ro.disconnect();
  }, []);

  const cancelTween = () => {
    if (tweenRef.current != null) cancelAnimationFrame(tweenRef.current);
    tweenRef.current = null;
  };

  const tweenTo = useCallback((targetZ: number, dur = 600) => {
    cancelTween();
    const startZ = zRef.current;
    let t0 = 0;
    const step = (ts: number) => {
      if (!t0) t0 = ts;
      const p = Math.min(1, (ts - t0) / dur);
      setZ(startZ + (targetZ - startZ) * easeInOut(p));
      if (p < 1) tweenRef.current = requestAnimationFrame(step);
      else tweenRef.current = null;
    };
    tweenRef.current = requestAnimationFrame(step);
  }, []);

  // wheel → continuous zoom
  useEffect(() => {
    const el = wrapRef.current;
    if (!el) return;
    const onWheel = (e: WheelEvent) => {
      e.preventDefault();
      cancelTween();
      const cur = zRef.current;
      // entering from year: lock focus to whatever is under the cursor
      if (cur < 0.25 && e.deltaY < 0) {
        const rect = el.getBoundingClientRect();
        const w = weekAtPoint(e.clientX - rect.left, e.clientY - rect.top, { w: el.clientWidth, h: el.clientHeight });
        if (w) { setFocus(w.month); setWeek(w.week); }
      }
      const next = Math.max(0, Math.min(2, cur - e.deltaY * 0.0022));
      setZ(next);
    };
    el.addEventListener("wheel", onWheel, { passive: false });
    return () => el.removeEventListener("wheel", onWheel);
  }, []);

  // keyboard
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") tweenTo(0);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [tweenTo]);

  const onMove = (e: React.MouseEvent) => {
    if (zRef.current >= 0.3) { if (hoverRef.current) setHover(null); return; }
    const el = wrapRef.current!;
    const rect = el.getBoundingClientRect();
    const w = weekAtPoint(e.clientX - rect.left, e.clientY - rect.top, { w: el.clientWidth, h: el.clientHeight });
    setHover(w);
  };

  const onClick = () => {
    if (zRef.current < 0.3 && hoverRef.current) {
      setFocus(hoverRef.current.month);
      setWeek(hoverRef.current.week);
      tweenTo(2);
    }
  };

  if (vp.w === 0) return <div ref={wrapRef} className="cc-wrap" />;

  const scene = buildScene(z, focus, week, vp, hover);
  const level = z < 0.5 ? 0 : z < 1.5 ? 1 : 2;

  return (
    <div ref={wrapRef} className="cc-wrap" onMouseMove={onMove} onMouseLeave={() => setHover(null)} onClick={onClick}>
      {/* breadcrumb / status */}
      <div className="cc-bar">
        <span className="cc-level">{LEVELS[level]}</span>
        {z >= 0.5 && <span className="cc-focus">{MONTH_LONG[focus]} {2026}{level === 2 ? ` · week ${week + 1}` : ""}</span>}
        <span className="cc-hint">scroll to zoom · {hover && z < 0.25 ? "click to open week" : "esc to reset"}</span>
      </div>

      {/* HTML item layer */}
      <div className="cc-layer">
        {scene.items.map((it) => <ItemView key={it.key} it={it} />)}
      </div>

      {/* SVG overlay (hover outline) */}
      {scene.outline && (
        <svg className="cc-svg" width={vp.w} height={vp.h}>
          <rect
            x={scene.outline.x} y={scene.outline.y} width={scene.outline.w} height={scene.outline.h}
            rx={4} className="cc-outline"
          />
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

  if (it.kind === "event") {
    return (
      <div className="cc-event" style={{ ...base, background: it.color }}>
        {it.text && <span style={{ fontSize: it.fontSize }}>{it.text}</span>}
      </div>
    );
  }

  // text labels
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
