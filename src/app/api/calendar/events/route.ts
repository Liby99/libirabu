import { NextRequest, NextResponse } from "next/server";
import { Prisma } from "@/generated/prisma/client";
import { prisma } from "@/lib/prisma";
import {
  ApiEvent, EVENT_KINDS, EventKind, eventCreateSchema, eventSemanticIssues,
  eventCreateData, resolveStartWall, toApiEvent, wallClock, DEFAULT_MAIN_TZ,
} from "@/lib/calendar/api";
import { requireUser, badRequest, serverError, getMainTz } from "../_helpers";

// GET /api/calendar/events?year=2026[&kind=timed|band][&from=YYYY-MM-DD&to=YYYY-MM-DD]
// Lists the signed-in user's events that overlap the given window. Provide either
// `year` (whole calendar year) or both `from` and `to` (date-only, [from, to) exclusive).
export async function GET(req: NextRequest) {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    const userId = auth;

    const sp = req.nextUrl.searchParams;
    const kind = sp.get("kind");
    if (kind && !EVENT_KINDS.includes(kind as EventKind)) {
      return badRequest(`kind must be one of ${EVENT_KINDS.join(", ")}`);
    }

    let rangeStart: Date;
    let rangeEnd: Date;
    const yearParam = sp.get("year");
    if (yearParam) {
      const year = Number(yearParam);
      if (!Number.isInteger(year) || year < 1970 || year > 3000) return badRequest("year must be an integer (1970–3000)");
      rangeStart = wallClock(year, 0, 1);
      rangeEnd = wallClock(year + 1, 0, 1);
    } else {
      const from = sp.get("from"), to = sp.get("to");
      if (!from || !to) return badRequest("provide ?year=YYYY, or both ?from= and ?to= (YYYY-MM-DD)");
      const m = /^(\d{4})-(\d{2})-(\d{2})$/;
      if (!m.test(from) || !m.test(to)) return badRequest("from/to must be YYYY-MM-DD");
      rangeStart = new Date(`${from}T00:00:00.000Z`);
      rangeEnd = new Date(`${to}T00:00:00.000Z`);
    }

    const rows = await prisma.calendarItem.findMany({
      where: {
        userId,
        ...(kind ? { kind } : {}),
        start: { lt: rangeEnd }, // overlaps [rangeStart, rangeEnd)
        end: { gte: rangeStart },
      },
      orderBy: { start: "asc" },
    });
    const events: ApiEvent[] = rows.map(toApiEvent);
    return NextResponse.json({ events });
  } catch (e) {
    return serverError(e);
  }
}

// POST /api/calendar/events — create an event. Body: see eventCreateSchema / README.
export async function POST(req: NextRequest) {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    const userId = auth;

    const body = await req.json().catch(() => null);
    const parsed = eventCreateSchema.safeParse(body);
    if (!parsed.success) return badRequest("invalid event", parsed.error.issues);

    const input = parsed.data;
    // Deadlines may be specified in an origin tz (originAt/originTz) → resolve to a
    // main-tz wall-clock for storage; timed/band use `start`/`end` directly.
    const needTz = input.kind === "deadline" && !input.start && !!input.originAt;
    const mainTz = needTz ? await getMainTz(userId) : DEFAULT_MAIN_TZ;
    const startWall = input.kind === "deadline" ? resolveStartWall(input, mainTz) : input.start;
    const endWall = input.kind === "deadline" ? startWall : input.end;

    const issues = eventSemanticIssues(input.kind, startWall, endWall, input.track ?? null);
    if (issues.length) return badRequest(issues.join("; "));

    const data = eventCreateData(input, startWall as string, endWall as string);
    const row = await prisma.calendarItem.create({
      data: { userId, ...data, repeat: data.repeat as unknown as Prisma.InputJsonValue, ...(input.id ? { id: input.id } : {}) },
    });
    return NextResponse.json(toApiEvent(row), { status: 201 });
  } catch (e) {
    if (e && typeof e === "object" && "code" in e && (e as { code: string }).code === "P2002") {
      return NextResponse.json({ error: "conflict", message: "An event with that id already exists." }, { status: 409 });
    }
    return serverError(e);
  }
}
