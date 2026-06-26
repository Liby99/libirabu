"use server";

import { z } from "zod";
import { revalidatePath } from "next/cache";
import { prisma } from "@/lib/prisma";
import { requireUserId } from "@/lib/auth";
import { PROJECT_STATUSES } from "@/lib/enums";

const projectInput = z.object({
  title: z.string().min(1).max(200),
  description: z.string().max(4000).optional(),
  status: z.enum(PROJECT_STATUSES).optional(),
  priority: z.number().int().optional(),
  trackId: z.string().optional().nullable(),
});

export async function listProjects() {
  const userId = await requireUserId();
  return prisma.project.findMany({
    where: { userId },
    orderBy: [{ priority: "desc" }, { updatedAt: "desc" }],
    include: {
      _count: { select: { tasks: true, people: true, papers: true } },
    },
  });
}

export async function getProject(id: string) {
  const userId = await requireUserId();
  return prisma.project.findFirst({
    where: { id, userId },
    include: {
      people: { include: { person: { select: { id: true, name: true, role: true } } } },
      tasks: { orderBy: [{ status: "asc" }, { priority: "desc" }] },
      papers: { select: { id: true, title: true, status: true } },
      proposals: { select: { id: true, title: true, status: true } },
    },
  });
}

export async function createProject(input: z.infer<typeof projectInput>) {
  const userId = await requireUserId();
  const data = projectInput.parse(input);
  const project = await prisma.project.create({
    data: {
      userId,
      title: data.title,
      description: data.description || null,
      status: data.status ?? "ACTIVE",
      priority: data.priority ?? 0,
      trackId: data.trackId || null,
    },
  });
  revalidatePath("/projects");
  return project;
}

const projectUpdate = projectInput.partial().extend({ id: z.string() });

export async function updateProject(input: z.infer<typeof projectUpdate>) {
  const userId = await requireUserId();
  const { id, ...rest } = projectUpdate.parse(input);
  const existing = await prisma.project.findFirst({ where: { id, userId } });
  if (!existing) throw new Error("Project not found");
  const project = await prisma.project.update({
    where: { id },
    data: {
      ...(rest.title !== undefined ? { title: rest.title } : {}),
      ...(rest.description !== undefined ? { description: rest.description || null } : {}),
      ...(rest.status !== undefined ? { status: rest.status } : {}),
      ...(rest.priority !== undefined ? { priority: rest.priority } : {}),
      ...(rest.trackId !== undefined ? { trackId: rest.trackId || null } : {}),
    },
  });
  revalidatePath("/projects");
  revalidatePath(`/projects/${id}`);
  return project;
}

export async function deleteProject(id: string) {
  const userId = await requireUserId();
  const existing = await prisma.project.findFirst({ where: { id, userId } });
  if (!existing) throw new Error("Project not found");
  await prisma.project.delete({ where: { id } });
  revalidatePath("/projects");
}

// ── Project ↔ Person links ────────────────────────────────────────────
export async function addPersonToProject(
  projectId: string,
  personId: string,
  role = "COLLABORATOR",
) {
  const userId = await requireUserId();
  const [project, person] = await Promise.all([
    prisma.project.findFirst({ where: { id: projectId, userId } }),
    prisma.person.findFirst({ where: { id: personId, userId } }),
  ]);
  if (!project || !person) throw new Error("Project or person not found");
  await prisma.projectPerson.upsert({
    where: { projectId_personId: { projectId, personId } },
    create: { projectId, personId, role },
    update: { role },
  });
  revalidatePath(`/projects/${projectId}`);
}

export async function removePersonFromProject(projectId: string, personId: string) {
  const userId = await requireUserId();
  const project = await prisma.project.findFirst({ where: { id: projectId, userId } });
  if (!project) throw new Error("Project not found");
  await prisma.projectPerson.delete({
    where: { projectId_personId: { projectId, personId } },
  });
  revalidatePath(`/projects/${projectId}`);
}
