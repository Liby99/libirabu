"use client";

import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { Trash2, Pencil, Eye, SkipBack } from "lucide-react";
import { EVENT_COLORS } from "./eventTypes";
import { Repeat } from "@/lib/calendar/api";
import TagEditor from "./TagEditor";
import RepeatEditor from "./RepeatEditor";
import NotesEditor from "./NotesEditor";
import NotesPreview from "./NotesPreview";

interface Props {
  name: string;
  onName: (v: string) => void;
  color: string;
  onColor: (c: string) => void;
  onColorPreview?: (c: string | null) => void; // hover a swatch → preview on the event
  repeat: Repeat;
  onRepeat: (r: Repeat) => void;
  anchorDow: number; // the event's own weekday (locked in the Weekdays toggle)
  anchorDate: string; // the event's own date "YYYY-MM-DD" (the "this event" until target)
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
export default function EventDrawerShell({ name, onName, color, onColor, onColorPreview, repeat, onRepeat, anchorDow, anchorDate, focusOcc, onGoToFirst, tags, onTags, notes, onNotes, onDelete, onClose, children }: Props) {
  const [mounted, setMounted] = useState(false);
  // Notes view: render the markdown by default when there's something to show, edit when
  // empty. (The shell is keyed by event id, so this re-initializes each time a drawer opens.)
  const [view, setView] = useState<"edit" | "preview">(() => (notes.trim() ? "preview" : "edit"));
  const nameRef = useRef<HTMLInputElement>(null);
  useEffect(() => setMounted(true), []);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      // Esc inside the notes editor is for its own search panel — don't close the drawer.
      if (e.key === "Escape" && !(e.target as HTMLElement | null)?.closest(".cm-editor")) onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);
  // Focus + select the name when the drawer appears (double-click → start typing the name).
  useEffect(() => { if (mounted) { nameRef.current?.focus(); nameRef.current?.select(); } }, [mounted]);

  // Drag the left edge to widen the drawer. Both the drawer width and the page's leftward
  // shift read --cc-drawer-w, so updating that one variable moves everything together. The
  // minimum is the default width (grow-only); the shell's transform transition is suspended
  // during the drag so it tracks the cursor without lag.
  const onResizeDown = (e: React.MouseEvent) => {
    e.preventDefault();
    const minW = 372; // == the default --cc-drawer-w in globals.css
    const maxW = Math.max(minW, Math.min(900, Math.round(window.innerWidth * 0.7)));
    document.body.classList.add("cc-drawer-resizing");
    const onMove = (me: MouseEvent) => {
      const w = Math.max(minW, Math.min(maxW, Math.round(window.innerWidth - me.clientX)));
      document.documentElement.style.setProperty("--cc-drawer-w", `${w}px`);
    };
    const onUp = () => {
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
      document.body.classList.remove("cc-drawer-resizing");
    };
    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
  };

  if (!mounted) return null;
  return createPortal(
    (
      <aside className="cc-drawer cc-dw" onMouseDown={(e) => e.stopPropagation()}>
        <div className="cc-dw-resize" onMouseDown={onResizeDown} title="Drag to resize" />
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
            <RepeatEditor repeat={repeat} anchorDow={anchorDow} anchorDate={anchorDate} focusOcc={focusOcc} onChange={onRepeat} />
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

        {view === "edit"
          ? <NotesEditor value={notes} onChange={onNotes} placeholder="Notes…  (markdown)" />
          : <NotesPreview value={notes} />}

        <div className="cc-dw-foot">
          {focusOcc && (
            <span className="cc-dw-occ">
              <span className="cc-dw-occ-badge">↻ occurrence</span>
              {onGoToFirst && (
                <button className="cc-dw-iconbtn" title="Go to first occurrence" aria-label="Go to first occurrence" onClick={onGoToFirst}>
                  <SkipBack size={15} />
                </button>
              )}
            </span>
          )}
          <div className="cc-dw-foot-right">
            <div className="cc-seg cc-dw-view" role="group" aria-label="Notes view">
              <button type="button" className={`cc-seg-btn${view === "edit" ? " sel" : ""}`} title="Edit" aria-label="Edit notes" onClick={() => setView("edit")}><Pencil size={13} /></button>
              <button type="button" className={`cc-seg-btn${view === "preview" ? " sel" : ""}`} title="Preview" aria-label="Preview notes" onClick={() => setView("preview")}><Eye size={13} /></button>
            </div>
            <button className="cc-dw-trash" title="Delete this event / series" onClick={() => { onDelete(); onClose(); }}>
              <Trash2 size={16} />
            </button>
          </div>
        </div>
      </aside>
    ),
    document.body,
  );
}
