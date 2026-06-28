// Persistent agent memory (design §16.2): durable, per-user facts the assistant learns —
// color/tag conventions, preferred timezones, soft contacts. Auto-recalled into the actor's
// system prompt each turn; written via the `remember` tool. Backed by the AssistantMemory table.

import { prisma } from "@/lib/prisma";
import { Prisma } from "@/generated/prisma/client";

/** All remembered facts for a user, as a { key: value } map (most-recent first, capped). */
export async function recallAll(userId: string): Promise<Record<string, unknown>> {
  const rows = await prisma.assistantMemory.findMany({
    where: { userId },
    orderBy: { updatedAt: "desc" },
    take: 100,
  });
  return Object.fromEntries(rows.map((r) => [r.key, r.value]));
}

/** Upsert one remembered fact. */
export async function remember(userId: string, key: string, value: unknown): Promise<void> {
  await prisma.assistantMemory.upsert({
    where: { userId_key: { userId, key } },
    create: { userId, key, value: value as Prisma.InputJsonValue },
    update: { value: value as Prisma.InputJsonValue },
  });
}
