"use server";

import { z } from "zod";
import { revalidatePath } from "next/cache";
import { prisma } from "@/lib/prisma";
import { requireUserId } from "@/lib/auth";
import { PROPOSAL_STATUSES, PROPOSAL_ROLES } from "@/lib/enums";

const proposalInput = z.object({
  title: z.string().min(1).max(300),
  agency: z.string().max(160).optional(),
  program: z.string().max(160).optional(),
  role: z.enum(PROPOSAL_ROLES).optional().nullable(),
  status: z.enum(PROPOSAL_STATUSES).optional(),
  amount: z.number().nonnegative().optional().nullable(),
  submittedAt: z.string().datetime({ offset: true }).optional().nullable(),
  projectId: z.string().optional().nullable(),
});

export async function listProposals() {
  const userId = await requireUserId();
  return prisma.proposal.findMany({
    where: { userId },
    orderBy: [{ submittedAt: "desc" }, { updatedAt: "desc" }],
    include: { project: { select: { id: true, title: true } } },
  });
}

export async function createProposal(input: z.infer<typeof proposalInput>) {
  const userId = await requireUserId();
  const d = proposalInput.parse(input);
  const proposal = await prisma.proposal.create({
    data: {
      userId,
      title: d.title,
      agency: d.agency || null,
      program: d.program || null,
      role: d.role ?? null,
      status: d.status ?? "DRAFTING",
      amount: d.amount ?? null,
      submittedAt: d.submittedAt ? new Date(d.submittedAt) : null,
      projectId: d.projectId || null,
    },
  });
  revalidatePath("/proposals");
  return proposal;
}

const proposalUpdate = proposalInput.partial().extend({ id: z.string() });

export async function updateProposal(input: z.infer<typeof proposalUpdate>) {
  const userId = await requireUserId();
  const { id, ...r } = proposalUpdate.parse(input);
  const existing = await prisma.proposal.findFirst({ where: { id, userId } });
  if (!existing) throw new Error("Proposal not found");
  const proposal = await prisma.proposal.update({
    where: { id },
    data: {
      ...(r.title !== undefined ? { title: r.title } : {}),
      ...(r.agency !== undefined ? { agency: r.agency || null } : {}),
      ...(r.program !== undefined ? { program: r.program || null } : {}),
      ...(r.role !== undefined ? { role: r.role ?? null } : {}),
      ...(r.status !== undefined ? { status: r.status } : {}),
      ...(r.amount !== undefined ? { amount: r.amount ?? null } : {}),
      ...(r.submittedAt !== undefined ? { submittedAt: r.submittedAt ? new Date(r.submittedAt) : null } : {}),
      ...(r.projectId !== undefined ? { projectId: r.projectId || null } : {}),
    },
  });
  revalidatePath("/proposals");
  return proposal;
}

export async function deleteProposal(id: string) {
  const userId = await requireUserId();
  const existing = await prisma.proposal.findFirst({ where: { id, userId } });
  if (!existing) throw new Error("Proposal not found");
  await prisma.proposal.delete({ where: { id } });
  revalidatePath("/proposals");
}
