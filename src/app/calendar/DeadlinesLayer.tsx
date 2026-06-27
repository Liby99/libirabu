"use client";

import { useRef, useState } from "react";
import { Plus, RotateCw } from "lucide-react";
import { Vp, Hover } from "./types";
import { LABEL_W } from "./constants";
import { frameFor } from "./frames";
import { hourMetrics } from "./eventGeom";
import { daysInMonth } from "./mock";
import { weekStartDOM } from "./dates";
import { Deadline } from "./deadlineTypes";
import { deadlineTimeLabel } from "./deadlineFormat";
import { occurrenceDates, occKey, occDate } from "./occurrences";

interface Props {
  vp: Vp;
  z: number;
  focus: number;
  week: number;
  scrollY: number;
  tlScroll: number;
  year: number;
  mainTz: string;
  hover: Hover;
  deadlines: Deadline[];
  addDeadline: (d: Omit<Deadline, "id">) => Deadline;
  updateDeadline: (id: string, patch: Partial<Deadline>) => void;
  selectedId: string | null;
  onSelect: (id: string | null, occ?: string | null) => void;
  onOpenDetail: (id: string, occ?: string | null) => void;
  onContextMenu: (id: string, x: number, y: number, occ?: string | null) => void;
}

export default function DeadlinesLayer({ vp, z, focus, week, scrollY, tlScroll, year, mainTz, hover, deadlines, addDeadline, updateDeadline, selectedId, onSelect, onOpenDetail, onContextMenu }: Props) {
  const layerRef = useRef<HTMLDivElement>(null);
  const movedRef = useRef(false); // a real drag happened → suppress the trailing click
  const [movingId, setMovingId] = useState<string | null>(null);

  const f = frameFor(focus, z, focus, week, vp, scrollY);
  const colW = f.dayW;
  const tlTop = f.bandY + 4 * f.trackH + 18;
  const tlBottom = vp.h - 8;
  const { hourH, scroll } = hourMetrics(tlTop, tlBottom, z, tlScroll);
  const revealed = z >= 0.82 && hourH > 0; // timeline visible (month detail + week)
  const weekly = z >= 1.5;

  const yOf = (hour: number) => tlTop + hour * hourH - scroll;
  const xOf = (day: number) => f.x0 + (day - 1) * colW;

  // ── Drag the label → move the deadline (day + integer hour, minutes preserved) ──
  const onMoveStart = (id: string, e: React.MouseEvent) => {
    if (e.button !== 0) return;
    e.stopPropagation();
    const dl = deadlines.find((x) => x.id === id);
    if (!dl) return;
    const dim = daysInMonth(focus);
    const wStart = weekly ? weekStartDOM(focus, Math.round(week)) : 1;
    const lo = weekly ? Math.max(1, wStart) : 1;
    const hi = weekly ? Math.min(dim, wStart + 6) : dim;
    movedRef.current = false;
    const onMove = (me: MouseEvent) => {
      if (Math.abs(me.clientX - e.clientX) > 3 || Math.abs(me.clientY - e.clientY) > 3) movedRef.current = true;
      if (!movedRef.current) return;
      setMovingId(id);
      const r = layerRef.current!.getBoundingClientRect();
      const px = me.clientX - r.left, py = me.clientY - r.top;
      const day = Math.min(hi, Math.max(lo, Math.floor((px - f.x0) / colW) + 1));
      const rawHour = (py - tlTop + scroll) / hourH;
      const hour = Math.min(23.75, Math.max(0, Math.round(rawHour * 4) / 4)); // 15-minute snap
      updateDeadline(id, { day, hour });
    };
    const onUp = () => {
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
      setMovingId(null);
      setTimeout(() => { movedRef.current = false; }, 0);
    };
    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
  };

  // The + quick-create affordance: only when the cursor is near the hovered day column's
  // left edge (hover.nearLeft), snapped to the nearest hour line (week view only).
  let plus: { day: number; hour: number; x: number; y: number } | null = null;
  if (revealed && weekly && hover && hover.nearLeft && hover.dom != null && hover.hourFrac != null) {
    const hour = Math.min(23, Math.max(0, Math.round(hover.hourFrac)));
    const x = xOf(hover.dom);
    const y = yOf(hour);
    // don't offer to create where a deadline already sits (same day + hour-line)
    const occupied = deadlines.some((d) => d.year === year && d.month === focus && d.day === hover.dom && Math.abs(d.hour - hour) < 1e-6);
    if (!occupied && y >= tlTop && y <= tlBottom && x >= LABEL_W - 1 && x <= vp.w) plus = { day: hover.dom, hour, x, y };
  }

  // Recurrence: read-only ghost copies of repeating deadlines on their occurrence days.
  const ghosts = revealed
    ? deadlines.filter((d) => d.repeat && d.repeat.kind !== "none")
        .flatMap((d) => occurrenceDates({ year: d.year, month: d.month, day: d.day }, d.repeat, year)
          .filter((o) => o.month === focus && o.year === year)
          .map((o) => ({ d, o, x: xOf(o.day), y: yOf(d.hour) }))
          .filter((g) => g.y >= tlTop && g.y <= tlBottom && g.x + colW >= LABEL_W && g.x <= vp.w))
    : [];

  return (
    <>
      <div className="cc-deadlines" ref={layerRef}>
        {ghosts.map(({ d, o, x, y }) => {
          const labelLeft = x - 8 - 120 > LABEL_W;
          return (
            <div key={occKey(d.id, o)} className={`cc-ddl cc-ev-${d.color} cc-ghost`}>
              <div data-ev-line-id={d.id} data-occ={occDate(o)} className="cc-ddl-line" style={{ transform: `translate(${x}px, ${y - 1}px)`, width: colW }} />
              <div
                data-ev-id={d.id}
                data-occ={occDate(o)}
                className={`cc-ddl-label ${labelLeft ? "cc-ddl-label-l" : "cc-ddl-label-r"}`}
                style={{ transform: `translate(${labelLeft ? x - 8 : x + colW + 8}px, ${y}px) translateY(calc(-50% + 1px))${labelLeft ? " translateX(-100%)" : ""}` }}
                onClick={(e) => { e.stopPropagation(); onSelect(d.id, occDate(o)); }}
                onDoubleClick={(e) => { e.stopPropagation(); onOpenDetail(d.id, occDate(o)); }}
                onContextMenu={(e) => { e.preventDefault(); e.stopPropagation(); const r = e.currentTarget.getBoundingClientRect(); onContextMenu(d.id, r.left + r.width / 2, r.top, occDate(o)); }}
              >
                <span className="cc-ddl-title">{d.title}</span>
                <span className="cc-ddl-time">{deadlineTimeLabel(d, mainTz)}</span>
                <RotateCw className="cc-rec-badge" size={9} strokeWidth={2.5} aria-hidden />
              </div>
            </div>
          );
        })}
        {revealed && deadlines.filter((d) => d.month === focus && d.year === year).map((d) => {
          const x = xOf(d.day);
          const y = yOf(d.hour);
          if (y < tlTop - 1 || y > tlBottom + 1) return null;
          if (x + colW < LABEL_W || x > vp.w) return null;
          const selected = d.id === selectedId;
          // label sits to the LEFT of the line; flip right only when there's no room before the gutter
          const labelLeft = x - 8 - 120 > LABEL_W;
          return (
            <div key={d.id} className={`cc-ddl cc-ev-${d.color}${selected ? " selected" : ""}${d.id === movingId ? " moving" : ""}`}>
              <div data-ev-line-id={d.id} className="cc-ddl-line" style={{ transform: `translate(${x}px, ${y - 1}px)`, width: colW }} />
              <div
                data-ev-id={d.id}
                className={`cc-ddl-label ${labelLeft ? "cc-ddl-label-l" : "cc-ddl-label-r"}`}
                style={{ transform: `translate(${labelLeft ? x - 8 : x + colW + 8}px, ${y}px) translateY(calc(-50% + 1px))${labelLeft ? " translateX(-100%)" : ""}` }}
                onMouseDown={(e) => onMoveStart(d.id, e)}
                onClick={(e) => { e.stopPropagation(); if (movedRef.current) return; onSelect(d.id); }}
                onDoubleClick={(e) => { e.stopPropagation(); onOpenDetail(d.id); }}
                onContextMenu={(e) => {
                  e.preventDefault(); e.stopPropagation();
                  const r = e.currentTarget.getBoundingClientRect();
                  onContextMenu(d.id, r.left + r.width / 2, r.top);
                }}
              >
                <span className="cc-ddl-title">{d.title}</span>
                <span className="cc-ddl-time">{deadlineTimeLabel(d, mainTz)}</span>
              </div>
            </div>
          );
        })}
      </div>

      {/* rendered as a cc-layer sibling so its z-index can sit above the mouse cursor line */}
      {plus && (
        <button
          className="cc-ddl-add"
          style={{ transform: `translate(${plus.x}px, ${plus.y}px) translate(-50%, -50%)` }}
          title="Add deadline"
          onMouseDown={(e) => e.stopPropagation()}
          onClick={(e) => {
            e.stopPropagation();
            const created = addDeadline({ year, month: focus, day: plus!.day, hour: plus!.hour, title: "Deadline", color: "default", originTz: null });
            onSelect(created.id);
          }}
        >
          <Plus size={11} strokeWidth={2.5} aria-hidden />
        </button>
      )}
    </>
  );
}
