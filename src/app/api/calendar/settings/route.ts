import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/prisma";
import { ApiSettings, DEFAULT_MAIN_TZ, settingsUpdateSchema } from "@/lib/calendar/api";
import { requireUser, badRequest, serverError } from "../_helpers";

type PrefsRow = { mainTz: string; altTz: string | null; trackNames: unknown };

// Track names are stored per-year ({ "2026": [12][4], … }). A legacy single [12][4] grid
// (pre per-year) is adopted as the current year so existing names aren't lost.
function normTrackMap(v: unknown): Record<string, string[][]> {
  if (Array.isArray(v)) return { [String(new Date().getFullYear())]: v as string[][] };
  if (v && typeof v === "object") return v as Record<string, string[][]>;
  return {};
}
const toApiSettings = (row: PrefsRow): ApiSettings => ({
  mainTz: row.mainTz,
  altTz: row.altTz ?? null,
  trackNames: normTrackMap(row.trackNames),
});

// GET /api/calendar/settings — the user's calendar preferences (defaults if never set).
export async function GET() {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    const row = await prisma.calendarPrefs.findUnique({ where: { userId: auth } });
    if (!row) {
      return NextResponse.json({ mainTz: DEFAULT_MAIN_TZ, altTz: null, trackNames: {} } satisfies ApiSettings);
    }
    return NextResponse.json(toApiSettings(row));
  } catch (e) {
    return serverError(e);
  }
}

// PUT /api/calendar/settings — partial update of mainTz / altTz / trackNames (upserts).
export async function PUT(req: NextRequest) {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;

    const body = await req.json().catch(() => null);
    const parsed = settingsUpdateSchema.safeParse(body);
    if (!parsed.success) return badRequest("invalid settings", parsed.error.issues);
    const p = parsed.data;

    const row = await prisma.calendarPrefs.upsert({
      where: { userId: auth },
      update: {
        ...(p.mainTz !== undefined ? { mainTz: p.mainTz } : {}),
        ...(p.altTz !== undefined ? { altTz: p.altTz } : {}),
        ...(p.trackNames !== undefined ? { trackNames: p.trackNames } : {}),
      },
      create: {
        userId: auth,
        mainTz: p.mainTz ?? DEFAULT_MAIN_TZ,
        altTz: p.altTz ?? null,
        trackNames: p.trackNames ?? {},
      },
    });
    return NextResponse.json(toApiSettings(row));
  } catch (e) {
    return serverError(e);
  }
}
