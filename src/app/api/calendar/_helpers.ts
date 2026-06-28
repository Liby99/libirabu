// Shared helpers for the /api/calendar route handlers (not a route itself).
import { NextResponse } from "next/server";
import { Prisma } from "@/generated/prisma/client";
import { getCurrentUserId } from "@/lib/auth";
import { prisma } from "@/lib/prisma";
import {
  ApiEvent, DEFAULT_MAIN_TZ, EventKind, Repeat, eventCreateSchema, eventSemanticIssues,
  eventCreateData, eventUpdateSchema, eventUpdateData, resolveStartWall, toApiEvent,
  formatWallClock, convertWallClock,
} from "@/lib/calendar/api";

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

/** Thrown by create/update on schema/semantic problems (maps to HTTP 400). */
export class EventValidationError extends Error {}
/** Thrown when the event doesn't exist / isn't owned by the user (maps to HTTP 404). */
export class EventNotFoundError extends Error {}

/** P2002 (unique violation) — a client-supplied id already exists. */
export const isUniqueViolation = (e: unknown): boolean =>
  !!e && typeof e === "object" && "code" in e && (e as { code: string }).code === "P2002";

// Create one event for a user from a raw body (zod-validated). Shared by the POST route
// and the AI assistant's create_event tool so both go through identical validation,
// deadline-timezone resolution, and semantic checks. Throws EventValidationError on bad
// input; lets the Prisma P2002 (duplicate id) bubble for the caller to map to 409.
export async function createEventForUser(userId: string, body: unknown, actor: "user" | "ai" = "user"): Promise<ApiEvent> {
  const parsed = eventCreateSchema.safeParse(body);
  if (!parsed.success) throw new EventValidationError(parsed.error.issues.map((i) => i.message).join("; "));
  const input = parsed.data;

  // Deadlines may be specified in an origin tz (originAt/originTz) → resolve to a main-tz
  // wall-clock for storage; timed/band use start/end directly.
  const needTz = input.kind === "deadline" && !input.start && !!input.originAt;
  const mainTz = needTz ? await getMainTz(userId) : DEFAULT_MAIN_TZ;
  const startWall = input.kind === "deadline" ? resolveStartWall(input, mainTz) : input.start;
  const endWall = input.kind === "deadline" ? startWall : input.end;

  const issues = eventSemanticIssues(input.kind, startWall, endWall, input.track ?? null);
  if (issues.length) throw new EventValidationError(issues.join("; "));

  const data = eventCreateData(input, startWall as string, endWall as string);
  const row = await prisma.calendarItem.create({
    data: {
      userId, ...data,
      repeat: data.repeat as unknown as Prisma.InputJsonValue,
      occurrenceNotes: data.occurrenceNotes as unknown as Prisma.InputJsonValue,
      createdByAI: actor === "ai" || data.createdByAI, // AI path forces provenance true
      ...(input.id ? { id: input.id } : {}),
    },
  });
  const ev = toApiEvent(row);
  if (actor === "ai") await logAiAction(userId, "create", null, ev).catch(() => {});
  return ev;
}

// Partial-update one event (kind immutable). Shared by the PATCH route and the assistant's
// update_event tool. actor "ai" stamps provenance (createdByAI=true → AI badge). Throws
// EventNotFoundError / EventValidationError for the caller to map to 404 / 400.
export async function updateEventForUser(userId: string, id: string, body: unknown, actor: "user" | "ai" = "user"): Promise<ApiEvent> {
  const existing = await prisma.calendarItem.findFirst({ where: { id, userId } });
  if (!existing) throw new EventNotFoundError();
  const before = toApiEvent(existing);

  const parsed = eventUpdateSchema.safeParse(body);
  if (!parsed.success) throw new EventValidationError(parsed.error.issues.map((i) => i.message).join("; "));
  const patch = parsed.data;
  const kind = existing.kind as EventKind;

  // Resolve a new main-tz start if the patch moves a deadline (directly or via origin tz).
  let startWall = patch.start ?? undefined;
  if (kind === "deadline" && !patch.start && patch.originAt) {
    const originTz = patch.originTz ?? existing.originTz;
    if (originTz) startWall = convertWallClock(patch.originAt, originTz, await getMainTz(userId));
  }

  // Re-validate the resolved event against its (unchanged) kind.
  if (kind === "deadline") {
    const effStart = startWall ?? formatWallClock(existing.start, false);
    const issues = eventSemanticIssues("deadline", effStart, effStart, null);
    if (issues.length) throw new EventValidationError(issues.join("; "));
  } else {
    const allDay = kind === "band";
    const mergedStart = patch.start ?? formatWallClock(existing.start, allDay);
    const mergedEnd = patch.end ?? formatWallClock(existing.end, allDay);
    const mergedTrack = patch.track !== undefined ? patch.track ?? null : existing.track;
    const issues = eventSemanticIssues(kind, mergedStart, mergedEnd, mergedTrack);
    if (issues.length) throw new EventValidationError(issues.join("; "));
  }

  const data = eventUpdateData(patch, kind, startWall);
  const row = await prisma.calendarItem.update({
    where: { id },
    data: { ...data, ...(actor === "ai" ? { createdByAI: true } : {}) },
  });
  const ev = toApiEvent(row);
  if (actor === "ai") await logAiAction(userId, "update", before, ev).catch(() => {});
  return ev;
}

export interface DeleteResult { ok: true; mode: "series" | "occurrence"; id: string }

// Delete an event. With `occurrenceDate` (YYYY-MM-DD) on a recurring event, punches a hole by
// appending to repeat.exdates (series preserved); otherwise deletes the event/series. Shared by the
// DELETE route and the assistant's confirm-gated delete execution.
export async function deleteEventForUser(userId: string, id: string, occurrenceDate?: string, actor: "user" | "ai" = "user"): Promise<DeleteResult> {
  const existing = await prisma.calendarItem.findFirst({ where: { id, userId } });
  if (!existing) throw new EventNotFoundError();
  const before = toApiEvent(existing);

  if (occurrenceDate) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(occurrenceDate)) throw new EventValidationError("occurrenceDate must be YYYY-MM-DD");
    const repeat = (existing.repeat as Repeat | null) ?? { kind: "none" };
    if (repeat.kind && repeat.kind !== "none") {
      const exdates = Array.from(new Set([...(repeat.exdates ?? []), occurrenceDate]));
      const updated = await prisma.calendarItem.update({ where: { id }, data: { repeat: { ...repeat, exdates } as unknown as Prisma.InputJsonValue } });
      if (actor === "ai") await logAiAction(userId, "delete", before, toApiEvent(updated), occurrenceDate).catch(() => {});
      return { ok: true, mode: "occurrence", id };
    }
    // Not recurring → "this occurrence" is the whole event.
  }
  await prisma.calendarItem.delete({ where: { id } });
  if (actor === "ai") await logAiAction(userId, "delete", before, null, occurrenceDate).catch(() => {});
  return { ok: true, mode: "series", id };
}

// ── AI operation log (design §16 / ActionLog): durable, per-user record of AI calendar
// mutations so the user can review and back-track them, independent of the in-session ⌘Z stack.
// Payload stores before/after ApiEvent snapshots → revert is a per-op inverse.

interface OpPayload { eventId?: string; before: ApiEvent | null; after: ApiEvent | null; occurrenceDate: string | null }

async function logAiAction(userId: string, kind: "create" | "update" | "delete", before: ApiEvent | null, after: ApiEvent | null, occurrenceDate?: string): Promise<void> {
  const payload: OpPayload = { eventId: (after ?? before)?.id, before, after, occurrenceDate: occurrenceDate ?? null };
  await prisma.actionLog.create({ data: { userId, actor: "AI", kind, status: "APPLIED", payload: payload as unknown as Prisma.InputJsonValue } });
}

/** An ApiEvent snapshot → a create-route body (to restore it verbatim, preserving id + provenance). */
function apiEventToCreateBody(ev: ApiEvent) {
  return {
    id: ev.id, kind: ev.kind, title: ev.title, notes: ev.notes, color: ev.color,
    start: ev.start, end: ev.end, track: ev.track, originTz: ev.originTz,
    tags: ev.tags, repeat: ev.repeat, createdByAI: ev.createdByAI,
  };
}

export interface AiActionSummary { id: string; kind: string; status: string; createdAt: string; title: string; occurrenceDate: string | null }

export async function listAiActions(userId: string): Promise<AiActionSummary[]> {
  const rows = await prisma.actionLog.findMany({ where: { userId, actor: "AI" }, orderBy: { createdAt: "desc" }, take: 50 });
  return rows.map((r) => {
    const p = r.payload as unknown as OpPayload;
    return { id: r.id, kind: r.kind, status: r.status, createdAt: r.createdAt.toISOString(), title: (p.after ?? p.before)?.title ?? "event", occurrenceDate: p.occurrenceDate ?? null };
  });
}

// Per-op inverse: create → delete the event; update/delete → restore the before-snapshot. Also
// marks this op AND any newer AI ops on the SAME event as reverted (reverting a create removes the
// event, so later edits to it are moot — matches the user's "back-track the creation" intent).
export async function revertAiAction(userId: string, logId: string): Promise<{ ok: true }> {
  const entry = await prisma.actionLog.findFirst({ where: { id: logId, userId, actor: "AI" } });
  if (!entry) throw new EventNotFoundError();
  if (entry.status === "REVERTED") throw new EventValidationError("This action was already reverted.");
  const p = entry.payload as unknown as OpPayload;

  if (!p.before && p.after) {
    await deleteEventForUser(userId, p.after.id).catch((e) => { if (!(e instanceof EventNotFoundError)) throw e; });
  } else if (p.before) {
    await deleteEventForUser(userId, p.before.id).catch((e) => { if (!(e instanceof EventNotFoundError)) throw e; });
    await createEventForUser(userId, apiEventToCreateBody(p.before), "user");
  }

  const eventId = p.eventId ?? (p.after ?? p.before)?.id;
  await prisma.actionLog.updateMany({
    where: { userId, actor: "AI", status: "APPLIED", createdAt: { gte: entry.createdAt }, ...(eventId ? { payload: { path: ["eventId"], equals: eventId } } : {}) },
    data: { status: "REVERTED" },
  });
  return { ok: true };
}
