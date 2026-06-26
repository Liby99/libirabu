"use server";

import { z } from "zod";
import { revalidatePath } from "next/cache";
import { prisma } from "@/lib/prisma";
import { requireUserId } from "@/lib/auth";

// ── Tracks ────────────────────────────────────────────────────────────
const trackInput = z.object({
  key: z.string().min(1).max(40),
  name: z.string().min(1).max(80),
  color: z.string().min(1).max(20),
  order: z.number().int().optional(),
});

export async function listTracks() {
  const userId = await requireUserId();
  return prisma.track.findMany({
    where: { userId },
    orderBy: { order: "asc" },
  });
}

export async function createTrack(input: z.infer<typeof trackInput>) {
  const userId = await requireUserId();
  const data = trackInput.parse(input);
  const track = await prisma.track.create({ data: { ...data, userId } });
  revalidatePath("/week");
  revalidatePath("/day");
  return track;
}

// ── Events ────────────────────────────────────────────────────────────
const EVENT_TYPES = [
  "DEADLINE", "MEETING", "CLASS", "TRAVEL",
  "CONFERENCE", "REVIEW", "FOCUS", "OTHER",
] as const;

const eventInput = z.object({
  title: z.string().min(1).max(200),
  notes: z.string().max(2000).optional(),
  start: z.string().datetime({ offset: true }),
  end: z.string().datetime({ offset: true }),
  allDay: z.boolean().optional(),
  type: z.enum(EVENT_TYPES).optional(),
  color: z.string().max(20).optional(),
  trackId: z.string().optional().nullable(),
});

export async function listEvents(rangeStartISO: string, rangeEndISO: string) {
  const userId = await requireUserId();
  const rangeStart = new Date(rangeStartISO);
  const rangeEnd = new Date(rangeEndISO);
  // events that overlap [rangeStart, rangeEnd)
  return prisma.calEvent.findMany({
    where: {
      userId,
      start: { lt: rangeEnd },
      end: { gt: rangeStart },
    },
    orderBy: { start: "asc" },
    include: { track: true },
  });
}

export async function createEvent(input: z.infer<typeof eventInput>) {
  const userId = await requireUserId();
  const data = eventInput.parse(input);
  if (new Date(data.end) < new Date(data.start)) {
    throw new Error("Event end must be on or after start");
  }
  const event = await prisma.calEvent.create({
    data: {
      userId,
      title: data.title,
      notes: data.notes,
      start: new Date(data.start),
      end: new Date(data.end),
      allDay: data.allDay ?? false,
      type: data.type ?? "OTHER",
      color: data.color,
      trackId: data.trackId ?? null,
    },
  });
  revalidatePath("/week");
  revalidatePath("/day");
  return event;
}

const eventUpdate = eventInput.partial().extend({ id: z.string() });

export async function updateEvent(input: z.infer<typeof eventUpdate>) {
  const userId = await requireUserId();
  const { id, ...rest } = eventUpdate.parse(input);
  // ownership check
  const existing = await prisma.calEvent.findFirst({ where: { id, userId } });
  if (!existing) throw new Error("Event not found");
  const event = await prisma.calEvent.update({
    where: { id },
    data: {
      ...(rest.title !== undefined ? { title: rest.title } : {}),
      ...(rest.notes !== undefined ? { notes: rest.notes } : {}),
      ...(rest.start !== undefined ? { start: new Date(rest.start) } : {}),
      ...(rest.end !== undefined ? { end: new Date(rest.end) } : {}),
      ...(rest.allDay !== undefined ? { allDay: rest.allDay } : {}),
      ...(rest.type !== undefined ? { type: rest.type } : {}),
      ...(rest.color !== undefined ? { color: rest.color } : {}),
      ...(rest.trackId !== undefined ? { trackId: rest.trackId } : {}),
    },
  });
  revalidatePath("/week");
  revalidatePath("/day");
  return event;
}

export async function deleteEvent(id: string) {
  const userId = await requireUserId();
  const existing = await prisma.calEvent.findFirst({ where: { id, userId } });
  if (!existing) throw new Error("Event not found");
  await prisma.calEvent.delete({ where: { id } });
  revalidatePath("/week");
  revalidatePath("/day");
}
