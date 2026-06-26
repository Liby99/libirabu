import { NextRequest } from "next/server";
import { prisma } from "@/lib/prisma";
import { getCurrentUserId } from "@/lib/auth";
import { readFile } from "@/lib/storage";

// Authenticated, ownership-checked file download. Files are never served statically.
export async function GET(
  _req: NextRequest,
  { params }: { params: Promise<{ id: string }> },
) {
  const userId = await getCurrentUserId();
  if (!userId) return new Response("Unauthorized", { status: 401 });
  const { id } = await params;
  const att = await prisma.attachment.findFirst({ where: { id, userId } });
  if (!att) return new Response("Not found", { status: 404 });

  try {
    const data = await readFile(att.storagePath, att.encrypted);
    return new Response(new Uint8Array(data), {
      headers: {
        "Content-Type": att.mime || "application/octet-stream",
        "Content-Disposition": `inline; filename="${att.filename.replace(/"/g, "")}"`,
        "Content-Length": String(data.byteLength),
        "Cache-Control": "private, no-store",
      },
    });
  } catch {
    return new Response("File unavailable", { status: 410 });
  }
}
