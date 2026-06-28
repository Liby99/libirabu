// GET  /api/assistant/history        — list the AI's calendar operations (newest first).
// POST /api/assistant/history { id }  — revert one AI operation (per-op inverse, design §16).
import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import {
  requireUser, badRequest, notFound, serverError,
  listAiActions, revertAiAction, EventNotFoundError, EventValidationError,
} from "@/app/api/calendar/_helpers";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    return NextResponse.json({ actions: await listAiActions(auth) });
  } catch (e) {
    return serverError(e);
  }
}

const revertSchema = z.object({ id: z.string().min(1).max(64) });

export async function POST(req: NextRequest) {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    const parsed = revertSchema.safeParse(await req.json().catch(() => null));
    if (!parsed.success) return badRequest("invalid request", parsed.error.issues);
    try {
      return NextResponse.json(await revertAiAction(auth, parsed.data.id));
    } catch (e) {
      if (e instanceof EventNotFoundError) return notFound("Action not found.");
      if (e instanceof EventValidationError) return badRequest(e.message);
      throw e;
    }
  } catch (e) {
    return serverError(e);
  }
}
