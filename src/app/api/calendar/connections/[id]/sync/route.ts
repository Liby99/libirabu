// POST /api/calendar/connections/:id/sync — run the EventKit bridge for one calendar over the sync
// window and return preview groups (New / Duplicates), WITHOUT writing (docs §9.1). The user reviews
// and commits via /api/calendar/import/commit with { connectionId }.
import { NextRequest, NextResponse } from "next/server";
import { requireUser, badRequest, serverError, EventValidationError } from "../../../_helpers";
import { buildApplePreview } from "@/lib/import/service";
import { AppleBridgeError } from "@/lib/import/apple";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type Ctx = { params: Promise<{ id: string }> };

export async function POST(_req: NextRequest, ctx: Ctx) {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    const userId = auth;
    const { id } = await ctx.params;

    const preview = await buildApplePreview(userId, id);
    return NextResponse.json(preview);
  } catch (e) {
    if (e instanceof AppleBridgeError) return NextResponse.json({ bridgeError: { code: e.code, message: e.message } }, { status: 200 });
    if (e instanceof EventValidationError) return badRequest(e.message);
    return serverError(e);
  }
}
