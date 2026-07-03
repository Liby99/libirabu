"use client";

// Deadline layer: renders deadline moments as vertical lines + gutter labels.

import { useRef, useState } from "react";
import { Plus } from "lucide-react";
import EventBadges from "../events/EventBadges";
import { Vp, Hover } from "../../geometry/types";
import { LABEL_W, PAST_DIM } from "../../geometry/constants";
import { frameFor, dailyFade, type MonthAnim } from "../../geometry/frames";
import { hourMetrics, relDomOf, incomingDetailReveal } from "../../geometry/eventGeom";
import { daysInMonth } from "../../model/api/mock";
import { weekStartDOM, resolveDate, momentIsPast } from "../../util/dates";
import { Deadline } from "../../model/types/deadlineTypes";
import { deadlineTimeLabel } from "../../util/deadlineFormat";
import { occurrenceDates, occKey, occDate, baseHidden } from "../../model/occurrences";

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
  onSelect: (id: string | null, occ?: string | null, space?: "timed" | "allday") => void;
  onOpenDetail: (id: string, occ?: string | null) => void;
  onContextMenu: (id: string, x: number, y: number, occ?: string | null) => void;
  detailMul?: number; // timeline opacity multiplier during month↕month paging (outgoing month)
  dimPast?: boolean; // "dim past events" view toggle
  now?: number;      // ms timestamp → decides what's past
  onLabelHover?: (over: boolean) => void; // hovering a deadline label → suppress the week-view mouse cursor line
  monthAnim?: MonthAnim | null; // active page-turn → render the incoming month's deadlines too
}

export default function DeadlinesLayer({ vp, z, focus, week, scrollY, tlScroll, year, mainTz, hover, deadlines, addDeadline, updateDeadline, selectedId, onSelect, onOpenDetail, onContextMenu, detailMul = 1, dimPast = false, now = 0, onLabelHover, monthAnim = null }: Props) {
  // dim-past multiplier: 0.4 once a deadline's moment has elapsed, else 1
  const pdim = (oy: number, om: number, od: number, hour: number) => (dimPast && momentIsPast(oy, om, od, hour, now) ? PAST_DIM : 1);
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

  // Daily view: the label always sits to the LEFT of the line — its right edge just left of the
  // line's left circle (the standard daily placement). The line keeps its full length; the layer is
  // raised ABOVE the dashboard mask (container z-index below) so the right-end circle shows on top.
  const daily = z > 2.5;
  const lineW = colW;
  const labelMaxW = undefined;
  const labelCls = (left: boolean) => (daily || left ? "cc-ddl-label-l" : "cc-ddl-label-r");
  const labelTf = (x: number, y: number, left: boolean) => {
    const onLeft = daily || left; // daily forces left-of-line
    return `translate(${onLeft ? x - 8 : x + colW + 8}px, ${y}px) translateY(calc(-50% + 1px))${onLeft ? " translateX(-100%)" : ""}`;
  };

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
    // The label is grabbed at an offset from the deadline LINE (it sits left of, and vertically
    // centered on, the line). So we must NOT snap to the raw cursor — that would teleport the line to
    // the label's position. Instead record the line's CENTER at drag start and move it by the mouse
    // delta; at zero delta the line stays put no matter where on the label you grabbed.
    const rel0 = relDomOf(focus, dl.month, dl.day) ?? dl.day;
    const centerX0 = f.x0 + (rel0 - 1) * colW + lineW / 2; // line center x (layer coords)
    const centerY0 = yOf(dl.hour);                          // line y (layer coords)
    const startX = e.clientX, startY = e.clientY;
    movedRef.current = false;
    const onMove = (me: MouseEvent) => {
      if (Math.abs(me.clientX - startX) > 3 || Math.abs(me.clientY - startY) > 3) movedRef.current = true;
      if (!movedRef.current) return;
      setMovingId(id);
      const cx = centerX0 + (me.clientX - startX); // line center moved by the mouse delta
      const cy = centerY0 + (me.clientY - startY);
      const day = Math.min(hi, Math.max(lo, Math.floor((cx - f.x0) / colW) + 1));
      const rawHour = (cy - tlTop + scroll) / hourH;
      const hour = Math.min(23.75, Math.max(0, Math.round(rawHour * 4) / 4)); // 15-minute snap
      updateDeadline(id, { day, hour });
    };
    const onUp = () => {
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
      setMovingId(null);
      if (movedRef.current) {
        // A real drag ends with the cursor over the timeline (the label moved away from it), so the
        // trailing click would hit the canvas and navigate (e.g. into daily view in week view).
        // Swallow that one click in the capture phase so it never reaches the canvas handler.
        const swallow = (ce: MouseEvent) => ce.stopPropagation();
        window.addEventListener("click", swallow, true);
        setTimeout(() => window.removeEventListener("click", swallow, true), 0);
      }
      setTimeout(() => { movedRef.current = false; }, 0);
    };
    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
  };

  // The + quick-create affordance: only when the cursor is near the hovered day column's
  // left edge (hover.nearLeft), snapped to the nearest hour line (week view only).
  let plus: { month: number; day: number; hour: number; x: number; y: number } | null = null;
  if (revealed && weekly && hover && hover.nearLeft && hover.dom != null && hover.hourFrac != null) {
    // The hovered column can be a spillover day → resolve to its real month/day before create.
    const r = resolveDate(focus, hover.dom);
    if (r) {
      const hour = Math.min(23, Math.max(0, Math.round(hover.hourFrac)));
      const x = xOf(hover.dom);
      const y = yOf(hour);
      // don't offer to create where a deadline already sits (same day + hour-line)
      const occupied = deadlines.some((d) => d.year === year && d.month === r.month && d.day === r.day && Math.abs(d.hour - hour) < 1e-6);
      if (!occupied && y >= tlTop && y <= tlBottom && x >= LABEL_W - 1 && x <= vp.w) plus = { month: r.month, day: r.day, hour, x, y };
    }
  }

  // Recurrence: read-only ghost copies of repeating deadlines on their occurrence days.
  const ghosts = revealed
    ? deadlines.filter((d) => d.repeat && d.repeat.kind !== "none")
        .flatMap((d) => occurrenceDates({ year: d.year, month: d.month, day: d.day }, d.repeat, year)
          .filter((o) => o.year === year)
          .map((o) => ({ d, o, rel: relDomOf(focus, o.month, o.day) }))
          .filter((g) => g.rel != null && (g.o.month === focus || weekly))
          .map((g) => ({ d: g.d, o: g.o, x: xOf(g.rel as number), y: yOf(g.d.hour) }))
          .filter((g) => g.y >= tlTop && g.y <= tlBottom && g.x + colW >= LABEL_W && g.x <= vp.w))
    : [];

  // Page-turn: the INCOMING month's deadlines, read-only, cross-fading in at the (same) resting
  // position so they appear as the band approaches. `to`'s deadlines map by their own day number.
  const inTo = monthAnim ? focus + monthAnim.dir : -1;
  const inReveal = revealed && monthAnim && inTo >= 0 && inTo <= 11 ? incomingDetailReveal(monthAnim.p) : 0;
  const inItems = inReveal > 0.02
    ? [
        ...deadlines.filter((d) => d.repeat && d.repeat.kind !== "none")
          .flatMap((d) => occurrenceDates({ year: d.year, month: d.month, day: d.day }, d.repeat, year)
            .filter((o) => o.year === year && o.month === inTo)
            .map((o) => ({ d, occ: occDate(o), day: o.day, recurring: true }))),
        ...deadlines.filter((d) => d.year === year && d.month === inTo && !baseHidden(occDate({ year: d.year, month: d.month, day: d.day }), d.repeat))
          .map((d) => ({ d, occ: null as string | null, day: d.day, recurring: false })),
      ]
        .map((it) => ({ ...it, x: xOf(it.day), y: yOf(it.d.hour) }))
        .filter((it) => it.y >= tlTop && it.y <= tlBottom && it.x + colW >= LABEL_W && it.x <= vp.w)
    : [];

  return (
    <>
      <div className="cc-deadlines" ref={layerRef} style={{ ...(detailMul < 1 ? { opacity: detailMul } : {}), ...(daily ? { zIndex: 16 } : {}) }}>
        {ghosts.map(({ d, o, x, y }) => {
          const labelLeft = x - 8 - 120 > LABEL_W;
          return (
            <div key={occKey(d.id, o)} className={`cc-ddl cc-ev-${d.color} cc-ghost${d.id === selectedId ? " selected" : ""}`} style={{ opacity: dailyFade(relDomOf(focus, o.month, o.day) ?? -999, z) * pdim(o.year, o.month, o.day, d.hour) }}>
              <div data-ev-line-id={d.id} data-occ={occDate(o)} className="cc-ddl-line" style={{ transform: `translate(${x}px, ${y - 1}px)`, width: lineW }} />
              <div
                data-ev-id={d.id}
                data-occ={occDate(o)}
                className={`cc-ddl-label ${labelCls(labelLeft)}`}
                style={{ transform: labelTf(x, y, labelLeft), maxWidth: labelMaxW }}
                onMouseEnter={() => onLabelHover?.(true)}
                onMouseLeave={() => onLabelHover?.(false)}
                onClick={(e) => { e.stopPropagation(); onSelect(d.id, occDate(o), "timed"); }}
                onDoubleClick={(e) => { e.stopPropagation(); onOpenDetail(d.id, occDate(o)); }}
                onContextMenu={(e) => { e.preventDefault(); e.stopPropagation(); const r = e.currentTarget.getBoundingClientRect(); onContextMenu(d.id, r.left + r.width / 2, r.top, occDate(o)); }}
              >
                <span className="cc-ddl-title">{d.title}</span>
                <span className="cc-ddl-time">{deadlineTimeLabel(d, mainTz)}</span>
                <EventBadges ai={d.createdByAI} imported={d.imported} recurring />
              </div>
            </div>
          );
        })}
        {revealed && deadlines.filter((d) => d.year === year && !baseHidden(occDate({ year: d.year, month: d.month, day: d.day }), d.repeat)).map((d) => {
          // Map to a focus-relative column so deadlines on this week's spillover days (in the
          // previous/next month) render too — those columns only exist in week view.
          const rel = relDomOf(focus, d.month, d.day);
          if (rel == null || (d.month !== focus && !weekly)) return null;
          const x = xOf(rel);
          const y = yOf(d.hour);
          if (y < tlTop - 1 || y > tlBottom + 1) return null;
          if (x + colW < LABEL_W || x > vp.w) return null;
          const selected = d.id === selectedId;
          // label sits to the LEFT of the line; flip right only when there's no room before the gutter
          const labelLeft = x - 8 - 120 > LABEL_W;
          return (
            <div key={d.id} className={`cc-ddl cc-ev-${d.color}${selected ? " selected" : ""}${d.id === movingId ? " moving" : ""}${d.hidden ? " cc-hidden" : ""}`} style={{ opacity: dailyFade(rel, z) * pdim(d.year, d.month, d.day, d.hour) }}>
              <div data-ev-line-id={d.id} className="cc-ddl-line" style={{ transform: `translate(${x}px, ${y - 1}px)`, width: lineW }} />
              <div
                data-ev-id={d.id}
                className={`cc-ddl-label ${labelCls(labelLeft)}`}
                style={{ transform: labelTf(x, y, labelLeft), maxWidth: labelMaxW }}
                onMouseEnter={() => onLabelHover?.(true)}
                onMouseLeave={() => onLabelHover?.(false)}
                onMouseDown={(e) => onMoveStart(d.id, e)}
                onClick={(e) => { e.stopPropagation(); if (movedRef.current) return; onSelect(d.id, null, "timed"); }}
                onDoubleClick={(e) => { e.stopPropagation(); onOpenDetail(d.id); }}
                onContextMenu={(e) => {
                  e.preventDefault(); e.stopPropagation();
                  const r = e.currentTarget.getBoundingClientRect();
                  onContextMenu(d.id, r.left + r.width / 2, r.top);
                }}
              >
                <span className="cc-ddl-title">{d.title}</span>
                <span className="cc-ddl-time">{deadlineTimeLabel(d, mainTz)}</span>
                <EventBadges ai={d.createdByAI} imported={d.imported} />
              </div>
            </div>
          );
        })}
      </div>

      {inItems.length > 0 && (
        <div className="cc-deadlines" style={{ opacity: inReveal, pointerEvents: "none" }}>
          {inItems.map(({ d, occ, x, y, recurring }) => {
            const labelLeft = x - 8 - 120 > LABEL_W;
            return (
              <div key={occ ? occKey(d.id, { year, month: inTo, day: d.day }) : `in-${d.id}`} className={`cc-ddl cc-ev-${d.color}${recurring ? " cc-ghost" : ""}`}>
                <div className="cc-ddl-line" style={{ transform: `translate(${x}px, ${y - 1}px)`, width: colW }} />
                <div
                  className={`cc-ddl-label ${labelLeft ? "cc-ddl-label-l" : "cc-ddl-label-r"}`}
                  style={{ transform: `translate(${labelLeft ? x - 8 : x + colW + 8}px, ${y}px) translateY(calc(-50% + 1px))${labelLeft ? " translateX(-100%)" : ""}` }}
                >
                  <span className="cc-ddl-title">{d.title}</span>
                  <span className="cc-ddl-time">{deadlineTimeLabel(d, mainTz)}</span>
                  <EventBadges ai={d.createdByAI} imported={d.imported} recurring={recurring} />
                </div>
              </div>
            );
          })}
        </div>
      )}

      {/* rendered as a cc-layer sibling so its z-index can sit above the mouse cursor line */}
      {plus && (
        <button
          className="cc-ddl-add"
          style={{ transform: `translate(${plus.x}px, ${plus.y}px) translate(-50%, -50%)` }}
          title="Add deadline"
          onMouseDown={(e) => e.stopPropagation()}
          onClick={(e) => {
            e.stopPropagation();
            const created = addDeadline({ year, month: plus!.month, day: plus!.day, hour: plus!.hour, title: "Deadline", color: "default", originTz: null });
            onSelect(created.id);
          }}
        >
          <Plus size={11} strokeWidth={2.5} aria-hidden />
        </button>
      )}
    </>
  );
}
