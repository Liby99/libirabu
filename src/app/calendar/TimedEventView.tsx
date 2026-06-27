"use client";

import { useEffect, useRef, useState } from "react";
import { TimedEvent, fmtRange } from "./eventTypes";
import { EventRect } from "./eventGeom";

interface Props {
  ev: TimedEvent;
  rect: EventRect;
  wide: boolean;        // week view → show title + time + handles
  reveal: number;       // fade-in opacity
  interactive: boolean; // week view → resize / title edit enabled
  onResizeStart: (id: string, edge: "top" | "bottom", e: React.MouseEvent) => void;
  onMoveStart: (id: string, e: React.MouseEvent) => void;
  onTitleCommit: (id: string, title: string) => void;
  onHover: (over: boolean) => void;
  onOpenDetail: (id: string) => void;
  onContextMenu: (id: string, x: number, y: number) => void;
  selected: boolean;
  onSelect: (id: string | null) => void;
  moving: boolean;
  movedRef: React.MutableRefObject<boolean>;
}

export default function TimedEventView({ ev, rect, wide, reveal, interactive, onResizeStart, onMoveStart, onTitleCommit, onHover, onOpenDetail, onContextMenu, selected, onSelect, moving, movedRef }: Props) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(ev.title);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => { if (editing) inputRef.current?.select(); }, [editing]);

  const commit = () => {
    setEditing(false);
    const t = draft.trim() || "Event";
    setDraft(t);
    if (t !== ev.title) onTitleCommit(ev.id, t);
  };

  const style: React.CSSProperties = {
    transform: `translate(${rect.x}px, ${rect.y}px)`,
    width: rect.w,
    height: rect.h,
    opacity: reveal,
    pointerEvents: interactive ? "auto" : "none",
  };
  // Too short for a time line → show the title only. Tiny events shrink the font so the
  // title still fits. Title clamps to a whole number of lines (fixed line-height) so a
  // line is never half cut off.
  const tiny = rect.h < 26;        // ~15 min
  const short = rect.h < 40;       // ~≤30 min: hide the time
  const LINE_H = tiny ? 12 : 16;   // px per title line (must match .cc-tevent-title line-height)
  const avail = rect.h - (tiny ? 2 : 10) - (short ? 0 : 13);
  const titleLines = Math.max(1, Math.floor(avail / LINE_H));

  return (
    <div
      data-ev-id={ev.id}
      className={`cc-item cc-tevent cc-ev-${ev.color}${selected ? " selected" : ""}${moving ? " moving" : ""}${short ? " cc-tevent-short" : ""}${tiny ? " cc-tevent-tiny" : ""}`}
      style={style}
      onMouseDown={(e) => onMoveStart(ev.id, e)}
      onClick={(e) => { e.stopPropagation(); if (movedRef.current) return; onSelect(ev.id); }}
      onDoubleClick={(e) => { if (!interactive) return; e.stopPropagation(); setEditing(false); onOpenDetail(ev.id); }}
      onMouseEnter={() => onHover(true)}
      onMouseLeave={() => onHover(false)}
      onContextMenu={(e) => {
        if (!interactive) return;
        e.preventDefault();
        e.stopPropagation();
        const r = e.currentTarget.getBoundingClientRect();
        onContextMenu(ev.id, r.left + r.width / 2, r.top);
      }}
    >
      {/* inner layer: holds the text + the accent/outline border */}
      <div className="cc-tevent-inner">
        {wide && (
          editing ? (
            <input
              ref={inputRef}
              className="cc-tevent-title-input"
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
              style={{ WebkitLineClamp: titleLines } as React.CSSProperties}
              onClick={(e) => {
                e.stopPropagation();
                if (e.detail >= 2) return; // part of a double-click → let it open the drawer
                if (movedRef.current) return; // just finished a move drag
                if (!selected) { onSelect(ev.id); return; } // first click selects; click again to edit
                if (interactive) { setDraft(ev.title); setEditing(true); }
              }}
            >
              {ev.title}
            </div>
          )
        )}
        {wide && !short && <div className="cc-tevent-time">{fmtRange(ev.startHour, ev.endHour)}</div>}
      </div>

      {interactive && (
        <div className="cc-tevent-handle cc-tevent-handle-top" onMouseDown={(e) => onResizeStart(ev.id, "top", e)} />
      )}
      {interactive && (
        <div className="cc-tevent-handle cc-tevent-handle-bottom" onMouseDown={(e) => onResizeStart(ev.id, "bottom", e)} />
      )}
    </div>
  );
}
