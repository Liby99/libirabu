import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/prisma";
import { requireUser, badRequest, serverError } from "../_helpers";

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

// GET /api/calendar/daily-note?date=YYYY-MM-DD → { date, notes }
// The per-day free-form markdown note shown in the daily dashboard's NOTE tab. `notes` is "" when
// the day has no note yet.
export async function GET(req: NextRequest) {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    const userId = auth;

    const date = req.nextUrl.searchParams.get("date");
    if (!date || !DATE_RE.test(date)) return badRequest("date (YYYY-MM-DD) is required");

    const row = await prisma.dailyNote.findUnique({ where: { userId_date: { userId, date } }, select: { notes: true } });
    return NextResponse.json({ date, notes: row?.notes ?? "" });
  } catch (e) {
    return serverError(e);
  }
}

// PUT /api/calendar/daily-note — body { date, notes }. Upserts the day's note; an empty note
// deletes the row (keeps the table sparse).
export async function PUT(req: NextRequest) {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    const userId = auth;

    const body = await req.json().catch(() => null);
    if (!body || typeof body !== "object") return badRequest("expected a JSON body");
    const { date, notes } = body as Record<string, unknown>;
    if (typeof date !== "string" || !DATE_RE.test(date)) return badRequest("date (YYYY-MM-DD) is required");
    if (typeof notes !== "string") return badRequest("notes (string) is required");
    if (notes.length > 100_000) return badRequest("notes too large");

    if (notes.trim() === "") {
      await prisma.dailyNote.deleteMany({ where: { userId, date } });
      return NextResponse.json({ date, notes: "" });
    }
    await prisma.dailyNote.upsert({
      where: { userId_date: { userId, date } },
      create: { userId, date, notes },
      update: { notes },
    });
    return NextResponse.json({ date, notes });
  } catch (e) {
    return serverError(e);
  }
}
