"use server";

import { z } from "zod";
import { revalidatePath } from "next/cache";
import { prisma } from "@/lib/prisma";
import { requireUserId } from "@/lib/auth";
import { DEADLINE_KINDS } from "@/lib/enums";

const deadlineInput = z.object({
  venue: z.string().min(1).max(160),
  kind: z.enum(DEADLINE_KINDS),
  dueAt: z.string().datetime({ offset: true }),
  url: z.string().url().optional().or(z.literal("")),
  trackId: z.string().optional().nullable(),
  watched: z.boolean().optional(),
  notes: z.string().max(2000).optional(),
});

export async function listDeadlines() {
  const userId = await requireUserId();
  return prisma.deadline.findMany({
    where: { userId },
    orderBy: { dueAt: "asc" },
  });
}

export async function createDeadline(input: z.infer<typeof deadlineInput>) {
  const userId = await requireUserId();
  const d = deadlineInput.parse(input);
  await prisma.deadline.create({
    data: {
      userId,
      venue: d.venue,
      kind: d.kind,
      dueAt: new Date(d.dueAt),
      url: d.url || null,
      trackId: d.trackId || null,
      watched: d.watched ?? true,
      notes: d.notes || null,
    },
  });
  revalidatePath("/deadlines");
}

export async function toggleWatched(id: string, watched: boolean) {
  const userId = await requireUserId();
  const existing = await prisma.deadline.findFirst({ where: { id, userId } });
  if (!existing) throw new Error("Deadline not found");
  await prisma.deadline.update({ where: { id }, data: { watched } });
  revalidatePath("/deadlines");
}

export async function deleteDeadline(id: string) {
  const userId = await requireUserId();
  const existing = await prisma.deadline.findFirst({ where: { id, userId } });
  if (!existing) throw new Error("Deadline not found");
  await prisma.deadline.delete({ where: { id } });
  revalidatePath("/deadlines");
}
