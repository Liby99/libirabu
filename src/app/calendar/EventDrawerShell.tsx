"use client";

import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { Trash2, Pencil, Eye, SkipBack, X, ChevronDown } from "lucide-react";
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
  anchorDate: string; // the event's own date "YYYY-MM-DD"
  focusOcc?: string | null; // set when the drawer was opened from a recurrence occurrence (ghost)
  onGoToFirst?: () => void;
  tags: string[];
  onTags: (t: string[]) => void;
  notes: string; // the "series" note (whole event / all occurrences)
  onNotes: (v: string) => void;
  recurring?: boolean; // → show the Series/This-event note tabs + the "go to first" foot button
  occNotes?: string;
  onOccNotes?: (v: string) => void;
  onDelete: () => void;
  onClose: () => void;
  children?: React.ReactNode; // the TIME row (per-kind date/time)
  configChildren?: React.ReactNode; // per-kind config control (promote / band track) — lives in the collapse
}

const MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const shortDate = (iso: string) => { const p = iso.split("-"); return p.length === 3 ? `${MON[(+p[1] || 1) - 1]} ${+p[2]}` : iso; };

// Drawer shell shared by every event kind. Top→bottom: title · time · divider · collapsible
// configuration (tags / colors / repeat / kind control) · divider · "Note" (+ Series|This-event
// tabs when recurring) · markdown notepad · foot (edit/preview toggle, go-to-first, delete).
export default function EventDrawerShell({ name, onName, color, onColor, onColorPreview, repeat, onRepeat, anchorDow, anchorDate, focusOcc, onGoToFirst, tags, onTags, notes, onNotes, recurring, occNotes = "", onOccNotes, onDelete, onClose, children, configChildren }: Props) {
  const [mounted, setMounted] = useState(false);
  // Notes view: render markdown by default when there's something to show, edit when empty.
  const [view, setView] = useState<"edit" | "preview">(() => (notes.trim() ? "preview" : "edit"));
  const [noteTab, setNoteTab] = useState<"series" | "occ">("series");
  const [configOpen, setConfigOpen] = useState(false); // the configuration section starts collapsed
  const [cursorLine, setCursorLine] = useState<number | null>(null); // ⌘-click target line for the editor
  const onOcc = recurring && noteTab === "occ" && !!onOccNotes;
  const activeNotes = onOcc ? occNotes : notes;
  const setActiveNotes = onOcc ? onOccNotes! : onNotes;
  const switchTab = (tab: "series" | "occ") => {
    setNoteTab(tab);
    setCursorLine(null);
    const target = tab === "occ" ? occNotes : notes; // open each note in its sensible view
    setView(target.trim() ? "preview" : "edit");
  };
  const showEdit = () => { setCursorLine(null); setView("edit"); };
  const showPreview = () => { setCursorLine(null); setView("preview"); };
  const editAt = (line: number) => { setCursorLine(line); setView("edit"); }; // ⌘-click in the preview

  const nameRef = useRef<HTMLInputElement>(null);
  useEffect(() => setMounted(true), []);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape" && !(e.target as HTMLElement | null)?.closest(".cm-editor")) onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);
  useEffect(() => { if (mounted) { nameRef.current?.focus(); nameRef.current?.select(); } }, [mounted]);

  // Drag the left edge to widen the drawer (updates --cc-drawer-w; grow-only from the default).
  const onResizeDown = (e: React.MouseEvent) => {
    e.preventDefault();
    const minW = 372;
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
        <button className="cc-dw-close" onClick={onClose} title="Close" aria-label="Close"><X size={16} /></button>

        <input
          ref={nameRef}
          className="cc-dw-name"
          value={name}
          placeholder="Untitled"
          onChange={(e) => onName(e.target.value)}
          onKeyDown={(e) => { if (e.key === "Enter") (e.target as HTMLInputElement).blur(); }}
        />

        <div className="cc-dw-time">{children}</div>

        <div className="cc-dw-row cc-dw-swatches cc-dw-colors">
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

        <hr className="cc-dw-divider" />

        <div className={`cc-dw-config${configOpen ? " open" : ""}`}>
          <button type="button" className="cc-dw-config-head" onClick={() => setConfigOpen((o) => !o)} aria-expanded={configOpen}>
            <span>Configuration</span>
            <ChevronDown size={14} className="cc-dw-config-chevron" />
          </button>
          <div className="cc-dw-config-wrap">
            <div className="cc-dw-config-body">
              <div className="cc-dw-row"><TagEditor tags={tags} onChange={onTags} /></div>
              <div className="cc-dw-row">
                <RepeatEditor repeat={repeat} anchorDow={anchorDow} anchorDate={anchorDate} focusOcc={focusOcc} onChange={onRepeat} />
              </div>
              {configChildren}
            </div>
          </div>
        </div>

        <hr className="cc-dw-divider" />

        <div className="cc-dw-noterow">
          <span className="cc-dw-notelabel">Note</span>
          {recurring && onOccNotes && (
            <div className="cc-seg cc-dw-notetabs" role="group" aria-label="Note scope">
              <button type="button" className={`cc-seg-btn${noteTab === "series" ? " sel" : ""}`} onClick={() => switchTab("series")}>Series</button>
              <button type="button" className={`cc-seg-btn${noteTab === "occ" ? " sel" : ""}`} title="Note for this occurrence only" onClick={() => switchTab("occ")}>This event</button>
            </div>
          )}
        </div>

        {view === "edit"
          ? <NotesEditor key={onOcc ? "occ" : "series"} value={activeNotes} onChange={setActiveNotes} cursorLine={cursorLine} placeholder={onOcc ? "Anything to note about this occurrence?" : "Something to note about this event?"} />
          : <NotesPreview value={activeNotes} onChange={setActiveNotes} onEditAt={editAt} />}

        <div className="cc-dw-foot">
          <div className="cc-seg cc-dw-view" role="group" aria-label="Notes view">
            <button type="button" className={`cc-seg-btn${view === "edit" ? " sel" : ""}`} title="Edit (⌘-click the preview to edit at a spot)" aria-label="Edit notes" onClick={showEdit}><Pencil size={13} /></button>
            <button type="button" className={`cc-seg-btn${view === "preview" ? " sel" : ""}`} title="Preview" aria-label="Preview notes" onClick={showPreview}><Eye size={13} /></button>
          </div>
          {recurring && onGoToFirst && (
            <button className="cc-dw-iconbtn" title="Go to the first occurrence" aria-label="Go to first occurrence" onClick={onGoToFirst}>
              <SkipBack size={15} />
            </button>
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
