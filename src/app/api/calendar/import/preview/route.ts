// POST /api/calendar/import/preview — parse a .ics blob and diff it against the calendar, WITHOUT
// writing anything (docs/calendar-import-design.md §9). Returns preview groups (new / decide /
// duplicate) plus the count of all-day events ignored by policy.
import { NextRequest, NextResponse } from "next/server";
import { requireUser, badRequest, serverError } from "../../_helpers";
import { buildIcsPreview } from "@/lib/import/service";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const MAX_ICS = 5 * 1024 * 1024; // 5 MB of .ics text

export async function POST(req: NextRequest) {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    const userId = auth;

    const body = await req.json().catch(() => null);
    const icsText = body?.icsText;
    const filename = typeof body?.filename === "string" ? body.filename : undefined;
    if (typeof icsText !== "string" || !icsText.trim()) return badRequest("icsText (string) is required");
    if (icsText.length > MAX_ICS) return badRequest("ics too large (max 5 MB)");
    if (!/BEGIN:VCALENDAR/i.test(icsText)) return badRequest("not a valid .ics file (no VCALENDAR)");

    const preview = await buildIcsPreview(userId, icsText, filename);
    return NextResponse.json(preview);
  } catch (e) {
    return serverError(e);
  }
}
