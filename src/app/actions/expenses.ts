"use server";

import { z } from "zod";
import { revalidatePath } from "next/cache";
import { prisma } from "@/lib/prisma";
import { requireUserId } from "@/lib/auth";
import { saveFile, deleteFile } from "@/lib/storage";
import { EXPENSE_STATUSES, EXPENSE_CATEGORIES } from "@/lib/enums";

const expenseInput = z.object({
  description: z.string().min(1).max(300),
  amount: z.number().nonnegative(),
  category: z.enum(EXPENSE_CATEGORIES),
  date: z.string().datetime({ offset: true }),
  status: z.enum(EXPENSE_STATUSES).optional(),
  personId: z.string().optional().nullable(),
  fundingSourceId: z.string().optional().nullable(),
  tripId: z.string().optional().nullable(),
});

export async function listExpenses() {
  const userId = await requireUserId();
  return prisma.expense.findMany({
    where: { userId },
    orderBy: { date: "desc" },
    include: {
      fundingSource: { select: { id: true, name: true } },
      trip: { select: { id: true, title: true } },
      attachments: { select: { id: true, filename: true } },
    },
  });
}

export async function createExpense(input: z.infer<typeof expenseInput>) {
  const userId = await requireUserId();
  const d = expenseInput.parse(input);
  await prisma.expense.create({
    data: {
      userId,
      description: d.description,
      amount: d.amount,
      category: d.category,
      date: new Date(d.date),
      status: d.status ?? "PLANNED",
      personId: d.personId || null,
      fundingSourceId: d.fundingSourceId || null,
      tripId: d.tripId || null,
    },
  });
  revalidatePath("/funding");
}

const expenseUpdate = expenseInput.partial().extend({ id: z.string() });

export async function updateExpense(input: z.infer<typeof expenseUpdate>) {
  const userId = await requireUserId();
  const { id, ...r } = expenseUpdate.parse(input);
  const existing = await prisma.expense.findFirst({ where: { id, userId } });
  if (!existing) throw new Error("Expense not found");
  await prisma.expense.update({
    where: { id },
    data: {
      ...(r.description !== undefined ? { description: r.description } : {}),
      ...(r.amount !== undefined ? { amount: r.amount } : {}),
      ...(r.category !== undefined ? { category: r.category } : {}),
      ...(r.date !== undefined ? { date: new Date(r.date) } : {}),
      ...(r.status !== undefined ? { status: r.status } : {}),
      ...(r.personId !== undefined ? { personId: r.personId || null } : {}),
      ...(r.fundingSourceId !== undefined ? { fundingSourceId: r.fundingSourceId || null } : {}),
      ...(r.tripId !== undefined ? { tripId: r.tripId || null } : {}),
    },
  });
  revalidatePath("/funding");
}

export async function deleteExpense(id: string) {
  const userId = await requireUserId();
  const existing = await prisma.expense.findFirst({ where: { id, userId }, include: { attachments: true } });
  if (!existing) throw new Error("Expense not found");
  for (const a of existing.attachments) await deleteFile(a.storagePath);
  await prisma.expense.delete({ where: { id } }); // cascade removes Attachment rows
  revalidatePath("/funding");
}

/** Upload a receipt/invoice for an expense (FormData: expenseId, file). Encrypted at rest. */
export async function uploadReceipt(formData: FormData) {
  const userId = await requireUserId();
  const expenseId = String(formData.get("expenseId") || "");
  const file = formData.get("file");
  if (!(file instanceof File)) throw new Error("No file provided");
  const expense = await prisma.expense.findFirst({ where: { id: expenseId, userId } });
  if (!expense) throw new Error("Expense not found");
  const bytes = new Uint8Array(await file.arrayBuffer());
  if (bytes.byteLength === 0) throw new Error("Empty file");
  if (bytes.byteLength > 25 * 1024 * 1024) throw new Error("File too large (max 25MB)");
  const stored = await saveFile(bytes, { encrypt: true });
  await prisma.attachment.create({
    data: {
      userId,
      filename: file.name || "receipt",
      mime: file.type || "application/octet-stream",
      bytes: stored.bytes,
      sha256: stored.sha256,
      storagePath: stored.storagePath,
      encrypted: stored.encrypted,
      expenseId,
    },
  });
  revalidatePath("/funding");
}

export async function deleteAttachment(id: string) {
  const userId = await requireUserId();
  const att = await prisma.attachment.findFirst({ where: { id, userId } });
  if (!att) throw new Error("Attachment not found");
  await deleteFile(att.storagePath);
  await prisma.attachment.delete({ where: { id } });
  revalidatePath("/funding");
}
