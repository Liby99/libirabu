// POST /api/assistant/allow — the user overrode an auditor-BLOCKED action ("Allow" in the chat).
// Re-runs the exact tool call with the auditor bypassed (the human explicitly approved it). The
// blocked action card carries { name, arguments }, which the client posts back here.
// Body: { name: string, arguments: object }.
import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { toolByName } from "@/lib/assistant/tools/registry";
import type { ViewContext } from "@/lib/assistant/types";
import {
  requireUser, badRequest, notFound, serverError,
  deleteEventForUser, EventNotFoundError, EventValidationError,
} from "@/app/api/calendar/_helpers";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const bodySchema = z.object({
  name: z.string().min(1).max(64),
  arguments: z.record(z.string(), z.unknown()).default({}),
});

// Tools don't use `view` for mutations (create/update/delete operate on their args); a stub suffices.
const STUB_VIEW: ViewContext = { year: new Date().getFullYear(), zoom: "month", focusedMonth: 0 };

export async function POST(req: NextRequest) {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;

    const parsed = bodySchema.safeParse(await req.json().catch(() => null));
    if (!parsed.success) return badRequest("invalid request", parsed.error.issues);
    const { name, arguments: args } = parsed.data;

    const tool = toolByName.get(name);
    if (!tool || tool.readOnly) return badRequest("That action can't be overridden.");

    try {
      const ctx = { userId: auth, view: STUB_VIEW };
      if (tool.confirm) {
        // Confirm-gated (delete): run() only RESOLVES a spec — perform the real mutation here.
        const spec = (await tool.run(args, ctx)) as { id: string; occurrenceDate?: string | null };
        const result = await deleteEventForUser(auth, spec.id, spec.occurrenceDate ?? undefined, "ai");
        return NextResponse.json({ ok: true, result });
      }
      const result = await tool.run(args, ctx); // create/update mutate directly
      return NextResponse.json({ ok: true, result });
    } catch (e) {
      if (e instanceof EventNotFoundError) return notFound("Event not found.");
      if (e instanceof EventValidationError) return badRequest(e.message);
      throw e;
    }
  } catch (e) {
    return serverError(e);
  }
}
