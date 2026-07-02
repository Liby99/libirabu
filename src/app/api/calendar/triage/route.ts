// Triage box — pending tier-2 dedup decisions (docs/calendar-import-design.md §6).
//   GET  → list pending items (the incoming event, its candidates, the AI hint).
//   POST → resolve one: { id, action: "create"|"merge"|"skip", targetId? }. The item is removed.
import { NextRequest, NextResponse } from "next/server";
import { requireUser, badRequest, serverError, EventValidationError } from "../_helpers";
import { listTriage, resolveTriage } from "@/lib/import/service";
import type { CommitAction } from "@/lib/import/types";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    return NextResponse.json({ items: await listTriage(auth) });
  } catch (e) {
    return serverError(e);
  }
}

export async function POST(req: NextRequest) {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    const { id, action, targetId } = (await req.json()) as { id?: string; action?: CommitAction; targetId?: string };
    if (!id || (action !== "create" && action !== "merge" && action !== "skip")) return badRequest("id and a valid action are required");
    if (action === "merge" && !targetId) return badRequest("targetId is required to merge");
    return NextResponse.json(await resolveTriage(auth, id, action, targetId));
  } catch (e) {
    if (e instanceof EventValidationError) return badRequest(e.message);
    return serverError(e);
  }
}
