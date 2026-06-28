// Server-built, TRUSTED context for the auditor (design §7.1): today's date + the existing events
// near a proposed mutation. Read straight from the DB — never via the actor or the web — so the
// auditor gains calendar/date awareness (catch duplicates/conflicts, judge "today"/"next week")
// WITHOUT an agentic tool loop that could be prompt-injected.

import { prisma } from "@/lib/prisma";
import { toApiEvent } from "@/lib/calendar/api";

function dateFromArgs(args: Record<string, unknown>): string | null {
  for (const k of ["start", "originAt", "end"]) {
    const v = args[k];
    if (typeof v === "string" && /^\d{4}-\d{2}-\d{2}/.test(v)) return v.slice(0, 10);
  }
  return null;
}

/** A short "existing events on <date>" line for the proposed event's day (empty if no date). */
export async function buildAuditContext(userId: string, args: Record<string, unknown>): Promise<string> {
  const date = dateFromArgs(args);
  if (!date) return "";
  const dayStart = new Date(`${date}T00:00:00.000Z`);
  const dayEnd = new Date(dayStart.getTime() + 86_400_000);
  try {
    const rows = await prisma.calendarItem.findMany({
      where: { userId, start: { lt: dayEnd }, end: { gte: dayStart } },
      orderBy: { start: "asc" },
      take: 20,
    });
    if (!rows.length) return `Existing events on ${date}: none.`;
    const list = rows
      .map((r) => {
        const ev = toApiEvent(r);
        const time = ev.allDay ? "all-day" : ev.start.slice(11, 16);
        return `${time} ${ev.title}`;
      })
      .join("; ");
    return `Existing events on ${date}: ${list}.`;
  } catch {
    return "";
  }
}
