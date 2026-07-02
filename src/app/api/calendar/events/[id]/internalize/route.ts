// POST /api/calendar/events/:id/internalize — detach an imported event into a fully-owned manual
// copy and hide the original (docs/calendar-import-design.md §7). Returns the new copy (ApiEvent).
import { NextRequest, NextResponse } from "next/server";
import { requireUser, badRequest, notFound, serverError, internalizeEventForUser, EventNotFoundError, EventValidationError } from "../../../_helpers";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type Ctx = { params: Promise<{ id: string }> };

export async function POST(_req: NextRequest, ctx: Ctx) {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    const userId = auth;
    const { id } = await ctx.params;

    const copy = await internalizeEventForUser(userId, id);
    return NextResponse.json(copy, { status: 201 });
  } catch (e) {
    if (e instanceof EventNotFoundError) return notFound("Event not found.");
    if (e instanceof EventValidationError) return badRequest(e.message);
    return serverError(e);
  }
}
