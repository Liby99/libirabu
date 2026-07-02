// POST /api/calendar/import/clear — hard-delete ALL imported events (incl. hidden ones) so the next
// sync re-imports from scratch. Debug/reset utility (also handy after import-format changes).
// Manual events + internalized copies are kept.
import { NextResponse } from "next/server";
import { requireUser, serverError } from "../../_helpers";
import { clearAllImported } from "@/lib/import/service";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST() {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    const deleted = await clearAllImported(auth);
    return NextResponse.json({ deleted });
  } catch (e) {
    return serverError(e);
  }
}
