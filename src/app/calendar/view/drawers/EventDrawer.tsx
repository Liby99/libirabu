"use client";

// Timed-event drawer: wraps EventDrawerShell with start/end time inputs + promote toggle.

import { SkipBack } from "lucide-react";
import { TimedEvent, hourToTimeInput, timeInputToHour } from "../../model/types/eventTypes";
import { NO_REPEAT } from "@/lib/calendar/api";
import EventDrawerShell from "./EventDrawerShell";
import PromoteEditor from "../editors/PromoteEditor";

const pad = (n: number) => String(n).padStart(2, "0");
const MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const fmtDate = (iso: string) => { const p = iso.split("-"); return p.length === 3 ? `${MON[(+p[1] || 1) - 1]} ${+p[2]}` : iso; };

interface Props {
  event: TimedEvent;
  onChange: (id: string, patch: Partial<TimedEvent>) => void;
  onDelete: (id: string) => void;
  onRestore?: (id: string) => void;
  onInternalize?: (id: string) => void;
  onIsolate?: (id: string) => void;
  onClose: () => void;
  onColorPreview?: (c: string | null) => void;
  focusOcc?: string | null;
  onGoToFirst?: () => void;
}

export default function EventDrawer({ event, onChange, onDelete, onClose, onRestore, onInternalize, onIsolate, onColorPreview, focusOcc, onGoToFirst }: Props) {
  const dateStr = `${event.year}-${pad(event.month + 1)}-${pad(event.day)}`;
  const occKey = focusOcc ?? dateStr; // the occurrence this drawer's per-occurrence note belongs to
  const recurring = (event.repeat?.kind ?? "none") !== "none";
  const onDate = (v: string) => { const [y, mo, d] = v.split("-").map(Number); if (y && mo && d) onChange(event.id, { year: y, month: mo - 1, day: d }); };
  const onStart = (v: string) => { const h = timeInputToHour(v); if (h != null) onChange(event.id, { startHour: Math.min(h, event.endHour - 0.25) }); };
  const onEnd = (v: string) => { const h = timeInputToHour(v); if (h != null) onChange(event.id, { endHour: Math.max(h, event.startHour + 0.25) }); };
  const timeInputs = (
    <>
      <input type="time" value={hourToTimeInput(event.startHour)} onChange={(e) => onStart(e.target.value)} />
      <span className="cc-dw-dash">–</span>
      <input type="time" value={hourToTimeInput(event.endHour)} onChange={(e) => onEnd(e.target.value)} />
    </>
  );
  return (
    <EventDrawerShell
      name={event.title}
      onName={(v) => onChange(event.id, { title: v })}
      color={event.color}
      onColor={(c) => onChange(event.id, { color: c })}
      onColorPreview={onColorPreview}
      repeat={event.repeat ?? NO_REPEAT}
      onRepeat={(r) => onChange(event.id, { repeat: r })}
      anchorDow={new Date(event.year, event.month, event.day).getDay()}
      anchorDate={dateStr}
      focusOcc={focusOcc}
      onGoToFirst={undefined} /* rendered inline on the Initial Event Date row instead of the foot */
      tags={event.tags ?? []}
      onTags={(t) => onChange(event.id, { tags: t })}
      notes={event.notes ?? ""}
      onNotes={(v) => onChange(event.id, { notes: v })}
      recurring={(event.repeat?.kind ?? "none") !== "none"}
      occNotes={event.occurrenceNotes?.[occKey] ?? ""}
      onOccNotes={(v) => onChange(event.id, { occurrenceNotes: { ...(event.occurrenceNotes ?? {}), [occKey]: v } })}
      onDelete={() => onDelete(event.id)}
      onClose={onClose}
      imported={event.imported}
      externalUrl={event.externalUrl}
      hidden={event.hidden}
      onRestore={onRestore ? () => onRestore(event.id) : undefined}
      onInternalize={onInternalize ? () => onInternalize(event.id) : undefined}
      onIsolate={onIsolate ? () => onIsolate(event.id) : undefined}
      configChildren={<PromoteEditor promoteTrack={event.promoteTrack} onChange={(t) => onChange(event.id, { promoteTrack: t })} />}
    >
      {recurring ? (
        <>
          {/* Recurring: name the occurrence being viewed, with its time; the editable date
              below is the series' initial (base) date — editing it moves the whole series. */}
          <div className="cc-dw-row cc-dw-when">
            <span className="cc-dw-label">This Event:</span>
            <span className="cc-dw-occ">{fmtDate(focusOcc ?? dateStr)}</span>
            {timeInputs}
          </div>
          <div className="cc-dw-row cc-dw-when cc-dw-initrow">
            <span className="cc-dw-label">Initial Event Date:</span>
            <input type="date" value={dateStr} onChange={(e) => onDate(e.target.value)} />
            {onGoToFirst && (
              <button className="cc-dw-iconbtn cc-dw-initgoto" title="Go to the first occurrence" aria-label="Go to first occurrence" onClick={onGoToFirst}>
                <SkipBack size={15} />
              </button>
            )}
          </div>
        </>
      ) : (
        <div className="cc-dw-row cc-dw-when">
          <input type="date" value={dateStr} onChange={(e) => onDate(e.target.value)} />
          {timeInputs}
        </div>
      )}
    </EventDrawerShell>
  );
}
