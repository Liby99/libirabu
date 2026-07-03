// Server-side import service (docs/calendar-import-design.md §9). Composes the pure core
// (parse/fetch → normalize → diff) with the DB and the shared write helpers. Both sources — an
// uploaded .ics blob and the Apple Calendar bridge — funnel through the same diff/preview/commit;
// commit re-derives the deterministic preview and applies the user's per-tempId selections, so no
// un-trusted event payloads travel back from the client.

import { prisma } from "@/lib/prisma";
import { Prisma } from "@/generated/prisma/client";
import { formatWallClock } from "@/lib/calendar/api";
import {
  getMainTz, createEventForUser, updateEventForUser, deleteEventForUser, EventNotFoundError, EventValidationError, type ImportProvenance,
} from "@/app/api/calendar/_helpers";
import { parseIcs } from "./ical";
import { fetchAppleEvents, listAppleCalendars, type AppleCalendar } from "./apple";
import { normalizeEvents } from "./normalize";
import { diffEvents, type ExistingEventRow } from "./diff";
import { renderManagedNote, composeNote, replaceManaged } from "./managedNote";
import { suggestDedup } from "./aiDedup";
import { normTitle } from "./fuzzy";
import { runWithUserKeys } from "@/lib/apiKeys";
import type { NormalizedEvent, PreviewGroups, PreviewItem, CommitSelection, CommitResult, CommitAction, MatchCandidate, DedupSuggestion, ConnectionRow, RemovedItem, TriageEntry, ImportSource } from "./types";

export interface ImportPreview {
  groups: PreviewGroups;
  /** Count of source all-day events dropped by policy (birthdays/holidays; §8). */
  ignoredAllDay: number;
  /** Diagnostics so "nothing to import" is never mysterious. */
  stats: { parsed: number; timed: number; allDay: number };
  /** Imported events (this connection, within the sync window) that vanished from the source (§10 P4). */
  removed?: RemovedItem[];
}
export type IcsPreview = ImportPreview; // back-compat alias

/** The pool of existing events to diff against: UID-bearing rows for tier-1, PLUS manual (no-UID)
 *  events, since a fuzzy tier-2 match may be against something the user typed by hand (§6.2). */
async function existingRows(userId: string): Promise<ExistingEventRow[]> {
  const rows = await prisma.calendarItem.findMany({
    where: { userId },
    select: { id: true, title: true, start: true, end: true, kind: true, externalUid: true, connectionId: true, hidden: true, externalEtag: true },
  });
  return rows.map((r) => ({
    id: r.id,
    title: r.title,
    start: formatWallClock(r.start, r.kind === "band"),
    end: formatWallClock(r.end, r.kind === "band"),
    externalUid: r.externalUid,
    connectionId: r.connectionId,
    hidden: r.hidden,
    externalEtag: r.externalEtag,
  }));
}

/** Diff a batch of normalized events into preview groups + assemble the ImportPreview envelope.
 *  `withAi` adds the tier-2 AI hint (§6.3) — on for the preview the user reviews, off for the commit
 *  re-derivation (which only needs the deterministic groups; tempIds are stable either way). */
async function previewOf(userId: string, events: NormalizedEvent[], allDay: NormalizedEvent[], parsed: number, withAi = false): Promise<ImportPreview> {
  const groups = diffEvents(events, await existingRows(userId));
  if (withAi && groups.decide.length) {
    const hints = await runWithUserKeys(userId, () => suggestDedup(groups.decide));
    for (const it of groups.decide) {
      const s = hints.get(it.tempId);
      if (!s) continue;
      it.suggestion = s;
      // Pre-select merge only on a confident same-event verdict; otherwise leave the safe "create".
      if (s.same && s.suggestion === "merge" && s.confidence >= 0.6) it.defaultAction = "merge";
    }
  }
  return { groups, ignoredAllDay: allDay.length, stats: { parsed, timed: events.length, allDay: allDay.length } };
}

// ── Triage: persist tier-2 ambiguities so they can be resolved later (even outside a sync) ───────
/** A stable per-event key so repeated syncs UPSERT the same pending item instead of piling copies. */
function triageKey(ev: NormalizedEvent): string {
  return `${ev.source}:${ev.externalUid ?? `${normTitle(ev.title)}@${ev.start}`}`;
}

/** Write this sync's tier-2 "decide" items to the Triage store (upsert by key). For a connection
 *  sync, prune pending items that are no longer ambiguous (resolved elsewhere, or became tier-1). */
async function persistTriage(userId: string, source: ImportSource, connectionId: string | null, decide: PreviewItem[]): Promise<void> {
  const keep: string[] = [];
  for (const it of decide) {
    const ev = it.incoming;
    const dedupKey = triageKey(ev);
    keep.push(dedupKey);
    const payload = ev as unknown as Prisma.InputJsonValue;
    const candidates = (it.candidates ?? []) as unknown as Prisma.InputJsonValue;
    const suggestion = it.suggestion ? (it.suggestion as unknown as Prisma.InputJsonValue) : Prisma.DbNull;
    await prisma.triageItem.upsert({
      where: { userId_dedupKey: { userId, dedupKey } },
      create: { userId, source, connectionId, dedupKey, payload, candidates, suggestion },
      update: { source, connectionId, payload, candidates, suggestion },
    });
  }
  if (connectionId) await prisma.triageItem.deleteMany({ where: { userId, connectionId, dedupKey: { notIn: keep } } });
}

/** Pending Triage entries, newest first. */
export async function listTriage(userId: string): Promise<TriageEntry[]> {
  const rows = await prisma.triageItem.findMany({ where: { userId }, orderBy: { createdAt: "desc" } });
  return rows.map((r) => ({
    id: r.id,
    source: r.source as ImportSource,
    incoming: r.payload as unknown as NormalizedEvent,
    candidates: (r.candidates as unknown as MatchCandidate[]) ?? [],
    suggestion: (r.suggestion as unknown as DedupSuggestion | null) ?? null,
    createdAt: r.createdAt.toISOString(),
  }));
}

export async function triageCount(userId: string): Promise<number> {
  return prisma.triageItem.count({ where: { userId } });
}

/** Resolve one Triage entry — create it as new, merge into a candidate, or dismiss (skip). The
 *  pending item is removed either way. A merge target is validated against the stored candidates. */
export async function resolveTriage(userId: string, id: string, action: CommitAction, targetId?: string): Promise<CommitResult> {
  const row = await prisma.triageItem.findFirst({ where: { id, userId } });
  if (!row) throw new EventValidationError("triage item not found");
  const ev = row.payload as unknown as NormalizedEvent;
  const candidates = (row.candidates as unknown as MatchCandidate[]) ?? [];
  const act: CommitAction = action === "merge" && !(targetId && mergeAllowed(candidates[0], candidates, targetId)) ? "skip" : action;
  const outcome = await applyEvent(userId, ev, act, targetId);
  await prisma.triageItem.delete({ where: { id: row.id } });
  return { created: +(outcome === "created"), merged: +(outcome === "merged"), skipped: +(outcome === "skipped"), failed: +(outcome === "failed") };
}

const provenanceOf = (ev: NormalizedEvent): ImportProvenance => ({
  source: ev.source,
  externalUid: ev.externalUid,
  externalId: ev.externalId,
  externalEtag: ev.externalEtag,
  externalUrl: ev.externalUrl,
  connectionId: ev.connectionId,
});

/** Body for createEventForUser from a normalized event + fully-composed note. */
function createBody(ev: NormalizedEvent, notes: string) {
  return {
    kind: ev.kind,
    title: ev.title,
    notes,
    start: ev.start,
    end: ev.end,
    track: ev.track ?? undefined, // band lane 0–3; omit for timed
    color: ev.color || undefined,
    tags: ev.tags ?? [],
    repeat: ev.repeat,
  };
}

/** A merge target must be one the pipeline itself proposed (a tier-1 match or a tier-2 candidate) —
 *  so a client can't redirect a merge onto an arbitrary event. */
function mergeAllowed(match: MatchCandidate | null | undefined, candidates: MatchCandidate[] | undefined, targetId: string): boolean {
  return match?.targetId === targetId || (candidates ?? []).some((c) => c.targetId === targetId);
}

/** Create or merge one normalized event (shared by import-commit and triage-resolve). Per-event
 *  isolation: a single malformed event must not abort the whole (possibly large) import. */
async function applyEvent(userId: string, ev: NormalizedEvent, action: CommitAction, targetId?: string): Promise<"created" | "merged" | "skipped" | "failed"> {
  if (action === "skip") return "skipped";
  const managed = renderManagedNote(ev.vendor, { provenance: ev.provenance, uid: ev.externalUid, rev: ev.externalEtag });
  try {
    if (action === "create") {
      await createEventForUser(userId, createBody(ev, composeNote(managed, "")), "user", provenanceOf(ev));
      return "created";
    }
    if (action === "merge" && targetId) {
      // Merge into the existing event: swap the managed block, keep the user's postfix; vendor owns title/time.
      const existing = await prisma.calendarItem.findFirst({ where: { id: targetId, userId }, select: { notes: true } });
      const notes = replaceManaged(existing?.notes ?? "", managed);
      await updateEventForUser(userId, targetId, { title: ev.title, notes, start: ev.start, end: ev.end, repeat: ev.repeat }, "user", provenanceOf(ev));
      return "merged";
    }
    return "skipped";
  } catch (e) {
    console.warn("[import] skipped one event:", ev.title, e instanceof Error ? e.message : e);
    return "failed";
  }
}

/** Apply per-tempId selections against a freshly-derived preview. Shared by every source. */
async function applySelections(userId: string, groups: PreviewGroups, selections: CommitSelection[]): Promise<CommitResult> {
  const byTemp = new Map<string, PreviewItem>();
  for (const bucket of [groups.new, groups.decide, groups.duplicate]) for (const it of bucket) byTemp.set(it.tempId, it);

  const tally = { created: 0, merged: 0, skipped: 0, failed: 0 };
  for (const sel of selections) {
    const item = byTemp.get(sel.tempId);
    if (!item) { tally.skipped++; continue; }
    // Reject a merge redirected off the proposed targets → treat as skip.
    const action: CommitAction = sel.action === "merge" && !(sel.targetId && mergeAllowed(item.match, item.candidates, sel.targetId)) ? "skip" : sel.action;
    tally[await applyEvent(userId, item.incoming, action, sel.targetId)]++;
  }
  return tally;
}

// ── .ics source ────────────────────────────────────────────────────────────────────────────────
export async function buildIcsPreview(userId: string, icsText: string, filename?: string): Promise<ImportPreview> {
  const mainTz = await getMainTz(userId);
  const raws = parseIcs(icsText, { provenance: filename });
  const { events, allDay } = normalizeEvents(raws, mainTz);
  if (raws.length === 0) console.warn("[import] parsed 0 VEVENTs from .ics — parser found no events");
  const preview = await previewOf(userId, events, allDay, raws.length, true);
  await persistTriage(userId, "ical", null, preview.groups.decide);
  return preview;
}

export async function commitIcs(userId: string, icsText: string, filename: string | undefined, selections: CommitSelection[]): Promise<CommitResult> {
  // Re-derive the deterministic groups (no AI — the client already sent its per-tempId decisions).
  const mainTz = await getMainTz(userId);
  const raws = parseIcs(icsText, { provenance: filename });
  const { events, allDay } = normalizeEvents(raws, mainTz);
  const { groups } = await previewOf(userId, events, allDay, raws.length);
  return applySelections(userId, groups, selections);
}

// ── Apple Calendar source ────────────────────────────────────────────────────────────────────
/** Rolling window for a sync (§11): −1 month … +12 months. The bridge's ISO8601 parser is strict
 *  (no fractional seconds), so drop the milliseconds `toISOString()` emits. */
function syncWindow(): { fromISO: string; toISO: string } {
  const now = new Date();
  const from = new Date(now); from.setUTCMonth(from.getUTCMonth() - 1);
  const to = new Date(now); to.setUTCMonth(to.getUTCMonth() + 12);
  const iso = (d: Date) => d.toISOString().replace(/\.\d{3}Z$/, "Z");
  return { fromISO: iso(from), toISO: iso(to) };
}

// Tags stamped on every event imported from a connection (§ user request): "imported", the account
// (EKSource title, e.g. an email), and a provider guess (iCloud vs an email account → Google).
function importTags(accountLabel: string): string[] {
  const acct = accountLabel.trim();
  const tags = ["imported"];
  if (acct && acct.toLowerCase() !== "imported") tags.push(acct);
  if (/icloud/i.test(acct)) tags.push("iCloud");
  else if (acct.includes("@")) tags.push("Google Calendar");
  return Array.from(new Set(tags));
}

/** Fetch + normalize one Apple connection's events over the sync window. */
async function appleNormalized(userId: string, connectionId: string) {
  const conn = await prisma.calendarConnection.findFirst({ where: { id: connectionId, userId, provider: "apple" } });
  if (!conn) throw new EventValidationError("calendar connection not found");
  const mainTz = await getMainTz(userId);
  const { fromISO, toISO } = syncWindow();
  const raws = await fetchAppleEvents(conn.externalCalId, fromISO, toISO, {
    provenance: `Apple · ${conn.accountLabel} · ${conn.calName}`,
    connectionId: conn.id,
    tags: importTags(conn.accountLabel),
  });
  const { events, allDay } = normalizeEvents(raws, mainTz);
  const fetchedUids = new Set(raws.map((r) => r.uid).filter((u): u is string => !!u));
  return { events, allDay, parsed: raws.length, connectionId, from: new Date(fromISO), to: new Date(toISO), fetchedUids };
}

/** Events imported from this connection, within the fetch window, whose UID vanished from the source. */
async function detectRemoved(userId: string, connectionId: string, from: Date, to: Date, fetchedUids: Set<string>): Promise<RemovedItem[]> {
  const rows = await prisma.calendarItem.findMany({
    where: { userId, connectionId, hidden: false, externalUid: { not: null }, start: { gte: from, lt: to } },
    select: { id: true, title: true, start: true, end: true, kind: true, externalUid: true },
  });
  return rows
    .filter((r) => r.externalUid && !fetchedUids.has(r.externalUid))
    .map((r) => ({ id: r.id, title: r.title, start: formatWallClock(r.start, r.kind === "band"), end: formatWallClock(r.end, r.kind === "band") }));
}

export async function buildApplePreview(userId: string, connectionId: string): Promise<ImportPreview> {
  const n = await appleNormalized(userId, connectionId);
  const preview = await previewOf(userId, n.events, n.allDay, n.parsed, true);
  await persistTriage(userId, "apple", connectionId, preview.groups.decide);
  const removed = await detectRemoved(userId, n.connectionId, n.from, n.to, n.fetchedUids);
  return { ...preview, removed };
}

export async function commitApple(userId: string, connectionId: string, selections: CommitSelection[], removeIds: string[] = []): Promise<CommitResult> {
  const n = await appleNormalized(userId, connectionId);
  const groups = (await previewOf(userId, n.events, n.allDay, n.parsed)).groups;
  const res = await applySelections(userId, groups, selections);

  // Deleted-upstream: hard-delete the user-selected imported copies whose source event is gone.
  let removed = 0;
  if (removeIds.length) {
    const removable = new Set((await detectRemoved(userId, n.connectionId, n.from, n.to, n.fetchedUids)).map((r) => r.id));
    for (const id of removeIds) {
      if (!removable.has(id)) continue; // only delete events genuinely absent from the source
      try { await deleteEventForUser(userId, id); removed++; } catch (e) { if (!(e instanceof EventNotFoundError)) throw e; }
    }
  }

  await prisma.calendarConnection.update({ where: { id: connectionId }, data: { lastSyncedAt: new Date() } });
  return { ...res, removed };
}

// ── Background auto-sync (§12.3) ─────────────────────────────────────────────────────────────
// A periodic, no-human-in-the-loop pull. To stay safe it applies ONLY the unambiguous tiers:
// new events (create) and tier-1 UID matches (merge/refresh) — both additive and reversible.
// Tier-2 ambiguities are parked in Triage as usual; removed-upstream events are only COUNTED
// (flagged), never auto-deleted. The scheduler lives in ./autoSync.ts.

export interface AutoSyncConnResult { connectionId: string; calName: string; created: number; merged: number; toTriage: number; removedFlagged: number }
export interface AutoSyncSummary { userId: string; connections: AutoSyncConnResult[]; created: number; merged: number; toTriage: number; removedFlagged: number }

async function autoSyncConnection(userId: string, connectionId: string): Promise<AutoSyncConnResult | null> {
  const conn = await prisma.calendarConnection.findFirst({ where: { id: connectionId, userId, provider: "apple", enabled: true } });
  if (!conn) return null;
  const n = await appleNormalized(userId, connectionId);
  const preview = await previewOf(userId, n.events, n.allDay, n.parsed, true);
  await persistTriage(userId, "apple", connectionId, preview.groups.decide);

  // Auto-apply ONLY the safe tiers: new (create) + tier-1 duplicates (merge). Never tier-2, never delete.
  const sels: CommitSelection[] = [
    ...preview.groups.new.map((it) => ({ tempId: it.tempId, action: "create" as const })),
    ...preview.groups.duplicate.map((it) => ({ tempId: it.tempId, action: "merge" as const, targetId: it.match?.targetId })),
  ];
  const res = sels.length ? await applySelections(userId, preview.groups, sels) : { created: 0, merged: 0, skipped: 0, failed: 0 };
  const removed = await detectRemoved(userId, n.connectionId, n.from, n.to, n.fetchedUids);
  await prisma.calendarConnection.update({ where: { id: connectionId }, data: { lastSyncedAt: new Date() } });
  return { connectionId, calName: conn.calName, created: res.created, merged: res.merged, toTriage: preview.groups.decide.length, removedFlagged: removed.length };
}

/** Auto-sync every enabled Apple connection for one user — unless they've turned Automatic Sync off.
 *  Per-connection failures are isolated. */
export async function autoSyncAll(userId: string): Promise<AutoSyncSummary> {
  const empty: AutoSyncSummary = { userId, connections: [], created: 0, merged: 0, toTriage: 0, removedFlagged: 0 };
  const pref = await prisma.calendarPrefs.findUnique({ where: { userId }, select: { autoSync: true } });
  if (pref && !pref.autoSync) return empty; // user opted out (no row → default on)
  const conns = await prisma.calendarConnection.findMany({ where: { userId, provider: "apple", enabled: true }, select: { id: true } });
  const results: AutoSyncConnResult[] = [];
  for (const c of conns) {
    try { const r = await autoSyncConnection(userId, c.id); if (r) results.push(r); }
    catch (e) { console.warn(`[autosync] connection ${c.id} failed:`, e instanceof Error ? e.message : e); }
  }
  const sum = (k: "created" | "merged" | "toTriage" | "removedFlagged") => results.reduce((a, r) => a + r[k], 0);
  return { userId, connections: results, created: sum("created"), merged: sum("merged"), toTriage: sum("toTriage"), removedFlagged: sum("removedFlagged") };
}

/** Whether the user has Automatic Sync on (default on when no prefs row exists yet). */
export async function getAutoSyncPref(userId: string): Promise<boolean> {
  const pref = await prisma.calendarPrefs.findUnique({ where: { userId }, select: { autoSync: true } });
  return pref?.autoSync ?? true;
}

/** Turn Automatic Sync on/off. Creates a minimal prefs row if needed (empty track-name map). */
export async function setAutoSyncPref(userId: string, enabled: boolean): Promise<void> {
  await prisma.calendarPrefs.upsert({
    where: { userId },
    create: { userId, autoSync: enabled, trackNames: {} },
    update: { autoSync: enabled },
  });
}

/** Distinct user ids that have at least one enabled Apple connection (drives the scheduler). */
export async function usersWithEnabledConnections(): Promise<string[]> {
  const rows = await prisma.calendarConnection.findMany({ where: { provider: "apple", enabled: true }, select: { userId: true }, distinct: ["userId"] });
  return rows.map((r) => r.userId);
}

// ── Connections (Apple calendar enumeration + persistence) ─────────────────────────────────────
// Auto-generated calendars the user rarely wants imported (§11) → start disabled.
const AUTO_CALENDAR = /^(Birthdays|Siri Suggestions|US Holidays|.*Holidays|Found in (Mail|Apps))$/i;
const defaultEnabled = (c: AppleCalendar) => !AUTO_CALENDAR.test(c.title);

/** Enumerate the Mac's Apple calendars, upserting a CalendarConnection per one; returns the merged list.
 *  Throws AppleBridgeError (no-access / not-built) — the route maps it to a "grant access" response. */
export async function listConnections(userId: string): Promise<ConnectionRow[]> {
  const cals = await listAppleCalendars();
  const existing = await prisma.calendarConnection.findMany({ where: { userId, provider: "apple" } });
  const byCal = new Map(existing.map((r) => [r.externalCalId, r]));

  const rows: ConnectionRow[] = [];
  for (const c of cals) {
    const prior = byCal.get(c.id);
    const color = c.color || null;
    const row = prior
      ? (prior.calName !== c.title || prior.accountLabel !== c.source || prior.color !== color
          ? await prisma.calendarConnection.update({ where: { id: prior.id }, data: { calName: c.title, accountLabel: c.source, color } })
          : prior)
      : await prisma.calendarConnection.create({
          data: { userId, provider: "apple", accountLabel: c.source, externalCalId: c.id, calName: c.title, color, enabled: defaultEnabled(c) },
        });
    rows.push({ id: row.id, calName: row.calName, accountLabel: row.accountLabel, color: row.color, enabled: row.enabled, lastSyncedAt: row.lastSyncedAt?.toISOString() ?? null });
  }
  return rows.sort((a, b) => a.accountLabel.localeCompare(b.accountLabel) || a.calName.localeCompare(b.calName));
}

export async function setConnectionEnabled(userId: string, connectionId: string, enabled: boolean): Promise<void> {
  const conn = await prisma.calendarConnection.findFirst({ where: { id: connectionId, userId } });
  if (!conn) throw new EventValidationError("calendar connection not found");
  await prisma.calendarConnection.update({ where: { id: connectionId }, data: { enabled } });
}

/** Debug/reset: hard-delete ALL imported events (apple/.ics), INCLUDING hidden (dismissed) ones, so
 *  the next sync re-imports from scratch. Manual events — and "internalized" copies, which are
 *  source:"manual" — are kept. Also clears each connection's lastSyncedAt. Returns the deleted count. */
export async function clearAllImported(userId: string): Promise<number> {
  const res = await prisma.calendarItem.deleteMany({ where: { userId, source: { not: "manual" } } });
  await prisma.calendarConnection.updateMany({ where: { userId }, data: { lastSyncedAt: null } });
  await prisma.triageItem.deleteMany({ where: { userId } }); // pending ambiguities are stale after a reset
  return res.count;
}
