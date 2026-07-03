// Account profile — read + update the signed-in user's editable fields (name/username, personal
// website, avatar). Email is identity here and is NOT changeable. Password lives in its own route
// (/api/auth/change-password). Avatars are small client-resized data URLs stored in User.image.
import { NextRequest, NextResponse } from "next/server";
import { getCurrentUserId } from "@/lib/auth";
import { prisma } from "@/lib/prisma";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const AVATAR_MAX = 700_000; // ~0.5MB of base64 — a 256²ish avatar fits comfortably

export async function GET() {
  const userId = await getCurrentUserId();
  if (!userId) return NextResponse.json({ error: "Not authenticated" }, { status: 401 });
  const user = await prisma.user.findUnique({
    where: { id: userId },
    select: { email: true, name: true, website: true, image: true },
  });
  if (!user) return NextResponse.json({ error: "User not found" }, { status: 404 });
  return NextResponse.json(user);
}

export async function PATCH(req: NextRequest) {
  const userId = await getCurrentUserId();
  if (!userId) return NextResponse.json({ error: "Not authenticated" }, { status: 401 });

  const body = (await req.json().catch(() => ({}))) as { name?: unknown; website?: unknown; image?: unknown };
  const data: { name?: string | null; website?: string | null; image?: string | null } = {};

  // Username: trimmed, ≤ 60 chars; blank clears it.
  if ("name" in body) {
    if (body.name !== null && typeof body.name !== "string") return NextResponse.json({ error: "Invalid name" }, { status: 400 });
    const name = (body.name as string | null)?.trim() ?? "";
    if (name.length > 60) return NextResponse.json({ error: "Name is too long (max 60)" }, { status: 400 });
    data.name = name || null;
  }

  // Website: must be a plausible http(s) URL if present; blank clears it.
  if ("website" in body) {
    if (body.website !== null && typeof body.website !== "string") return NextResponse.json({ error: "Invalid website" }, { status: 400 });
    const raw = (body.website as string | null)?.trim() ?? "";
    if (!raw) {
      data.website = null;
    } else {
      const url = /^https?:\/\//i.test(raw) ? raw : `https://${raw}`;
      try { new URL(url); } catch { return NextResponse.json({ error: "Invalid website URL" }, { status: 400 }); }
      data.website = url;
    }
  }

  // Avatar: a data URL (already resized client-side) or null to clear.
  if ("image" in body) {
    if (body.image === null || body.image === "") {
      data.image = null;
    } else if (typeof body.image === "string" && body.image.startsWith("data:image/")) {
      if (body.image.length > AVATAR_MAX) return NextResponse.json({ error: "Image is too large" }, { status: 400 });
      data.image = body.image;
    } else {
      return NextResponse.json({ error: "Invalid image" }, { status: 400 });
    }
  }

  const user = await prisma.user.update({
    where: { id: userId },
    data,
    select: { email: true, name: true, website: true, image: true },
  });
  return NextResponse.json(user);
}
