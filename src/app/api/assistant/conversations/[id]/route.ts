// GET    /api/assistant/conversations/:id — load one chat's messages (to resume it).
// DELETE /api/assistant/conversations/:id — delete a saved chat.
import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/prisma";
import { requireUser, notFound, serverError } from "@/app/api/calendar/_helpers";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type Ctx = { params: Promise<{ id: string }> };

export async function GET(_req: NextRequest, ctx: Ctx) {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    const { id } = await ctx.params;
    const conv = await prisma.aIConversation.findFirst({ where: { id, userId: auth } });
    if (!conv) return notFound("Conversation not found.");
    const rows = await prisma.aIMessage.findMany({ where: { conversationId: id }, orderBy: { createdAt: "asc" } });
    return NextResponse.json({ id: conv.id, title: conv.title ?? "Untitled", messages: rows.map((r) => r.content) });
  } catch (e) {
    return serverError(e);
  }
}

export async function DELETE(_req: NextRequest, ctx: Ctx) {
  try {
    const auth = await requireUser();
    if (auth instanceof NextResponse) return auth;
    const { id } = await ctx.params;
    const conv = await prisma.aIConversation.findFirst({ where: { id, userId: auth }, select: { id: true } });
    if (!conv) return notFound("Conversation not found.");
    await prisma.aIConversation.delete({ where: { id } }); // AIMessage rows cascade
    return new NextResponse(null, { status: 204 });
  } catch (e) {
    return serverError(e);
  }
}
