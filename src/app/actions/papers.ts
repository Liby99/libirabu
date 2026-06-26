"use server";

import { z } from "zod";
import { revalidatePath } from "next/cache";
import { prisma } from "@/lib/prisma";
import { requireUserId } from "@/lib/auth";
import { PAPER_STATUSES } from "@/lib/enums";

const url = z.string().url().optional().or(z.literal(""));

const paperInput = z.object({
  title: z.string().min(1).max(300),
  venue: z.string().max(160).optional(),
  year: z.number().int().min(1900).max(2100).optional().nullable(),
  status: z.enum(PAPER_STATUSES).optional(),
  overleafUrl: url,
  githubUrl: url,
  arxivUrl: url,
  doi: z.string().max(120).optional(),
  abstract: z.string().max(8000).optional(),
  projectId: z.string().optional().nullable(),
});

export async function listPapers() {
  const userId = await requireUserId();
  return prisma.paper.findMany({
    where: { userId },
    orderBy: [{ year: "desc" }, { updatedAt: "desc" }],
    include: {
      project: { select: { id: true, title: true } },
      authors: {
        orderBy: { order: "asc" },
        include: { person: { select: { id: true, name: true } } },
      },
    },
  });
}

export async function getPaper(id: string) {
  const userId = await requireUserId();
  return prisma.paper.findFirst({
    where: { id, userId },
    include: {
      authors: { orderBy: { order: "asc" }, include: { person: { select: { id: true, name: true } } } },
    },
  });
}

export async function createPaper(input: z.infer<typeof paperInput>) {
  const userId = await requireUserId();
  const d = paperInput.parse(input);
  const paper = await prisma.paper.create({
    data: {
      userId,
      title: d.title,
      venue: d.venue || null,
      year: d.year ?? null,
      status: d.status ?? "IN_PREP",
      overleafUrl: d.overleafUrl || null,
      githubUrl: d.githubUrl || null,
      arxivUrl: d.arxivUrl || null,
      doi: d.doi || null,
      abstract: d.abstract || null,
      projectId: d.projectId || null,
    },
  });
  revalidatePath("/papers");
  return paper;
}

const paperUpdate = paperInput.partial().extend({ id: z.string() });

export async function updatePaper(input: z.infer<typeof paperUpdate>) {
  const userId = await requireUserId();
  const { id, ...r } = paperUpdate.parse(input);
  const existing = await prisma.paper.findFirst({ where: { id, userId } });
  if (!existing) throw new Error("Paper not found");
  const paper = await prisma.paper.update({
    where: { id },
    data: {
      ...(r.title !== undefined ? { title: r.title } : {}),
      ...(r.venue !== undefined ? { venue: r.venue || null } : {}),
      ...(r.year !== undefined ? { year: r.year ?? null } : {}),
      ...(r.status !== undefined ? { status: r.status } : {}),
      ...(r.overleafUrl !== undefined ? { overleafUrl: r.overleafUrl || null } : {}),
      ...(r.githubUrl !== undefined ? { githubUrl: r.githubUrl || null } : {}),
      ...(r.arxivUrl !== undefined ? { arxivUrl: r.arxivUrl || null } : {}),
      ...(r.doi !== undefined ? { doi: r.doi || null } : {}),
      ...(r.abstract !== undefined ? { abstract: r.abstract || null } : {}),
      ...(r.projectId !== undefined ? { projectId: r.projectId || null } : {}),
    },
  });
  revalidatePath("/papers");
  revalidatePath(`/papers/${id}`);
  return paper;
}

export async function deletePaper(id: string) {
  const userId = await requireUserId();
  const existing = await prisma.paper.findFirst({ where: { id, userId } });
  if (!existing) throw new Error("Paper not found");
  await prisma.paper.delete({ where: { id } });
  revalidatePath("/papers");
}

// ── Authors ───────────────────────────────────────────────────────────
export async function addAuthor(paperId: string, personId: string, isCorresponding = false) {
  const userId = await requireUserId();
  const [paper, person] = await Promise.all([
    prisma.paper.findFirst({ where: { id: paperId, userId } }),
    prisma.person.findFirst({ where: { id: personId, userId } }),
  ]);
  if (!paper || !person) throw new Error("Paper or person not found");
  const count = await prisma.paperAuthor.count({ where: { paperId } });
  await prisma.paperAuthor.upsert({
    where: { paperId_personId: { paperId, personId } },
    create: { paperId, personId, order: count, isCorresponding },
    update: { isCorresponding },
  });
  revalidatePath(`/papers/${paperId}`);
}

export async function removeAuthor(paperId: string, personId: string) {
  const userId = await requireUserId();
  const paper = await prisma.paper.findFirst({ where: { id: paperId, userId } });
  if (!paper) throw new Error("Paper not found");
  await prisma.paperAuthor.delete({ where: { paperId_personId: { paperId, personId } } });
  revalidatePath(`/papers/${paperId}`);
}
