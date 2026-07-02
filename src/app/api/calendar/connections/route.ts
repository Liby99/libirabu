// GET /api/calendar/connections — enumerate the Mac's Apple calendars (via the EventKit bridge),
// upserting a CalendarConnection per one, and return the merged list with enabled/last-synced state
// (docs/calendar-import-design.md §5.3 / §9.2). A bridge permission/build failure is reported as a
// structured `bridgeError` (HTTP 200) so the UI can show a "grant Calendar access" affordance.
import { NextResponse } from "next/server";
import { requireUser, serverError } from "../_helpers";
import { listConnections } from "@/lib/import/service";
import { AppleBridgeError } from "@/lib/import/apple";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    const userId = auth;

    try {
      const calendars = await listConnections(userId);
      return NextResponse.json({ calendars });
    } catch (e) {
      if (e instanceof AppleBridgeError) {
        return NextResponse.json({ calendars: [], bridgeError: { code: e.code, message: e.message } });
      }
      throw e;
    }
  } catch (e) {
    return serverError(e);
  }
}
