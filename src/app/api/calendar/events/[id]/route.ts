import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/prisma";
import { toApiEvent } from "@/lib/calendar/api";
import {
  requireUser, badRequest, notFound, serverError,
  updateEventForUser, deleteEventForUser, EventValidationError, EventNotFoundError,
} from "../../_helpers";

type Ctx = { params: Promise<{ id: string }> };

// GET /api/calendar/events/:id — fetch a single event.
export async function GET(_req: NextRequest, ctx: Ctx) {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    const { id } = await ctx.params;
    const row = await prisma.calendarItem.findFirst({ where: { id, userId: auth } });
    if (!row) return notFound("Event not found.");
    return NextResponse.json(toApiEvent(row));
  } catch (e) {
    return serverError(e);
  }
}

// PATCH /api/calendar/events/:id — partial update (kind is immutable).
export async function PATCH(req: NextRequest, ctx: Ctx) {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    const { id } = await ctx.params;
    const body = await req.json().catch(() => null);
    try {
      return NextResponse.json(await updateEventForUser(auth, id, body));
    } catch (e) {
      if (e instanceof EventNotFoundError) return notFound("Event not found.");
      if (e instanceof EventValidationError) return badRequest(e.message);
      throw e;
    }
  } catch (e) {
    return serverError(e);
  }
}

// DELETE /api/calendar/events/:id
export async function DELETE(_req: NextRequest, ctx: Ctx) {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    const { id } = await ctx.params;
    try {
      await deleteEventForUser(auth, id);
      return new NextResponse(null, { status: 204 });
    } catch (e) {
      if (e instanceof EventNotFoundError) return notFound("Event not found.");
      throw e;
    }
  } catch (e) {
    return serverError(e);
  }
}
