// Account → API Keys: manage the signed-in user's per-service credentials for the AI assistant and
// web search. Secrets are AES-256-GCM encrypted at rest and NEVER returned — GET reports only
// whether each is configured + the last 4 chars (+ region for Bedrock).
import { NextRequest, NextResponse } from "next/server";
import { getCurrentUserId } from "@/lib/auth";
import { prisma } from "@/lib/prisma";
import { encrypt, last4 } from "@/lib/crypto";
import { API_SERVICES, type ApiService } from "@/lib/apiKeys";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const isService = (s: unknown): s is ApiService => typeof s === "string" && (API_SERVICES as readonly string[]).includes(s);

export async function GET() {
  const userId = await getCurrentUserId();
  if (!userId) return NextResponse.json({ error: "Not authenticated" }, { status: 401 });
  const rows = await prisma.userApiKey.findMany({ where: { userId }, select: { service: true, last4: true, region: true, valueEnc: true } });
  const byService = new Map(rows.map((r) => [r.service, r]));
  const keys = API_SERVICES.map((service) => {
    const r = byService.get(service);
    return { service, configured: !!r?.valueEnc, last4: r?.last4 ?? null, region: r?.region ?? null };
  });
  return NextResponse.json({ keys });
}

export async function PUT(req: NextRequest) {
  const userId = await getCurrentUserId();
  if (!userId) return NextResponse.json({ error: "Not authenticated" }, { status: 401 });

  const body = (await req.json().catch(() => ({}))) as { service?: unknown; value?: unknown; region?: unknown };
  if (!isService(body.service)) return NextResponse.json({ error: "Unknown service" }, { status: 400 });
  const service = body.service;

  // Build the upsert payload. A non-empty `value` (re)sets the secret; a present `region` (Bedrock)
  // updates the region. A blank/absent value leaves the existing secret untouched.
  const setKey = typeof body.value === "string" && body.value.trim() !== "";
  const setRegion = "region" in body && service === "bedrock";
  if (!setKey && !setRegion) return NextResponse.json({ error: "Nothing to update" }, { status: 400 });

  const value = setKey ? (body.value as string).trim() : "";
  const region = setRegion ? ((body.region as string | null)?.trim() || null) : undefined;

  const enc = setKey ? Buffer.from(encrypt(value)) : undefined;
  await prisma.userApiKey.upsert({
    where: { userId_service: { userId, service } },
    create: {
      userId, service,
      valueEnc: enc ?? null,
      last4: setKey ? last4(value) : null,
      region: region ?? null,
    },
    update: {
      ...(setKey ? { valueEnc: enc, last4: last4(value) } : {}),
      ...(setRegion ? { region: region ?? null } : {}),
    },
  });
  return NextResponse.json({ ok: true, service, configured: setKey || undefined });
}

export async function DELETE(req: NextRequest) {
  const userId = await getCurrentUserId();
  if (!userId) return NextResponse.json({ error: "Not authenticated" }, { status: 401 });
  const service = new URL(req.url).searchParams.get("service");
  if (!isService(service)) return NextResponse.json({ error: "Unknown service" }, { status: 400 });
  await prisma.userApiKey.deleteMany({ where: { userId, service } });
  return NextResponse.json({ ok: true });
}
