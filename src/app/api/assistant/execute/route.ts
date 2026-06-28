// POST /api/assistant/execute — runs a confirm-gated assistant action AFTER the user clicked
// Confirm in the chat UI (design §7.2: human-in-the-loop for deletes). P3 supports delete only.
// Body: { action: "delete", id, occurrenceDate? }.
import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import {
  requireUser, badRequest, notFound, serverError,
  deleteEventForUser, EventNotFoundError, EventValidationError,
} from "@/app/api/calendar/_helpers";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const bodySchema = z.object({
  action: z.literal("delete"),
  id: z.string().min(1).max(64),
  occurrenceDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
});

export async function POST(req: NextRequest) {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;

    const parsed = bodySchema.safeParse(await req.json().catch(() => null));
    if (!parsed.success) return badRequest("invalid request", parsed.error.issues);
    const { id, occurrenceDate } = parsed.data;

    try {
      const result = await deleteEventForUser(auth, id, occurrenceDate, "ai");
      return NextResponse.json(result);
    } catch (e) {
      if (e instanceof EventNotFoundError) return notFound("Event not found.");
      if (e instanceof EventValidationError) return badRequest(e.message);
      throw e;
    }
  } catch (e) {
    return serverError(e);
  }
}
