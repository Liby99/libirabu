"use client";

import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { Trash2 } from "lucide-react";
import { EVENT_COLORS } from "./eventTypes";
import { Repeat } from "@/lib/calendar/api";
import TagEditor from "./TagEditor";
import RepeatEditor from "./RepeatEditor";

interface Props {
  name: string;
  onName: (v: string) => void;
  color: string;
  onColor: (c: string) => void;
  onColorPreview?: (c: string | null) => void; // hover a swatch → preview on the event
  repeat: Repeat;
  onRepeat: (r: Repeat) => void;
  anchorDow: number; // the event's own weekday (locked in the Weekdays toggle)
  focusOcc?: string | null; // set when the drawer was opened from a recurrence occurrence (ghost)
  onGoToFirst?: () => void;
  tags: string[];
  onTags: (t: string[]) => void;
  notes: string;
  onNotes: (v: string) => void;
  onDelete: () => void;
  onClose: () => void;
  children?: React.ReactNode; // per-kind metadata rows (date/time/track/tz …)
}

// Minimal, design-forward drawer shell shared by every event kind: the event name is the
// top row (auto-focused), label-less rows separated by dashed lines, a markdown notepad
// filling the rest, and a single trash icon bottom-right. Closes via the dim mask / Esc.
export default function EventDrawerShell({ name, onName, color, onColor, onColorPreview, repeat, onRepeat, anchorDow, focusOcc, onGoToFirst, tags, onTags, notes, onNotes, onDelete, onClose, children }: Props) {
  const [mounted, setMounted] = useState(false);
  const nameRef = useRef<HTMLInputElement>(null);
  useEffect(() => setMounted(true), []);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);
  // Focus + select the name when the drawer appears (double-click → start typing the name).
  useEffect(() => { if (mounted) { nameRef.current?.focus(); nameRef.current?.select(); } }, [mounted]);

  if (!mounted) return null;
  return createPortal(
    (
      <aside className="cc-drawer cc-dw" onMouseDown={(e) => e.stopPropagation()}>
        <input
          ref={nameRef}
          className="cc-dw-name"
          value={name}
          placeholder="Untitled"
          onChange={(e) => onName(e.target.value)}
          onKeyDown={(e) => { if (e.key === "Enter") (e.target as HTMLInputElement).blur(); }}
        />

        <div className="cc-dw-rows">
          {children}
          <div className="cc-dw-row">
            <RepeatEditor repeat={repeat} anchorDow={anchorDow} focusOcc={focusOcc} onChange={onRepeat} />
          </div>
          <div className="cc-dw-row cc-dw-swatches">
            {EVENT_COLORS.map((c) => (
              <button
                key={c}
                className={`cc-swatch cc-ev-${c}${color === c ? " sel" : ""}`}
                title={c}
                onClick={() => onColor(c)}
                onMouseEnter={() => onColorPreview?.(c)}
                onMouseLeave={() => onColorPreview?.(null)}
              />
            ))}
          </div>
          <div className="cc-dw-row">
            <TagEditor tags={tags} onChange={onTags} />
          </div>
        </div>

        <textarea
          className="cc-dw-notes"
          value={notes}
          placeholder="Notes…  (markdown)"
          onChange={(e) => onNotes(e.target.value)}
        />

        <div className="cc-dw-foot">
          {focusOcc && (
            <span className="cc-dw-occ">
              <span className="cc-dw-occ-badge">↻ occurrence</span>
              {onGoToFirst && <button className="cc-dw-link" onClick={onGoToFirst}>Go to first ↩</button>}
            </span>
          )}
          <button className="cc-dw-trash" title="Delete this event / series" onClick={() => { onDelete(); onClose(); }}>
            <Trash2 size={16} />
          </button>
        </div>
      </aside>
    ),
    document.body,
  );
}
