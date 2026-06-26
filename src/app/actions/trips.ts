"use server";

import { z } from "zod";
import { revalidatePath } from "next/cache";
import { prisma } from "@/lib/prisma";
import { requireUserId } from "@/lib/auth";
import { TRIP_PURPOSES } from "@/lib/enums";

const tripInput = z.object({
  title: z.string().min(1).max(200),
  destination: z.string().min(1).max(200),
  purpose: z.enum(TRIP_PURPOSES),
  start: z.string().datetime({ offset: true }),
  end: z.string().datetime({ offset: true }),
  estCost: z.number().nonnegative().optional().nullable(),
  actualCost: z.number().nonnegative().optional().nullable(),
  travelerPersonId: z.string().optional().nullable(),
  projectId: z.string().optional().nullable(),
  fundingSourceId: z.string().optional().nullable(),
});

export async function listTrips() {
  const userId = await requireUserId();
  return prisma.trip.findMany({
    where: { userId },
    orderBy: { start: "desc" },
    include: {
      fundingSource: { select: { id: true, name: true } },
      expenses: { select: { amount: true } },
    },
  });
}

export async function createTrip(input: z.infer<typeof tripInput>) {
  const userId = await requireUserId();
  const d = tripInput.parse(input);
  if (new Date(d.end) < new Date(d.start)) throw new Error("Trip end must be on or after start");
  await prisma.trip.create({
    data: {
      userId,
      title: d.title,
      destination: d.destination,
      purpose: d.purpose,
      start: new Date(d.start),
      end: new Date(d.end),
      estCost: d.estCost ?? null,
      actualCost: d.actualCost ?? null,
      travelerPersonId: d.travelerPersonId || null,
      projectId: d.projectId || null,
      fundingSourceId: d.fundingSourceId || null,
    },
  });
  revalidatePath("/travel");
}

const tripUpdate = tripInput.partial().extend({ id: z.string() });

export async function updateTrip(input: z.infer<typeof tripUpdate>) {
  const userId = await requireUserId();
  const { id, ...r } = tripUpdate.parse(input);
  const existing = await prisma.trip.findFirst({ where: { id, userId } });
  if (!existing) throw new Error("Trip not found");
  await prisma.trip.update({
    where: { id },
    data: {
      ...(r.title !== undefined ? { title: r.title } : {}),
      ...(r.destination !== undefined ? { destination: r.destination } : {}),
      ...(r.purpose !== undefined ? { purpose: r.purpose } : {}),
      ...(r.start !== undefined ? { start: new Date(r.start) } : {}),
      ...(r.end !== undefined ? { end: new Date(r.end) } : {}),
      ...(r.estCost !== undefined ? { estCost: r.estCost ?? null } : {}),
      ...(r.actualCost !== undefined ? { actualCost: r.actualCost ?? null } : {}),
      ...(r.travelerPersonId !== undefined ? { travelerPersonId: r.travelerPersonId || null } : {}),
      ...(r.projectId !== undefined ? { projectId: r.projectId || null } : {}),
      ...(r.fundingSourceId !== undefined ? { fundingSourceId: r.fundingSourceId || null } : {}),
    },
  });
  revalidatePath("/travel");
}

export async function deleteTrip(id: string) {
  const userId = await requireUserId();
  const existing = await prisma.trip.findFirst({ where: { id, userId } });
  if (!existing) throw new Error("Trip not found");
  await prisma.trip.delete({ where: { id } });
  revalidatePath("/travel");
}
