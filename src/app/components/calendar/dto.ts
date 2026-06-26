import type { CalEventDTO, TrackDTO } from "./shared";

// Maps Prisma rows → serializable DTOs for the client views.

type EventRow = {
  id: string;
  title: string;
  notes: string | null;
  start: Date;
  end: Date;
  allDay: boolean;
  type: string;
  color: string | null;
  trackId: string | null;
  track?: { name: string; color: string } | null;
};

export function toEventDTO(e: EventRow): CalEventDTO {
  return {
    id: e.id,
    title: e.title,
    notes: e.notes,
    start: e.start.toISOString(),
    end: e.end.toISOString(),
    allDay: e.allDay,
    type: e.type,
    color: e.color,
    trackId: e.trackId,
    trackName: e.track?.name ?? null,
    trackColor: e.track?.color ?? null,
  };
}

type TrackRow = { id: string; key: string; name: string; color: string };

export function toTrackDTO(t: TrackRow): TrackDTO {
  return { id: t.id, key: t.key, name: t.name, color: t.color };
}
