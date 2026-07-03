// GET  /api/assistant/conversations          — list the user's saved chats (newest first).
// POST /api/assistant/conversations { id?, messages } — upsert: replace a conversation's messages
//      (or create one). Title is derived from the first user message. Returns { id, title }.
import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { Prisma } from "@/generated/prisma/client";
import { prisma } from "@/lib/prisma";
import { requireUser, badRequest, serverError } from "@/app/api/calendar/_helpers";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    const rows = await prisma.aIConversation.findMany({
      where: { userId: auth },
      orderBy: { updatedAt: "desc" },
      take: 50,
      select: { id: true, title: true, updatedAt: true },
    });
    return NextResponse.json({ conversations: rows.map((r) => ({ id: r.id, title: r.title ?? "Untitled", updatedAt: r.updatedAt.toISOString() })) });
  } catch (e) {
    return serverError(e);
  }
}

const msgSchema = z.object({ role: z.enum(["user", "assistant"]) }).passthrough();
const bodySchema = z.object({
  id: z.string().min(1).max(64).nullish(), // null (new chat) or undefined both mean "create"
  messages: z.array(msgSchema).min(1).max(500),
});

function titleFrom(messages: { role: string; text?: unknown }[]): string {
  const firstUser = messages.find((m) => m.role === "user");
  const t = typeof firstUser?.text === "string" ? firstUser.text.trim() : "";
  return (t || "Untitled").slice(0, 80);
}

export async function POST(req: NextRequest) {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    const parsed = bodySchema.safeParse(await req.json().catch(() => null));
    if (!parsed.success) return badRequest("invalid request", parsed.error.issues);
    const { id, messages } = parsed.data;
    const title = titleFrom(messages as { role: string; text?: unknown }[]);
    const rows = (cid: string) => messages.map((m) => ({ conversationId: cid, role: m.role, content: m as unknown as Prisma.InputJsonValue }));

    const owned = id ? await prisma.aIConversation.findFirst({ where: { id, userId: auth }, select: { id: true } }) : null;
    if (owned) {
      await prisma.$transaction([
        prisma.aIMessage.deleteMany({ where: { conversationId: owned.id } }),
        prisma.aIConversation.update({ where: { id: owned.id }, data: { title } }),
        prisma.aIMessage.createMany({ data: rows(owned.id) }),
      ]);
      return NextResponse.json({ id: owned.id, title });
    }
    // Honor the client's id when it's free, so it matches the id AI actions were stamped with this
    // turn (change-history grouping). Fall back to a generated id if it's already taken.
    const free = id ? !(await prisma.aIConversation.findUnique({ where: { id }, select: { id: true } })) : false;
    const conv = await prisma.aIConversation.create({ data: { ...(id && free ? { id } : {}), userId: auth, title } });
    await prisma.aIMessage.createMany({ data: rows(conv.id) });
    return NextResponse.json({ id: conv.id, title });
  } catch (e) {
    return serverError(e);
  }
}
