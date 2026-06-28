"use client";

import { Deadline } from "./deadlineTypes";
import { DEADLINE_TZS, convertWallClock, NO_REPEAT } from "@/lib/calendar/api";
import EventDrawerShell from "./EventDrawerShell";
import PromoteEditor from "./PromoteEditor";

const pad = (n: number) => String(n).padStart(2, "0");
const hhmm = (hour: number) => {
  let h = Math.floor(hour); let m = Math.round((hour - h) * 60);
  if (m === 60) { m = 0; h += 1; }
  return `${pad(h)}:${pad(m)}`;
};

interface Props {
  event: Deadline;
  mainTz: string;
  onChange: (id: string, patch: Partial<Deadline>) => void;
  onDelete: (id: string) => void;
  onClose: () => void;
  onColorPreview?: (c: string | null) => void;
  focusOcc?: string | null;
  onGoToFirst?: () => void;
}

// When an origin tz is set, the date/time fields edit the origin-tz value (the stored
// main-tz moment is recomputed); with no origin tz you edit your main-tz time directly.
export default function DeadlineDrawer({ event, mainTz, onChange, onDelete, onClose, onColorPreview, focusOcc, onGoToFirst }: Props) {
  const editTz = event.originTz || null;
  const mainWall = `${event.year}-${pad(event.month + 1)}-${pad(event.day)}T${hhmm(event.hour)}`;
  const editWall = editTz ? convertWallClock(mainWall, mainTz, editTz) : mainWall;
  const [editDate, editClock] = editWall.split("T");
  const editTime = editClock.slice(0, 5);

  const applyEdit = (date: string, time: string) => {
    const main = editTz ? convertWallClock(`${date}T${time}`, editTz, mainTz) : `${date}T${time}`;
    const [d, t] = main.split("T");
    const [y, mo, da] = d.split("-").map(Number);
    const [h, mi] = t.split(":").map(Number);
    if (y && mo && da) onChange(event.id, { year: y, month: mo - 1, day: da, hour: h + (mi || 0) / 60 });
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
      anchorDow={new Date(event.year, event.month, event.day).getDay()}
      anchorDate={`${event.year}-${pad(event.month + 1)}-${pad(event.day)}`}
      focusOcc={focusOcc}
      onGoToFirst={onGoToFirst}
      tags={event.tags ?? []}
      onTags={(t) => onChange(event.id, { tags: t })}
      notes={event.notes ?? ""}
      onNotes={(v) => onChange(event.id, { notes: v })}
      recurring={(event.repeat?.kind ?? "none") !== "none"}
      occNotes={event.occurrenceNotes?.[focusOcc ?? `${event.year}-${pad(event.month + 1)}-${pad(event.day)}`] ?? ""}
      onOccNotes={(v) => { const k = focusOcc ?? `${event.year}-${pad(event.month + 1)}-${pad(event.day)}`; onChange(event.id, { occurrenceNotes: { ...(event.occurrenceNotes ?? {}), [k]: v } }); }}
      onDelete={() => onDelete(event.id)}
      onClose={onClose}
      configChildren={<PromoteEditor promoteTrack={event.promoteTrack} onChange={(t) => onChange(event.id, { promoteTrack: t })} />}
    >
      <div className="cc-dw-row cc-dw-when">
        <input type="date" value={editDate} onChange={(e) => { if (e.target.value) applyEdit(e.target.value, editTime); }} />
        <input type="time" value={editTime} onChange={(e) => { if (e.target.value) applyEdit(editDate, e.target.value); }} />
        <select value={event.originTz ?? ""} onChange={(e) => onChange(event.id, { originTz: e.target.value || null })}>
          <option value="">My timezone</option>
          {DEADLINE_TZS.map((t) => <option key={t.id} value={t.id}>{t.label}</option>)}
        </select>
      </div>
      {editTz && <div className="cc-dw-row cc-dw-hint">In your timezone: {mainWall.split("T")[0]} {hhmm(event.hour)}</div>}
    </EventDrawerShell>
  );
}
