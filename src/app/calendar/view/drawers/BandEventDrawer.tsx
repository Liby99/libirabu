"use client";

// All-day-event drawer: date-range inputs (clamped to the month) + track picker.

import { BandEvent } from "../../model/types/bandEventTypes";
import { daysInMonth } from "../../model/api/mock";
import { NO_REPEAT } from "@/lib/calendar/api";
import EventDrawerShell from "./EventDrawerShell";

const pad = (n: number) => String(n).padStart(2, "0");

interface Props {
  event: BandEvent;
  onChange: (id: string, patch: Partial<BandEvent>) => void;
  onDelete: (id: string) => void;
  onRestore?: (id: string) => void;
  onInternalize?: (id: string) => void;
  onIsolate?: (id: string) => void;
  onClose: () => void;
  onColorPreview?: (c: string | null) => void;
  focusOcc?: string | null;
  onGoToFirst?: () => void;
}

// All-day (band) event: single month, so the date pickers are clamped to its month.
export default function BandEventDrawer({ event, onChange, onDelete, onClose, onRestore, onInternalize, onIsolate, onColorPreview, focusOcc, onGoToFirst }: Props) {
  const dim = daysInMonth(event.month);
  const monthPrefix = `${event.year}-${pad(event.month + 1)}`;
  const minDate = `${monthPrefix}-01`;
  const maxDate = `${monthPrefix}-${pad(dim)}`;
  const dayWithin = (value: string): number | null => {
    const [y, mo, d] = value.split("-").map(Number);
    if (!y || !mo || !d || y !== event.year || mo - 1 !== event.month) return null;
    return Math.min(dim, Math.max(1, d));
  };
  return (
    <EventDrawerShell
      name={event.title}
      onName={(v) => onChange(event.id, { title: v })}
      color={event.color}
      onColor={(c) => onChange(event.id, { color: c })}
      onColorPreview={onColorPreview}
      repeat={event.repeat ?? NO_REPEAT}
      onRepeat={(r) => onChange(event.id, { repeat: r })}
      anchorDow={new Date(event.year, event.month, event.startDay).getDay()}
      anchorDate={`${monthPrefix}-${pad(event.startDay)}`}
      focusOcc={focusOcc}
      onGoToFirst={onGoToFirst}
      tags={event.tags ?? []}
      onTags={(t) => onChange(event.id, { tags: t })}
      notes={event.notes ?? ""}
      onNotes={(v) => onChange(event.id, { notes: v })}
      recurring={(event.repeat?.kind ?? "none") !== "none"}
      occNotes={event.occurrenceNotes?.[focusOcc ?? `${monthPrefix}-${pad(event.startDay)}`] ?? ""}
      onOccNotes={(v) => { const k = focusOcc ?? `${monthPrefix}-${pad(event.startDay)}`; onChange(event.id, { occurrenceNotes: { ...(event.occurrenceNotes ?? {}), [k]: v } }); }}
      onDelete={() => onDelete(event.id)}
      onClose={onClose}
      imported={event.imported}
      externalUrl={event.externalUrl}
      hidden={event.hidden}
      onRestore={onRestore ? () => onRestore(event.id) : undefined}
      onInternalize={onInternalize ? () => onInternalize(event.id) : undefined}
      onIsolate={onIsolate ? () => onIsolate(event.id) : undefined}
      configChildren={
        <div className="cc-dw-row cc-dw-when">
          <span className="cc-dw-label">Track</span>
          <div className="cc-seg" role="group" aria-label="Track">
            {[0, 1, 2, 3].map((t) => (
              <button
                key={t}
                type="button"
                className={`cc-seg-btn${event.track === t ? " sel" : ""}`}
                onClick={() => onChange(event.id, { track: t })}
              >
                T{t + 1}
              </button>
            ))}
          </div>
        </div>
      }
    >
      <div className="cc-dw-row cc-dw-when">
        <input
          type="date" min={minDate} max={maxDate}
          value={`${monthPrefix}-${pad(event.startDay)}`}
          onChange={(e) => { const d = dayWithin(e.target.value); if (d != null) onChange(event.id, { startDay: Math.min(d, event.endDay) }); }}
        />
        <span className="cc-dw-dash">–</span>
        <input
          type="date" min={minDate} max={maxDate}
          value={`${monthPrefix}-${pad(event.endDay)}`}
          onChange={(e) => { const d = dayWithin(e.target.value); if (d != null) onChange(event.id, { endDay: Math.max(d, event.startDay) }); }}
        />
      </div>
    </EventDrawerShell>
  );
}
