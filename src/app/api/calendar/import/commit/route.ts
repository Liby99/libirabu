// POST /api/calendar/import/commit — apply the user's reviewed selections for a .ics blob
// (docs/calendar-import-design.md §9). The server re-derives the same deterministic preview from the
// .ics text and applies each selection by tempId, so no un-trusted event payloads come from the
// client. Writes go through the shared createEventForUser / updateEventForUser path.
import { NextRequest, NextResponse } from "next/server";
import { requireUser, badRequest, serverError, EventValidationError } from "../../_helpers";
import { commitIcs, commitApple } from "@/lib/import/service";
import { AppleBridgeError } from "@/lib/import/apple";
import type { CommitAction, CommitSelection } from "@/lib/import/types";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const ACTIONS: CommitAction[] = ["create", "merge", "skip"];

export async function POST(req: NextRequest) {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    const userId = auth;

    const body = await req.json().catch(() => null);
    if (!Array.isArray(body?.selections)) return badRequest("selections (array) is required");

    // Validate/normalize the selections array.
    const selections: CommitSelection[] = [];
    for (const s of body.selections) {
      if (!s || typeof s.tempId !== "string" || !ACTIONS.includes(s.action)) {
        return badRequest("each selection needs a tempId and action of create|merge|skip");
      }
      if (s.action === "merge" && typeof s.targetId !== "string") return badRequest("merge selections need a targetId");
      selections.push({ tempId: s.tempId, action: s.action, targetId: s.targetId });
    }

    // One source per commit: an uploaded .ics, or an Apple connection to re-fetch.
    const icsText = body?.icsText;
    const connectionId = body?.connectionId;
    const removeIds = Array.isArray(body?.removeIds) ? body.removeIds.filter((x: unknown): x is string => typeof x === "string") : [];
    let result;
    if (typeof connectionId === "string" && connectionId) {
      result = await commitApple(userId, connectionId, selections, removeIds);
    } else if (typeof icsText === "string" && icsText.trim()) {
      const filename = typeof body?.filename === "string" ? body.filename : undefined;
      result = await commitIcs(userId, icsText, filename, selections);
    } else {
      return badRequest("provide either icsText or connectionId");
    }
    return NextResponse.json(result);
  } catch (e) {
    if (e instanceof AppleBridgeError) return badRequest(`Apple Calendar: ${e.message}`);
    if (e instanceof EventValidationError) return badRequest(e.message);
    return serverError(e);
  }
}
