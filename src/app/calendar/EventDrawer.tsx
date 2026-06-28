"use client";

import { TimedEvent, hourToTimeInput, timeInputToHour } from "./eventTypes";
import { NO_REPEAT } from "@/lib/calendar/api";
import EventDrawerShell from "./EventDrawerShell";
import PromoteEditor from "./PromoteEditor";

const pad = (n: number) => String(n).padStart(2, "0");

interface Props {
  event: TimedEvent;
  onChange: (id: string, patch: Partial<TimedEvent>) => void;
  onDelete: (id: string) => void;
  onClose: () => void;
  onColorPreview?: (c: string | null) => void;
  focusOcc?: string | null;
  onGoToFirst?: () => void;
}

export default function EventDrawer({ event, onChange, onDelete, onClose, onColorPreview, focusOcc, onGoToFirst }: Props) {
  const dateStr = `${event.year}-${pad(event.month + 1)}-${pad(event.day)}`;
  const occKey = focusOcc ?? dateStr; // the occurrence this drawer's per-occurrence note belongs to
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
      onGoToFirst={onGoToFirst}
      tags={event.tags ?? []}
      onTags={(t) => onChange(event.id, { tags: t })}
      notes={event.notes ?? ""}
      onNotes={(v) => onChange(event.id, { notes: v })}
      recurring={(event.repeat?.kind ?? "none") !== "none"}
      occNotes={event.occurrenceNotes?.[occKey] ?? ""}
      onOccNotes={(v) => onChange(event.id, { occurrenceNotes: { ...(event.occurrenceNotes ?? {}), [occKey]: v } })}
      onDelete={() => onDelete(event.id)}
      onClose={onClose}
      configChildren={<PromoteEditor promoteTrack={event.promoteTrack} onChange={(t) => onChange(event.id, { promoteTrack: t })} />}
    >
      <div className="cc-dw-row cc-dw-when">
        <input
          type="date"
          value={dateStr}
          onChange={(e) => {
            const [y, mo, d] = e.target.value.split("-").map(Number);
            if (y && mo && d) onChange(event.id, { year: y, month: mo - 1, day: d });
          }}
        />
        <input
          type="time"
          value={hourToTimeInput(event.startHour)}
          onChange={(e) => { const h = timeInputToHour(e.target.value); if (h != null) onChange(event.id, { startHour: Math.min(h, event.endHour - 0.25) }); }}
        />
        <span className="cc-dw-dash">–</span>
        <input
          type="time"
          value={hourToTimeInput(event.endHour)}
          onChange={(e) => { const h = timeInputToHour(e.target.value); if (h != null) onChange(event.id, { endHour: Math.max(h, event.startHour + 0.25) }); }}
        />
      </div>
    </EventDrawerShell>
  );
}
