"use server";

import { z } from "zod";
import { revalidatePath } from "next/cache";
import { prisma } from "@/lib/prisma";
import { requireUserId } from "@/lib/auth";
import { encrypt, decryptToString, last4 } from "@/lib/crypto";
import { APIKEY_STATUSES } from "@/lib/enums";

// DESIGN §7: prefer metadata-only. The full secret is OPTIONAL; when provided it is
// AES-GCM encrypted at rest and only ever returned via the gated revealApiKey action,
// which records the access in ActionLog.

const apiKeyInput = z.object({
  label: z.string().min(1).max(120),
  provider: z.string().min(1).max(80),
  secret: z.string().max(400).optional(), // optional full secret
  last4: z.string().max(8).optional(), // used when no secret stored
  purpose: z.string().max(200).optional(),
  environment: z.string().max(40).optional(),
  status: z.enum(APIKEY_STATUSES).optional(),
  issuedToPersonId: z.string().optional().nullable(),
  issuedToLabel: z.string().max(120).optional(),
  expiresAt: z.string().datetime({ offset: true }).optional().nullable(),
});

export async function listApiKeys() {
  const userId = await requireUserId();
  const keys = await prisma.apiKey.findMany({
    where: { userId },
    orderBy: [{ status: "asc" }, { provider: "asc" }],
  });
  // never return valueEnc to the client; expose only whether a secret is stored
  return keys.map((k) => ({
    id: k.id,
    label: k.label,
    provider: k.provider,
    last4: k.last4,
    hasSecret: k.valueEnc != null,
    purpose: k.purpose,
    environment: k.environment,
    status: k.status,
    issuedToPersonId: k.issuedToPersonId,
    issuedToLabel: k.issuedToLabel,
    expiresAt: k.expiresAt ? k.expiresAt.toISOString() : null,
  }));
}

export async function createApiKey(input: z.infer<typeof apiKeyInput>) {
  const userId = await requireUserId();
  const d = apiKeyInput.parse(input);
  const valueEnc = d.secret ? encrypt(d.secret) : null;
  const derivedLast4 = d.secret ? last4(d.secret) : d.last4 || null;
  await prisma.apiKey.create({
    data: {
      userId,
      label: d.label,
      provider: d.provider,
      valueEnc,
      last4: derivedLast4,
      purpose: d.purpose || null,
      environment: d.environment || null,
      status: d.status ?? "ACTIVE",
      issuedToPersonId: d.issuedToPersonId || null,
      issuedToLabel: d.issuedToLabel || null,
      expiresAt: d.expiresAt ? new Date(d.expiresAt) : null,
    },
  });
  revalidatePath("/keys");
}

const apiKeyUpdate = apiKeyInput.partial().extend({ id: z.string() });

export async function updateApiKey(input: z.infer<typeof apiKeyUpdate>) {
  const userId = await requireUserId();
  const { id, ...r } = apiKeyUpdate.parse(input);
  const existing = await prisma.apiKey.findFirst({ where: { id, userId } });
  if (!existing) throw new Error("API key not found");
  await prisma.apiKey.update({
    where: { id },
    data: {
      ...(r.label !== undefined ? { label: r.label } : {}),
      ...(r.provider !== undefined ? { provider: r.provider } : {}),
      ...(r.purpose !== undefined ? { purpose: r.purpose || null } : {}),
      ...(r.environment !== undefined ? { environment: r.environment || null } : {}),
      ...(r.status !== undefined ? { status: r.status } : {}),
      ...(r.issuedToPersonId !== undefined ? { issuedToPersonId: r.issuedToPersonId || null } : {}),
      ...(r.issuedToLabel !== undefined ? { issuedToLabel: r.issuedToLabel || null } : {}),
      ...(r.expiresAt !== undefined ? { expiresAt: r.expiresAt ? new Date(r.expiresAt) : null } : {}),
      ...(r.secret !== undefined
        ? { valueEnc: r.secret ? encrypt(r.secret) : null, last4: r.secret ? last4(r.secret) : existing.last4 }
        : {}),
    },
  });
  revalidatePath("/keys");
}

export async function deleteApiKey(id: string) {
  const userId = await requireUserId();
  const existing = await prisma.apiKey.findFirst({ where: { id, userId } });
  if (!existing) throw new Error("API key not found");
  await prisma.apiKey.delete({ where: { id } });
  revalidatePath("/keys");
}

/** Gated reveal of a stored secret. Logged to ActionLog. */
export async function revealApiKey(id: string): Promise<string> {
  const userId = await requireUserId();
  const key = await prisma.apiKey.findFirst({ where: { id, userId } });
  if (!key) throw new Error("API key not found");
  if (!key.valueEnc) throw new Error("No secret stored for this key");
  await prisma.actionLog.create({
    data: { userId, actor: "USER", kind: "reveal_api_key", payload: { apiKeyId: id }, status: "APPLIED" },
  });
  return decryptToString(Buffer.from(key.valueEnc));
}
