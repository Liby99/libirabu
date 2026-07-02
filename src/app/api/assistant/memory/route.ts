// The assistant's persistent memory, for the user to browse and curate (design §16.2).
//   GET    → list remembered facts (excludes internal assistant.* settings)
//   PUT    { key, value } → add/edit a fact
//   DELETE { key }        → forget a fact
import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { requireUser, badRequest, serverError } from "@/app/api/calendar/_helpers";
import { listMemories, remember, forget } from "@/lib/assistant/memory";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    return NextResponse.json({ memories: await listMemories(auth) });
  } catch (e) {
    return serverError(e);
  }
}

const putSchema = z.object({ key: z.string().min(1).max(120), value: z.unknown() });

export async function PUT(req: NextRequest) {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    const parsed = putSchema.safeParse(await req.json().catch(() => null));
    if (!parsed.success) return badRequest("key (and value) required", parsed.error.issues);
    if (parsed.data.key.startsWith("assistant.")) return badRequest("that key is reserved");
    await remember(auth, parsed.data.key, parsed.data.value ?? "");
    return NextResponse.json({ ok: true });
  } catch (e) {
    return serverError(e);
  }
}

const delSchema = z.object({ key: z.string().min(1).max(120) });

export async function DELETE(req: NextRequest) {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    const parsed = delSchema.safeParse(await req.json().catch(() => null));
    if (!parsed.success) return badRequest("key required", parsed.error.issues);
    await forget(auth, parsed.data.key);
    return NextResponse.json({ ok: true });
  } catch (e) {
    return serverError(e);
  }
}
