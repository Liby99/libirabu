import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/prisma";
import { toApiEvent } from "@/lib/calendar/api";
import { indexTodos, parseDailyNoteTodos, compareTodos, toggleTodoLine, type ParsedTodo } from "@/lib/assistant/tools/todos";
import { AUTO_TZ, systemTz } from "@/app/calendar/timezones";
import {
  requireUser, badRequest, notFound, serverError, getMainTz,
  updateEventForUser, EventNotFoundError, EventValidationError,
} from "../_helpers";

// Today's date (YYYY-MM-DD) in the user's main timezone — drives `active`/defer feed visibility.
// `mainTz` may be the "auto" sentinel (follow the system zone) or, defensively, any non-IANA
// value; both resolve to the system zone rather than throwing a RangeError.
function todayInTz(tz: string): string {
  const fmt = (zone: string) =>
    new Intl.DateTimeFormat("en-CA", { timeZone: zone, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date());
  const zone = tz === AUTO_TZ ? systemTz() : tz;
  try { return fmt(zone); }
  catch { return fmt(systemTz()); }
}

// The current wall-clock to the minute in the user's main timezone: "YYYY-MM-DDTHH:MM".
// Used as the `done:` completion stamp when a TODO is ticked.
function nowInTz(tz: string): string {
  const fmt = (zone: string) => {
    const parts = new Intl.DateTimeFormat("en-CA", {
      timeZone: zone, hourCycle: "h23",
      year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit",
    }).formatToParts(new Date());
    const v = (t: string) => parts.find((x) => x.type === t)?.value ?? "00";
    return `${v("year")}-${v("month")}-${v("day")}T${v("hour")}:${v("minute")}`;
  };
  const zone = tz === AUTO_TZ ? systemTz() : tz;
  try { return fmt(zone); }
  catch { return fmt(systemTz()); }
}

// GET /api/calendar/todos
// The cross-event TODO index: every `- [ ]` checkbox in every event's notes, parsed into a flat,
// sorted, pointer-referenced list. Each item soft-links to its source line via
// (eventId, occurrenceKey, line). The markdown stays the single source of truth — this is a
// derived view, not a separate store (design §17.2).
export async function GET() {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    const userId = auth;

    const today = todayInTz(await getMainTz(userId));
    // Single-user app: scan every event AND every daily note. Rows without checkboxes yield nothing.
    const [rows, noteRows] = await Promise.all([
      prisma.calendarItem.findMany({ where: { userId }, orderBy: { start: "asc" } }),
      prisma.dailyNote.findMany({ where: { userId } }),
    ]);
    const eventTodos = indexTodos(rows.map(toApiEvent), today);
    const dailyTodos = noteRows.flatMap((n) => parseDailyNoteTodos(n.date, n.notes, today));
    const todos: ParsedTodo[] = [...eventTodos, ...dailyTodos].sort(compareTodos);
    return NextResponse.json({ todos, today });
  } catch (e) {
    return serverError(e);
  }
}

// PATCH /api/calendar/todos — the soft-link write: check/uncheck one TODO by its anchor.
// Event source:  { eventId, occurrenceKey?: string|null, line, checked? }  → rewrites a CalendarItem note
// Daily source:  { dailyDate: "YYYY-MM-DD", line, checked? }               → rewrites a DailyNote
//   checked omitted → toggle. Ticking stamps a main-tz `done:` to the minute; untick strips it.
export async function PATCH(req: NextRequest) {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    const userId = auth;

    const body = await req.json().catch(() => null);
    if (!body || typeof body !== "object") return badRequest("expected a JSON body");
    const b = body as Record<string, unknown>;
    const { line, dailyDate } = b;
    const checked = b.checked;

    if (typeof line !== "number" || !Number.isInteger(line) || line < 1) return badRequest("line (1-based integer) is required");
    if (checked !== undefined && typeof checked !== "boolean") return badRequest("checked must be a boolean");

    const stamp = nowInTz(await getMainTz(userId)); // `done:` completion stamp

    // ── Daily-note source ──
    if (dailyDate !== undefined) {
      if (typeof dailyDate !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(dailyDate)) return badRequest("dailyDate must be YYYY-MM-DD");
      const row = await prisma.dailyNote.findUnique({ where: { userId_date: { userId, date: dailyDate } } });
      if (!row) return badRequest("The referenced daily note no longer exists (stale anchor).");
      const next = toggleTodoLine(row.notes, line, checked, stamp);
      if (next === null) return badRequest("That line is no longer a checkbox (stale anchor).");
      if (next === row.notes) return NextResponse.json({ ok: true, changed: false });
      await prisma.dailyNote.update({ where: { userId_date: { userId, date: dailyDate } }, data: { notes: next } });
      return NextResponse.json({ ok: true, changed: true });
    }

    // ── Event source ──
    const { eventId } = b;
    const occurrenceKey = b.occurrenceKey ?? null;
    if (typeof eventId !== "string" || !eventId) return badRequest("eventId (string) or dailyDate is required");
    if (occurrenceKey !== null && typeof occurrenceKey !== "string") return badRequest("occurrenceKey must be a string or null");

    const event = await prisma.calendarItem.findFirst({ where: { id: eventId, userId } });
    if (!event) return notFound("No such event.");

    // Pick the note this anchor points into: base notes, or one per-occurrence note.
    const occNotes = (event.occurrenceNotes as Record<string, string> | null) ?? {};
    const source = occurrenceKey === null ? event.notes : occNotes[occurrenceKey as string];
    if (source == null) return badRequest("The referenced note no longer exists (stale anchor).");

    const next = toggleTodoLine(source, line, checked, stamp);
    if (next === null) return badRequest("That line is no longer a checkbox (stale anchor).");
    if (next === source) return NextResponse.json({ ok: true, changed: false }); // already in the requested state

    // occurrenceNotes is replace-on-patch, so merge the single changed key back into the full map.
    const patch = occurrenceKey === null
      ? { notes: next }
      : { occurrenceNotes: { ...occNotes, [occurrenceKey as string]: next } };

    try {
      await updateEventForUser(userId, eventId, patch);
    } catch (e) {
      if (e instanceof EventNotFoundError) return notFound("No such event.");
      if (e instanceof EventValidationError) return badRequest(e.message);
      throw e;
    }
    return NextResponse.json({ ok: true, changed: true });
  } catch (e) {
    return serverError(e);
  }
}
