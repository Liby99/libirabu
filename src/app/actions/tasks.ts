"use server";

import { z } from "zod";
import { revalidatePath } from "next/cache";
import { prisma } from "@/lib/prisma";
import { requireUserId } from "@/lib/auth";
import { TASK_STATUSES } from "@/lib/enums";

const taskInput = z.object({
  title: z.string().min(1).max(300),
  notes: z.string().max(4000).optional(),
  status: z.enum(TASK_STATUSES).optional(),
  priority: z.number().int().optional(),
  dueAt: z.string().datetime({ offset: true }).optional().nullable(),
  projectId: z.string().optional().nullable(),
});

export async function listTasks(opts?: { projectId?: string }) {
  const userId = await requireUserId();
  return prisma.task.findMany({
    where: { userId, ...(opts?.projectId ? { projectId: opts.projectId } : {}) },
    orderBy: [{ status: "asc" }, { priority: "desc" }, { dueAt: "asc" }],
    include: { project: { select: { id: true, title: true } } },
  });
}

export async function createTask(input: z.infer<typeof taskInput>) {
  const userId = await requireUserId();
  const data = taskInput.parse(input);
  const task = await prisma.task.create({
    data: {
      userId,
      title: data.title,
      notes: data.notes || null,
      status: data.status ?? "TODO",
      priority: data.priority ?? 0,
      dueAt: data.dueAt ? new Date(data.dueAt) : null,
      projectId: data.projectId || null,
    },
  });
  revalidatePath("/tasks");
  if (task.projectId) revalidatePath(`/projects/${task.projectId}`);
  return task;
}

const taskUpdate = taskInput.partial().extend({ id: z.string() });

export async function updateTask(input: z.infer<typeof taskUpdate>) {
  const userId = await requireUserId();
  const { id, ...rest } = taskUpdate.parse(input);
  const existing = await prisma.task.findFirst({ where: { id, userId } });
  if (!existing) throw new Error("Task not found");
  const task = await prisma.task.update({
    where: { id },
    data: {
      ...(rest.title !== undefined ? { title: rest.title } : {}),
      ...(rest.notes !== undefined ? { notes: rest.notes || null } : {}),
      ...(rest.status !== undefined ? { status: rest.status } : {}),
      ...(rest.priority !== undefined ? { priority: rest.priority } : {}),
      ...(rest.dueAt !== undefined ? { dueAt: rest.dueAt ? new Date(rest.dueAt) : null } : {}),
      ...(rest.projectId !== undefined ? { projectId: rest.projectId || null } : {}),
    },
  });
  revalidatePath("/tasks");
  if (existing.projectId) revalidatePath(`/projects/${existing.projectId}`);
  if (task.projectId) revalidatePath(`/projects/${task.projectId}`);
  return task;
}

export async function deleteTask(id: string) {
  const userId = await requireUserId();
  const existing = await prisma.task.findFirst({ where: { id, userId } });
  if (!existing) throw new Error("Task not found");
  await prisma.task.delete({ where: { id } });
  revalidatePath("/tasks");
  if (existing.projectId) revalidatePath(`/projects/${existing.projectId}`);
}
