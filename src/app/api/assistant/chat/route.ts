// POST /api/assistant/chat — the assistant agent loop, streamed as SSE.
// Body: { message, view: ViewContext, history?: ChatMessage[] }. P0: read-only.
import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { requireUser, badRequest, serverError } from "@/app/api/calendar/_helpers";
import { runAgent } from "@/lib/assistant/agent";
import { runWithUserKeys } from "@/lib/apiKeys";
import type { ChatMessage } from "@/lib/llm";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const viewSchema = z.object({
  year: z.number().int(),
  zoom: z.enum(["year", "month", "week"]),
  focusedMonth: z.number().int().min(0).max(11),
  focusedWeekStart: z.string().optional(),
});

const historyMsgSchema = z.object({
  role: z.enum(["system", "user", "assistant", "tool"]),
  content: z.string(),
  toolCallId: z.string().optional(),
});

const attachmentSchema = z.object({
  filename: z.string().max(300),
  text: z.string().max(20000),
});

const bodySchema = z.object({
  message: z.string().min(1).max(8000),
  view: viewSchema,
  history: z.array(historyMsgSchema).max(100).optional(),
  attachments: z.array(attachmentSchema).max(10).optional(),
  resumeId: z.string().max(200).optional(), // continue a step-capped turn with its stashed scratchpad
});

export async function POST(req: NextRequest) {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    const userId = auth;

    const parsed = bodySchema.safeParse(await req.json().catch(() => null));
    if (!parsed.success) return badRequest("invalid request", parsed.error.issues);
    const { message, view, history, attachments, resumeId } = parsed.data;

    const encoder = new TextEncoder();
    const stream = new ReadableStream<Uint8Array>({
      async start(controller) {
        const send = (obj: unknown) => controller.enqueue(encoder.encode(`data: ${JSON.stringify(obj)}\n\n`));
        try {
          // Resolve this user's API keys once and keep them in scope for the whole turn, so the LLM
          // provider + web-search tool use the user's configured keys (falling back to env).
          await runWithUserKeys(userId, async () => {
            for await (const ev of runAgent({ userId, message, view, history: history as ChatMessage[] | undefined, attachments, resumeId, signal: req.signal })) {
              send(ev);
            }
          });
        } catch (e) {
          send({ t: "error", message: e instanceof Error ? e.message : "Unexpected error." });
        } finally {
          controller.close();
        }
      },
    });

    return new Response(stream, {
      headers: {
        "Content-Type": "text/event-stream; charset=utf-8",
        "Cache-Control": "no-cache, no-transform",
        Connection: "keep-alive",
      },
    });
  } catch (e) {
    return serverError(e);
  }
}
