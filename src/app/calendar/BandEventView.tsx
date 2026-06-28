"use client";

import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { BandEvent } from "./bandEventTypes";
import { BandRect } from "./bandGeom";

interface Props {
  ev: BandEvent;
  rect: BandRect;
  vw: number;          // viewport width → cap the inline editor so it can't run off-screen
  gap?: number;        // px to the next event on the lane → clip the title to this width
  raised: boolean;     // hovered → lift above neighbours so the full title can show
  onHover: (id: string | null) => void;
  selected: boolean;
  moving: boolean;
  movedRef: React.MutableRefObject<boolean>;
  onMoveStart: (id: string, e: React.MouseEvent) => void;
  onResizeStart: (id: string, edge: "start" | "end", e: React.MouseEvent) => void;
  onSelect: (id: string | null) => void;
  onTitleCommit: (id: string, title: string) => void;
  onOpenDetail: (id: string) => void;
  onContextMenu: (id: string, x: number, y: number) => void;
}

// All-day event bar — identical look to a timed event (two-layer + left bar), title only.
export default function BandEventView({ ev, rect, vw, gap, raised, onHover, selected, moving, movedRef, onMoveStart, onResizeStart, onSelect, onTitleCommit, onOpenDetail, onContextMenu }: Props) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(ev.title);
  const inputRef = useRef<HTMLInputElement>(null);
  const titleRef = useRef<HTMLDivElement>(null);
  useEffect(() => { if (editing) inputRef.current?.select(); }, [editing]);

  // On hover, a frosted mask covers the title's spill — but ONLY when the title actually
  // runs into a following event (its right end passes the next event's left). With no next
  // event (or one that starts after the text ends), the title just overflows freely, no mask.
  const [maskW, setMaskW] = useState(0);
  useLayoutEffect(() => {
    if (!raised || !titleRef.current) { setMaskW(0); return; }
    const titleEnd = titleRef.current.offsetLeft + titleRef.current.offsetWidth; // text block RHS, rel. to block
    const overlapsNext = gap != null && gap < titleEnd;
    setMaskW(overlapsNext ? Math.max(0, titleEnd + 9 - rect.w) : 0);
  }, [raised, gap, rect.w, ev.title]);

  const commit = () => {
    setEditing(false);
    const t = draft.trim() || "Event";
    setDraft(t);
    if (t !== ev.title) onTitleCommit(ev.id, t);
  };

  // The editor overflows the bar to the right (overflow:visible + min-width:100px), so on a
  // bar near the screen edge it would run off-screen. Cap its width to the space left up to
  // the viewport's right edge; minWidth shrinks too so the cap actually binds there.
  const inputLeft = rect.x + 9; // event left + inner margin/border/padding
  const avail = Math.max(24, vw - 8 - inputLeft);
  const inputStyle: React.CSSProperties = { maxWidth: avail, minWidth: Math.min(100, avail) };

  const style: React.CSSProperties = {
    transform: `translate(${rect.x}px, ${rect.y}px)`,
    width: rect.w,
    height: rect.h,
    pointerEvents: "auto",
    // A later start date stacks on top of an earlier one (timeline order). Inline so it
    // beats .cc-tevent:hover. Selected/moving/hovered pop to the front (hovered so the
    // full title can show over the next event).
    zIndex: moving ? 1001 : selected ? 1000 : raised ? 950 : 10 + ev.startDay,
    ...(gap != null ? ({ "--band-gap": `${Math.max(12, gap - 10)}px` } as React.CSSProperties) : {}),
  };

  return (
    <>
      {/* frosted mask rendered as a sibling (NOT a child) of the event so its backdrop-filter
          escapes the event's own backdrop-filter and actually blurs the event behind it. */}
      {raised && maskW > 0 && (
        <div className={`cc-band-mask cc-ev-${ev.color}`} style={{ left: rect.x + rect.w, top: rect.y, width: maskW, height: rect.h, zIndex: 949 }} />
      )}
    <div
      data-ev-id={ev.id}
      className={`cc-item cc-tevent cc-tevent-band cc-ev-${ev.color}${selected ? " selected" : ""}${moving ? " moving" : ""}${gap != null ? " cc-band-clip" : ""}${raised ? " cc-band-raised" : ""}`}
      style={style}
      onMouseEnter={() => onHover(ev.id)}
      onMouseLeave={() => onHover(null)}
      onMouseDown={(e) => onMoveStart(ev.id, e)}
      onClick={(e) => { e.stopPropagation(); if (movedRef.current) return; onSelect(ev.id); }}
      onDoubleClick={(e) => { e.stopPropagation(); setEditing(false); onOpenDetail(ev.id); }}
      onContextMenu={(e) => {
        e.preventDefault();
        e.stopPropagation();
        const r = e.currentTarget.getBoundingClientRect();
        onContextMenu(ev.id, r.left + r.width / 2, r.top);
      }}
    >
      <div className="cc-tevent-inner">
        {editing ? (
          <input
            ref={inputRef}
            className="cc-tevent-title-input"
            style={inputStyle}
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onBlur={commit}
            onKeyDown={(e) => {
              if (e.key === "Enter") commit();
              else if (e.key === "Escape") { setDraft(ev.title); setEditing(false); }
            }}
            onMouseDown={(e) => e.stopPropagation()}
          />
        ) : (
          <div
            className="cc-tevent-title"
            ref={titleRef}
            onClick={(e) => {
              e.stopPropagation();
              if (e.detail >= 2) return; // double-click → open the drawer, don't edit inline
              if (movedRef.current) return;
              if (!selected) { onSelect(ev.id); return; }
              setDraft(ev.title); setEditing(true);
            }}
          >
            {ev.title}
          </div>
        )}
      </div>

      {/* Resize edges — only on the selected bar, and only for an edge that's on-screen. */}
      {selected && !rect.clipStart && (
        <div className="cc-tevent-handle-x cc-tevent-handle-left" onMouseDown={(e) => onResizeStart(ev.id, "start", e)} />
      )}
      {selected && !rect.clipEnd && (
        <div className="cc-tevent-handle-x cc-tevent-handle-right" onMouseDown={(e) => onResizeStart(ev.id, "end", e)} />
      )}
    </div>
    </>
  );
}
