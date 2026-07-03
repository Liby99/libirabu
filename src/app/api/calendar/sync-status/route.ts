// GET /api/calendar/sync-status — the latest background auto-sync result (docs §12.3). The client
// polls this so background-applied changes aren't silent: when lastRunAt advances with new/updated
// events, the calendar refetches.
import { NextResponse } from "next/server";
import { requireUser, serverError } from "../_helpers";
import { getAutoSyncStatus } from "@/lib/import/autoSync";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    return NextResponse.json(getAutoSyncStatus());
  } catch (e) {
    return serverError(e);
  }
}
