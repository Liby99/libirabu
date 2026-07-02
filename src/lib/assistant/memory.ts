// Persistent agent memory (design §16.2): durable, per-user facts the assistant learns —
// color/tag conventions, preferred timezones, soft contacts. Auto-recalled into the actor's
// system prompt each turn; written via the `remember` tool. Backed by the AssistantMemory table.

import { prisma } from "@/lib/prisma";
import { Prisma } from "@/generated/prisma/client";

/** All remembered facts for a user, as a { key: value } map (most-recent first, capped). */
export async function recallAll(userId: string): Promise<Record<string, unknown>> {
  const rows = await prisma.assistantMemory.findMany({
    where: { userId, NOT: { key: { startsWith: "assistant." } } }, // hide internal settings from the prompt
    orderBy: { updatedAt: "desc" },
    take: 100,
  });
  return Object.fromEntries(rows.map((r) => [r.key, r.value]));
}

/** The user's selected assistant model id (AssistantMemory key "assistant.model"), or undefined. */
export async function getSelectedModel(userId: string): Promise<string | undefined> {
  const row = await prisma.assistantMemory.findUnique({ where: { userId_key: { userId, key: "assistant.model" } } });
  return typeof row?.value === "string" ? row.value : undefined;
}

/** Upsert one remembered fact. */
export async function remember(userId: string, key: string, value: unknown): Promise<void> {
  await prisma.assistantMemory.upsert({
    where: { userId_key: { userId, key } },
    create: { userId, key, value: value as Prisma.InputJsonValue },
    update: { value: value as Prisma.InputJsonValue },
  });
}

/** Delete one remembered fact (the assistant's `forget` tool + the user's Memory browser). */
export async function forget(userId: string, key: string): Promise<void> {
  await prisma.assistantMemory.deleteMany({ where: { userId, key } });
}

export interface MemoryEntry { key: string; value: unknown; updatedAt: string }

/** Browsable facts for the Memory UI — excludes internal `assistant.*` settings (e.g. the model pick). */
export async function listMemories(userId: string): Promise<MemoryEntry[]> {
  const rows = await prisma.assistantMemory.findMany({
    where: { userId, NOT: { key: { startsWith: "assistant." } } },
    orderBy: { updatedAt: "desc" },
    take: 300,
  });
  return rows.map((r) => ({ key: r.key, value: r.value, updatedAt: r.updatedAt.toISOString() }));
}
