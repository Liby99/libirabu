import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/prisma";
import { ApiEvent, EVENT_KINDS, EventKind, toApiEvent, wallClock, Repeat } from "@/lib/calendar/api";
import { occurrenceDates } from "@/app/calendar/model/occurrences";
import {
  requireUser, badRequest, serverError,
  createEventForUser, EventValidationError, isUniqueViolation,
} from "../_helpers";

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
    // Soft-deleted (hidden) events are excluded unless explicitly requested (the "Show hidden" view).
    const includeHidden = sp.get("includeHidden") === "1";
    const hiddenFilter = includeHidden ? {} : { hidden: false };

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
        ...hiddenFilter,
        start: { lt: rangeEnd }, // overlaps [rangeStart, rangeEnd)
        end: { gte: rangeStart },
      },
      orderBy: { start: "asc" },
    });
    const events: ApiEvent[] = rows.map(toApiEvent);

    // Cross-year recurrence: a recurring base living in an EARLIER year still projects
    // occurrences into this window, but its row sits before the window so the query above
    // misses it. Pull recurring bases that start before the window and keep the ones that
    // actually reach the requested year (the "special small set"). Whole-year query only;
    // their own base day is in another year, so the client renders only their ghosts here.
    if (yearParam) {
      const year = Number(yearParam);
      const recurringBases = await prisma.calendarItem.findMany({
        where: {
          userId,
          ...(kind ? { kind } : {}),
          ...hiddenFilter,
          start: { lt: rangeStart },                // base is in an earlier year
          repeat: { path: ["kind"], not: "none" },  // …and it recurs
        },
        orderBy: { start: "asc" },
      });
      for (const row of recurringBases) {
        const s = row.start; // floating wall-clock → read with UTC getters
        const base = { year: s.getUTCFullYear(), month: s.getUTCMonth(), day: s.getUTCDate() };
        if (occurrenceDates(base, row.repeat as unknown as Repeat, year).length > 0) events.push(toApiEvent(row));
      }
    }
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
    try {
      const ev = await createEventForUser(userId, body);
      return NextResponse.json(ev, { status: 201 });
    } catch (e) {
      if (e instanceof EventValidationError) return badRequest(e.message);
      if (isUniqueViolation(e)) {
        return NextResponse.json({ error: "conflict", message: "An event with that id already exists." }, { status: 409 });
      }
      throw e;
    }
  } catch (e) {
    return serverError(e);
  }
}
