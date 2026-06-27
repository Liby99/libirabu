// Shared helpers for the /api/calendar route handlers (not a route itself).
import { NextResponse } from "next/server";
import { getCurrentUserId } from "@/lib/auth";
import { prisma } from "@/lib/prisma";
import { DEFAULT_MAIN_TZ } from "@/lib/calendar/api";

/** The user's main timezone (for deadline origin↔main conversion); default if unset. */
export async function getMainTz(userId: string): Promise<string> {
  const prefs = await prisma.calendarPrefs.findUnique({ where: { userId }, select: { mainTz: true } });
  return prefs?.mainTz ?? DEFAULT_MAIN_TZ;
}

/** Resolve the session user id, or a ready-to-return 401 response. */
export async function requireUser(): Promise<string | NextResponse> {
  const userId = await getCurrentUserId();
  if (!userId) {
    return NextResponse.json(
      { error: "unauthorized", message: "Sign in to use the calendar API." },
      { status: 401 },
    );
  }
  return userId;
}

export const badRequest = (message: string, issues?: unknown) =>
  NextResponse.json({ error: "bad_request", message, ...(issues ? { issues } : {}) }, { status: 400 });

export const notFound = (message = "Resource not found.") =>
  NextResponse.json({ error: "not_found", message }, { status: 404 });

export const serverError = (e: unknown) => {
  console.error("[api/calendar]", e);
  return NextResponse.json({ error: "server_error", message: "Unexpected error." }, { status: 500 });
};
