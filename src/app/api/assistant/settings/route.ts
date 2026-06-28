// GET /api/assistant/settings  → { model, models } (current selection + the catalog).
// PUT /api/assistant/settings { model } → persist the chosen model (AssistantMemory).
import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { requireUser, badRequest, serverError } from "@/app/api/calendar/_helpers";
import { getSelectedModel, remember } from "@/lib/assistant/memory";
import { MODEL_CHOICES, FALLBACK_MODEL } from "@/lib/assistant/models";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    const saved = await getSelectedModel(auth);
    const model = saved ?? process.env.JHU_GATEWAY_MODEL ?? FALLBACK_MODEL;
    return NextResponse.json({ model, models: MODEL_CHOICES });
  } catch (e) {
    return serverError(e);
  }
}

const bodySchema = z.object({ model: z.string().min(1).max(200) });

export async function PUT(req: NextRequest) {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    const parsed = bodySchema.safeParse(await req.json().catch(() => null));
    if (!parsed.success) return badRequest("invalid request", parsed.error.issues);
    await remember(auth, "assistant.model", parsed.data.model);
    return NextResponse.json({ ok: true, model: parsed.data.model });
  } catch (e) {
    return serverError(e);
  }
}
