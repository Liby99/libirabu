"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import {
  createEvent,
  updateEvent,
  deleteEvent,
} from "@/app/actions/calendar";
import type { CalEventDTO, TrackDTO } from "./shared";

const EVENT_TYPES = [
  "DEADLINE", "MEETING", "CLASS", "TRAVEL",
  "CONFERENCE", "REVIEW", "FOCUS", "OTHER",
];

export interface EventDraft {
  id?: string;
  title: string;
  notes: string;
  start: Date;
  end: Date;
  allDay: boolean;
  type: string;
  color: string;
  trackId: string;
}

/** Date → value for <input type="datetime-local"> (local time). */
function toLocalInput(d: Date): string {
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}
function fromLocalInput(s: string): Date {
  return new Date(s);
}

export function draftFromEvent(e: CalEventDTO): EventDraft {
  return {
    id: e.id,
    title: e.title,
    notes: e.notes ?? "",
    start: new Date(e.start),
    end: new Date(e.end),
    allDay: e.allDay,
    type: e.type,
    color: e.color ?? "",
    trackId: e.trackId ?? "",
  };
}

export default function EventModal({
  draft,
  tracks,
  onClose,
}: {
  draft: EventDraft;
  tracks: TrackDTO[];
  onClose: () => void;
}) {
  const router = useRouter();
  const [d, setD] = useState<EventDraft>(draft);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const isEdit = Boolean(d.id);

  function set<K extends keyof EventDraft>(k: K, v: EventDraft[K]) {
    setD((prev) => ({ ...prev, [k]: v }));
  }

  async function save() {
    setBusy(true);
    setError(null);
    try {
      const payload = {
        title: d.title.trim() || "Untitled",
        notes: d.notes || undefined,
        start: d.start.toISOString(),
        end: d.end.toISOString(),
        allDay: d.allDay,
        type: d.type as never,
        color: d.color || undefined,
        trackId: d.trackId || null,
      };
      if (isEdit) await updateEvent({ id: d.id!, ...payload });
      else await createEvent(payload);
      router.refresh();
      onClose();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to save");
    } finally {
      setBusy(false);
    }
  }

  async function remove() {
    if (!d.id) return;
    setBusy(true);
    try {
      await deleteEvent(d.id);
      router.refresh();
      onClose();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to delete");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal-card" onClick={(e) => e.stopPropagation()}>
        <h2 className="modal-title">{isEdit ? "Edit event" : "New event"}</h2>

        <label className="auth-label">Title</label>
        <input
          className="auth-input"
          value={d.title}
          autoFocus
          onChange={(e) => set("title", e.target.value)}
        />

        <div className="modal-row">
          <div style={{ flex: 1 }}>
            <label className="auth-label">Track</label>
            <select
              className="auth-input"
              value={d.trackId}
              onChange={(e) => set("trackId", e.target.value)}
            >
              <option value="">— none —</option>
              {tracks.map((t) => (
                <option key={t.id} value={t.id}>{t.name}</option>
              ))}
            </select>
          </div>
          <div style={{ flex: 1 }}>
            <label className="auth-label">Type</label>
            <select
              className="auth-input"
              value={d.type}
              onChange={(e) => set("type", e.target.value)}
            >
              {EVENT_TYPES.map((t) => (
                <option key={t} value={t}>{t}</option>
              ))}
            </select>
          </div>
        </div>

        <label className="modal-check">
          <input
            type="checkbox"
            checked={d.allDay}
            onChange={(e) => set("allDay", e.target.checked)}
          />
          All day
        </label>

        <div className="modal-row">
          <div style={{ flex: 1 }}>
            <label className="auth-label">Start</label>
            <input
              className="auth-input"
              type="datetime-local"
              value={toLocalInput(d.start)}
              onChange={(e) => set("start", fromLocalInput(e.target.value))}
            />
          </div>
          <div style={{ flex: 1 }}>
            <label className="auth-label">End</label>
            <input
              className="auth-input"
              type="datetime-local"
              value={toLocalInput(d.end)}
              onChange={(e) => set("end", fromLocalInput(e.target.value))}
            />
          </div>
        </div>

        <label className="auth-label">Notes</label>
        <textarea
          className="auth-input"
          rows={2}
          value={d.notes}
          onChange={(e) => set("notes", e.target.value)}
        />

        {error && <div className="auth-error">{error}</div>}

        <div className="modal-actions">
          {isEdit && (
            <button className="btn-danger" onClick={remove} disabled={busy}>
              Delete
            </button>
          )}
          <span style={{ flex: 1 }} />
          <button className="btn-ghost" onClick={onClose} disabled={busy}>
            Cancel
          </button>
          <button className="btn-primary" onClick={save} disabled={busy}>
            {busy ? "…" : "Save"}
          </button>
        </div>
      </div>
    </div>
  );
}
