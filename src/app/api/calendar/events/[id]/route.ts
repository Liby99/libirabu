import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/prisma";
import {
  eventUpdateSchema, eventSemanticIssues, eventUpdateData, toApiEvent, formatWallClock, EventKind,
  convertWallClock,
} from "@/lib/calendar/api";
import { requireUser, badRequest, notFound, serverError, getMainTz } from "../../_helpers";

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

    const existing = await prisma.calendarItem.findFirst({ where: { id, userId: auth } });
    if (!existing) return notFound("Event not found.");

    const body = await req.json().catch(() => null);
    const parsed = eventUpdateSchema.safeParse(body);
    if (!parsed.success) return badRequest("invalid patch", parsed.error.issues);
    const patch = parsed.data;
    const kind = existing.kind as EventKind;

    // Resolve a new main-tz start if the patch moves the deadline (directly or via origin).
    let startWall = patch.start ?? undefined;
    if (kind === "deadline" && !patch.start && patch.originAt) {
      const originTz = patch.originTz ?? existing.originTz;
      if (originTz) startWall = convertWallClock(patch.originAt, originTz, await getMainTz(auth));
    }

    // Re-validate the resolved event against its (unchanged) kind.
    if (kind === "deadline") {
      const effStart = startWall ?? formatWallClock(existing.start, false);
      const issues = eventSemanticIssues("deadline", effStart, effStart, null);
      if (issues.length) return badRequest(issues.join("; "));
    } else {
      const allDay = kind === "band";
      const mergedStart = patch.start ?? formatWallClock(existing.start, allDay);
      const mergedEnd = patch.end ?? formatWallClock(existing.end, allDay);
      const mergedTrack = patch.track !== undefined ? patch.track ?? null : existing.track;
      const issues = eventSemanticIssues(kind, mergedStart, mergedEnd, mergedTrack);
      if (issues.length) return badRequest(issues.join("; "));
    }

    const row = await prisma.calendarItem.update({ where: { id }, data: eventUpdateData(patch, kind, startWall) });
    return NextResponse.json(toApiEvent(row));
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
    const existing = await prisma.calendarItem.findFirst({ where: { id, userId: auth } });
    if (!existing) return notFound("Event not found.");
    await prisma.calendarItem.delete({ where: { id } });
    return new NextResponse(null, { status: 204 });
  } catch (e) {
    return serverError(e);
  }
}
