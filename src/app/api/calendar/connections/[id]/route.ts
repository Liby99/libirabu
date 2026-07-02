// PATCH /api/calendar/connections/:id — enable/disable one connected calendar for import.
import { NextRequest, NextResponse } from "next/server";
import { requireUser, badRequest, serverError, EventValidationError } from "../../_helpers";
import { setConnectionEnabled } from "@/lib/import/service";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type Ctx = { params: Promise<{ id: string }> };

export async function PATCH(req: NextRequest, ctx: Ctx) {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    const userId = auth;
    const { id } = await ctx.params;

    const body = await req.json().catch(() => null);
    if (typeof body?.enabled !== "boolean") return badRequest("enabled (boolean) is required");

    await setConnectionEnabled(userId, id, body.enabled);
    return NextResponse.json({ ok: true });
  } catch (e) {
    if (e instanceof EventValidationError) return badRequest(e.message);
    return serverError(e);
  }
}
