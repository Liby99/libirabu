"use client";

// Shared drawer scaffold for all event kinds: title, time/config sections, notes editor/preview, footer.

import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { Trash2, Pencil, Eye, SkipBack, X, ChevronDown, RotateCcw } from "lucide-react";
import { EVENT_COLORS } from "../../model/types/eventTypes";
import { Repeat } from "@/lib/calendar/api";
import TagEditor from "../editors/TagEditor";
import RepeatEditor from "../editors/RepeatEditor";
import NotesEditor from "../notes/NotesEditor";
import NotesPreview from "../notes/NotesPreview";
import { splitNote, composeNote, flattenManaged, parseManaged } from "@/lib/import/managedNote";

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
  imported?: boolean; // event pulled from an external calendar → title/time locked, note has a managed block
  externalUrl?: string | null; // "open at source" deep link, when imported
  hidden?: boolean; // soft-deleted imported event → offer Restore instead of the trash
  onRestore?: () => void;
  onInternalize?: () => void; // imported → detach into an editable manual copy (hides the original)
  onIsolate?: () => void; // recurring (manual) → detach this occurrence into its own standalone event
  children?: React.ReactNode; // the TIME row (per-kind date/time)
  configChildren?: React.ReactNode; // per-kind config control (promote / band track) — lives in the collapse
}

const MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const shortDate = (iso: string) => { const p = iso.split("-"); return p.length === 3 ? `${MON[(+p[1] || 1) - 1]} ${+p[2]}` : iso; };

// Drawer shell shared by every event kind. Top→bottom: title · time · divider · collapsible
// configuration (tags / colors / repeat / kind control) · divider · "Note" (+ Series|This-event
// tabs when recurring) · markdown notepad · foot (edit/preview toggle, go-to-first, delete).
export default function EventDrawerShell({ name, onName, color, onColor, onColorPreview, repeat, onRepeat, anchorDow, anchorDate, focusOcc, onGoToFirst, tags, onTags, notes, onNotes, recurring, occNotes = "", onOccNotes, onDelete, onClose, imported, externalUrl, hidden, onRestore, onInternalize, onIsolate, children, configChildren }: Props) {
  const [mounted, setMounted] = useState(false);
  // Notes view: render markdown by default when there's something to show, edit when empty.
  const [view, setView] = useState<"edit" | "preview">(() => (notes.trim() ? "preview" : "edit"));
  const [noteTab, setNoteTab] = useState<"series" | "occ">("series");
  const [configOpen, setConfigOpen] = useState(false); // the configuration section starts collapsed
  const [cursorLine, setCursorLine] = useState<number | null>(null); // ⌘-click target line for the editor
  const onOcc = recurring && noteTab === "occ" && !!onOccNotes;
  const activeNotes = onOcc ? occNotes : notes;
  const setActiveNotes = onOcc ? onOccNotes! : onNotes;
  // Imported events keep a vendor-owned managed block as the note prefix (§7): in EDIT mode on the
  // series note, we render that block read-only and let the user edit only the postfix. Occurrence
  // notes are user-only, so they edit normally.
  const seriesSplit = imported && !onOcc ? splitNote(notes) : null;
  const seriesManaged = seriesSplit?.managed ? parseManaged(seriesSplit.managed) : null; // key:value fields + description
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
      const el = e.target as HTMLElement | null;
      if (e.key === "Escape" && !el?.closest(".cm-editor")) { onClose(); return; }
      // ⌘⇧V toggles the notes view. The in-editor direction is handled inside CodeMirror (so it
      // fires while typing); here we cover the preview→edit direction (and from anywhere else in
      // the drawer that isn't an editable field, so we don't hijack paste in the title input).
      if ((e.metaKey || e.ctrlKey) && e.shiftKey && (e.key === "v" || e.key === "V") &&
          !el?.closest(".cm-editor, input, textarea, [contenteditable='true']")) {
        e.preventDefault();
        setCursorLine(null);
        setView((v) => (v === "edit" ? "preview" : "edit"));
      }
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
          className={`cc-dw-name${imported ? " cc-dw-name-locked" : ""}`}
          value={name}
          placeholder="Untitled"
          readOnly={imported}
          title={imported ? "Synced from an external calendar — edit the title at the source" : undefined}
          onChange={(e) => onName(e.target.value)}
          onKeyDown={(e) => { if (e.key === "Enter") (e.target as HTMLInputElement).blur(); }}
        />

        {imported && (
          <div className="cc-dw-source">
            <span>Synced · title &amp; time are read-only</span>
            {externalUrl && (
              <a href={externalUrl} target="_blank" rel="noopener noreferrer">Open at source ↗</a>
            )}
            {onInternalize && (
              <button className="cc-dw-source-btn" onClick={onInternalize} title="Make a fully-editable copy you own; the synced original is hidden">Make editable copy</button>
            )}
          </div>
        )}

        <div className={`cc-dw-time${imported ? " cc-dw-locked" : ""}`} aria-disabled={imported || undefined} title={imported ? "Synced — edit the time at the source" : undefined}>{children}</div>

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
          <div className="cc-dw-noteright">
            {recurring && onOccNotes && (
              <div className="cc-seg cc-dw-notetabs" role="group" aria-label="Note scope">
                <button type="button" className={`cc-seg-btn${noteTab === "series" ? " sel" : ""}`} onClick={() => switchTab("series")}>Series</button>
                <button type="button" className={`cc-seg-btn${noteTab === "occ" ? " sel" : ""}`} title="Note for this occurrence only" onClick={() => switchTab("occ")}>This event<span className="cc-dw-tab-date"> – {shortDate(focusOcc ?? anchorDate)}</span></button>
              </div>
            )}
            {recurring && onIsolate && !imported && (
              <button type="button" className="cc-dw-isolate" onClick={onIsolate}
                title="Detach this occurrence into its own standalone, editable event (leaves a gap in the series)">
                Isolate
              </button>
            )}
          </div>
        </div>

        {view === "edit" ? (
          seriesSplit && seriesSplit.managed ? (
            // Imported series note: the read-only managed info (markers + UID stripped) shows as a
            // monospace <pre> that SHARES the scroll with an auto-growing editor below — so when the
            // synced info is long, scrolling reveals the full editable area (it isn't boxed off).
            <div className="cc-dw-managed-edit">
              <pre className="cc-dw-managed-pre" title="Synced from the source — updates on re-sync">{flattenManaged(seriesSplit.managed)}</pre>
              <NotesEditor key="series-user" value={seriesSplit.user} grow onChange={(u) => onNotes(composeNote(seriesSplit.managed, u))} cursorLine={null} onPreview={showPreview} placeholder="Add your own notes / TODOs…" />
            </div>
          ) : (
            <NotesEditor key={onOcc ? "occ" : "series"} value={activeNotes} onChange={setActiveNotes} cursorLine={cursorLine} onPreview={showPreview} placeholder={onOcc ? "Anything to note about this occurrence?" : "Something to note about this event?"} />
          )
        ) : seriesSplit && seriesManaged ? (
          // Imported series preview: the synced info as a structured key:value table (UID never
          // shown), then the user's own note. Everything is selectable/copyable (see CSS).
          <div className="cc-dw-note-scroll">
            <div className="cc-dw-mi">
              {seriesManaged.fields.map((f) => (
                <div className="cc-dw-mi-row" key={f.label}>
                  <span className="cc-dw-mi-key">{f.label}</span>
                  <span className="cc-dw-mi-val">
                    {f.href ? <a href={f.href} target="_blank" rel="noopener noreferrer">{f.value}</a> : f.value}
                  </span>
                </div>
              ))}
              {seriesManaged.description && <div className="cc-dw-mi-desc"><NotesPreview value={seriesManaged.description} inline /></div>}
            </div>
            <NotesPreview value={seriesSplit.user} onChange={(v) => onNotes(composeNote(seriesSplit.managed, v))} onEditAt={editAt} inline />
          </div>
        ) : (
          <NotesPreview value={activeNotes} onChange={setActiveNotes} onEditAt={editAt} />
        )}

        <div className="cc-dw-foot">
          <div className="cc-seg cc-dw-view" role="group" aria-label="Notes view">
            <button type="button" className={`cc-seg-btn${view === "edit" ? " sel" : ""}`} title="Edit (⌘⇧V to toggle · ⌘-click the preview to edit at a spot)" aria-label="Edit notes" onClick={showEdit}><Pencil size={13} /></button>
            <button type="button" className={`cc-seg-btn${view === "preview" ? " sel" : ""}`} title="Preview (⌘⇧V)" aria-label="Preview notes" onClick={showPreview}><Eye size={13} /></button>
          </div>
          {recurring && onGoToFirst && (
            <button className="cc-dw-iconbtn" title="Go to the first occurrence" aria-label="Go to first occurrence" onClick={onGoToFirst}>
              <SkipBack size={15} />
            </button>
          )}
          {hidden && onRestore ? (
            <button className="cc-dw-iconbtn" title="Restore this hidden event" aria-label="Restore" onClick={onRestore}>
              <RotateCcw size={15} />
            </button>
          ) : (
            // onClick is just onDelete (no onClose): onDelete opens a confirm dialog (recurring
            // scope / hide / delete) that should sit over the still-open drawer. When the event
            // is actually removed, the host auto-closes the drawer (drawerEv becomes null).
            <button className="cc-dw-trash" title={imported ? "Hide this event (synced — can't be deleted here)" : "Delete this event / series"} onClick={onDelete}>
              <Trash2 size={16} />
            </button>
          )}
        </div>
      </aside>
    ),
    document.body,
  );
}
