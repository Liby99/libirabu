"use server";

import { z } from "zod";
import { revalidatePath } from "next/cache";
import { prisma } from "@/lib/prisma";
import { requireUserId } from "@/lib/auth";
import { SUBSCRIPTION_CYCLES } from "@/lib/enums";

// ── Funding sources (grants / gifts / discretionary pools) ─────────────
const sourceInput = z.object({
  name: z.string().min(1).max(200),
  agency: z.string().max(160).optional(),
  awardNumber: z.string().max(120).optional(),
  amount: z.number().nonnegative().optional().nullable(),
  startDate: z.string().datetime({ offset: true }).optional().nullable(),
  endDate: z.string().datetime({ offset: true }).optional().nullable(),
  proposalId: z.string().optional().nullable(),
});

export async function listFundingSources() {
  const userId = await requireUserId();
  return prisma.fundingSource.findMany({
    where: { userId },
    orderBy: { createdAt: "desc" },
    include: {
      expenses: { select: { amount: true } },
      _count: { select: { subscriptions: true, trips: true } },
    },
  });
}

export async function createFundingSource(input: z.infer<typeof sourceInput>) {
  const userId = await requireUserId();
  const d = sourceInput.parse(input);
  await prisma.fundingSource.create({
    data: {
      userId,
      name: d.name,
      agency: d.agency || null,
      awardNumber: d.awardNumber || null,
      amount: d.amount ?? null,
      startDate: d.startDate ? new Date(d.startDate) : null,
      endDate: d.endDate ? new Date(d.endDate) : null,
      proposalId: d.proposalId || null,
    },
  });
  revalidatePath("/funding");
}

const sourceUpdate = sourceInput.partial().extend({ id: z.string() });

export async function updateFundingSource(input: z.infer<typeof sourceUpdate>) {
  const userId = await requireUserId();
  const { id, ...r } = sourceUpdate.parse(input);
  const existing = await prisma.fundingSource.findFirst({ where: { id, userId } });
  if (!existing) throw new Error("Funding source not found");
  await prisma.fundingSource.update({
    where: { id },
    data: {
      ...(r.name !== undefined ? { name: r.name } : {}),
      ...(r.agency !== undefined ? { agency: r.agency || null } : {}),
      ...(r.awardNumber !== undefined ? { awardNumber: r.awardNumber || null } : {}),
      ...(r.amount !== undefined ? { amount: r.amount ?? null } : {}),
      ...(r.startDate !== undefined ? { startDate: r.startDate ? new Date(r.startDate) : null } : {}),
      ...(r.endDate !== undefined ? { endDate: r.endDate ? new Date(r.endDate) : null } : {}),
      ...(r.proposalId !== undefined ? { proposalId: r.proposalId || null } : {}),
    },
  });
  revalidatePath("/funding");
}

export async function deleteFundingSource(id: string) {
  const userId = await requireUserId();
  const existing = await prisma.fundingSource.findFirst({ where: { id, userId } });
  if (!existing) throw new Error("Funding source not found");
  await prisma.fundingSource.delete({ where: { id } });
  revalidatePath("/funding");
}

// ── Subscriptions ──────────────────────────────────────────────────────
const subInput = z.object({
  name: z.string().min(1).max(160),
  vendor: z.string().min(1).max(160),
  cost: z.number().nonnegative(),
  cycle: z.enum(SUBSCRIPTION_CYCLES),
  renewalDate: z.string().datetime({ offset: true }).optional().nullable(),
  status: z.enum(["ACTIVE", "CANCELLED"]).optional(),
  fundingSourceId: z.string().optional().nullable(),
  apiKeyId: z.string().optional().nullable(),
});

export async function listSubscriptions() {
  const userId = await requireUserId();
  return prisma.subscription.findMany({
    where: { userId },
    orderBy: [{ status: "asc" }, { renewalDate: "asc" }],
    include: { fundingSource: { select: { id: true, name: true } } },
  });
}

export async function createSubscription(input: z.infer<typeof subInput>) {
  const userId = await requireUserId();
  const d = subInput.parse(input);
  await prisma.subscription.create({
    data: {
      userId,
      name: d.name,
      vendor: d.vendor,
      cost: d.cost,
      cycle: d.cycle,
      renewalDate: d.renewalDate ? new Date(d.renewalDate) : null,
      status: d.status ?? "ACTIVE",
      fundingSourceId: d.fundingSourceId || null,
      apiKeyId: d.apiKeyId || null,
    },
  });
  revalidatePath("/funding");
}

const subUpdate = subInput.partial().extend({ id: z.string() });

export async function updateSubscription(input: z.infer<typeof subUpdate>) {
  const userId = await requireUserId();
  const { id, ...r } = subUpdate.parse(input);
  const existing = await prisma.subscription.findFirst({ where: { id, userId } });
  if (!existing) throw new Error("Subscription not found");
  await prisma.subscription.update({
    where: { id },
    data: {
      ...(r.name !== undefined ? { name: r.name } : {}),
      ...(r.vendor !== undefined ? { vendor: r.vendor } : {}),
      ...(r.cost !== undefined ? { cost: r.cost } : {}),
      ...(r.cycle !== undefined ? { cycle: r.cycle } : {}),
      ...(r.renewalDate !== undefined ? { renewalDate: r.renewalDate ? new Date(r.renewalDate) : null } : {}),
      ...(r.status !== undefined ? { status: r.status } : {}),
      ...(r.fundingSourceId !== undefined ? { fundingSourceId: r.fundingSourceId || null } : {}),
      ...(r.apiKeyId !== undefined ? { apiKeyId: r.apiKeyId || null } : {}),
    },
  });
  revalidatePath("/funding");
}

export async function deleteSubscription(id: string) {
  const userId = await requireUserId();
  const existing = await prisma.subscription.findFirst({ where: { id, userId } });
  if (!existing) throw new Error("Subscription not found");
  await prisma.subscription.delete({ where: { id } });
  revalidatePath("/funding");
}
