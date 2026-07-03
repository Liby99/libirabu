// POST /api/calendar/sync-all — on-demand sync of ALL enabled Apple calendars (the Connectivity
// "Sync" button). Auto-applies new + tier-1 changes, parks tier-2 in Triage; not gated by the
// Automatic-sync preference (this is a manual trigger).
import { NextResponse } from "next/server";
import { requireUser, serverError } from "../_helpers";
import { syncAllConnections } from "@/lib/import/service";
import { AppleBridgeError } from "@/lib/import/apple";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST() {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    return NextResponse.json(await syncAllConnections(auth));
  } catch (e) {
    if (e instanceof AppleBridgeError) return NextResponse.json({ bridgeError: { code: e.code, message: e.message } }, { status: 200 });
    return serverError(e);
  }
}
