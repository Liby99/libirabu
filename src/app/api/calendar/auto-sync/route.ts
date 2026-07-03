// GET/PUT /api/calendar/auto-sync — the user's "Automatic sync" toggle (Connectivity menu).
// The background scheduler (docs §12.3) reads this each tick, so toggling takes effect next cycle.
import { NextRequest, NextResponse } from "next/server";
import { requireUser, badRequest, serverError } from "../_helpers";
import { getAutoSyncPref, setAutoSyncPref } from "@/lib/import/service";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    return NextResponse.json({ enabled: await getAutoSyncPref(auth) });
  } catch (e) {
    return serverError(e);
  }
}

export async function PUT(req: NextRequest) {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    const { enabled } = (await req.json().catch(() => ({}))) as { enabled?: unknown };
    if (typeof enabled !== "boolean") return badRequest("enabled (boolean) is required");
    await setAutoSyncPref(auth, enabled);
    return NextResponse.json({ enabled });
  } catch (e) {
    return serverError(e);
  }
}
