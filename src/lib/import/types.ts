// Shared types for calendar import (docs/calendar-import-design.md). Pure types only — safe to
// import from server routes, the normalize/diff pipeline, and client preview UI alike.
//
// Pipeline shape: a source (Apple EventKit bridge or a parsed .ics) is turned into
// NormalizedEvent[] (source-agnostic, main-tz wall-clock), diffed against existing CalendarItems
// into PreviewItem[] grouped by tier, reviewed by the user, then committed via the shared
// createEventForUser / updateEventForUser write path.

import type { EventKind, Repeat } from "@/lib/calendar/api";

/** Where an imported event came from. Mirrors CalendarItem.source ("manual" is native, not imported). */
export type ImportSource = "apple" | "ical" | "google";

/** An attendee's RSVP, normalized across sources (EventKit EKParticipantStatus / iCal PARTSTAT). */
export type AttendeeStatus = "accepted" | "declined" | "tentative" | "needs-action" | "unknown";

export interface Attendee {
  name?: string;
  email?: string;
  status: AttendeeStatus;
}

/** Raw vendor-owned details that get rendered into the managed note block (§7.1). */
export interface VendorDetails {
  location?: string | null;
  meetingUrl?: string | null; // hangout / conference / Zoom link
  organizer?: string | null;
  attendees?: Attendee[];
  description?: string | null; // the vendor's own notes/description (markdown-escaped on render)
  status?: string | null; // confirmed | tentative | cancelled
}

/**
 * A source event after normalization: schedule expressed as main-tz floating wall-clock strings
 * (identical convention to ApiEvent), provenance/dedup keys filled, and raw vendor details kept
 * aside for the managed note block. Source-agnostic past the fetch step.
 */
export interface NormalizedEvent {
  source: ImportSource;

  // identity / provenance / dedup
  externalUid: string | null; // iCalUID / EKEvent.calendarItemExternalIdentifier — the dedup key
  externalId: string | null; // source-native id (Apple: calendarItemIdentifier)
  externalEtag: string | null; // change token (Apple: lastModifiedDate)
  externalUrl: string | null; // "open at source" deep link
  connectionId: string | null; // CalendarConnection.id (Apple); null for .ics
  provenance: string; // human label, e.g. "Apple · Google · Liby's Work"

  // schedule (main-tz wall-clock; same shapes as ApiEvent.start/end)
  kind: EventKind;
  title: string;
  start: string;
  end: string;
  allDay: boolean;
  track: number | null;
  color?: string | null;
  tags?: string[];
  repeat: Repeat;
  repeatSimplified?: boolean; // true when an RRULE couldn't be fully mapped → preview flag (§8)

  // raw details → managed note block
  vendor: VendorDetails;
}

/**
 * A single point in time as a source reports it. `dateOnly` events (all-day) carry a "YYYY-MM-DD"
 * value; timed events carry an ISO-8601 instant (with offset). normalize.ts turns both into the
 * app's main-tz floating wall-clock.
 */
export interface RawInstant {
  value: string; // "YYYY-MM-DD" when dateOnly; otherwise an ISO instant ("…T…±hh:mm" / "…Z")
  dateOnly: boolean;
}

/**
 * Source-neutral event straight off a fetch (parsed VEVENT, or the Apple EventKit bridge in P2),
 * before any app-specific normalization. normalize.ts maps this → NormalizedEvent. Keeping this
 * intermediate is what lets normalize/diff/preview/commit stay identical across sources.
 */
export interface RawSourceEvent {
  source: ImportSource;
  uid: string | null;
  nativeId: string | null; // source-native id (Apple: calendarItemIdentifier)
  url: string | null; // open-at-source deep link
  etag: string | null; // change token (lastmodified ISO / etag)
  connectionId: string | null;
  provenance: string; // human label ("Apple · Google · Liby's Work", or "file.ics")

  title: string;
  start: RawInstant;
  end: RawInstant | null; // for all-day, this is EXCLUSIVE (RFC) — normalize makes it inclusive

  rrule: string | null; // RFC 5545 RRULE body (no "RRULE:" prefix); null = single occurrence
  exdates: string[]; // "YYYY-MM-DD" occurrences removed

  tags?: string[];
  color?: string | null;
  vendor: VendorDetails;
}

/** What the user (or default policy) chooses to do with a preview row at commit time. */
export type CommitAction = "create" | "merge" | "skip";

/** Which review bucket a preview row falls into (§6.2). */
export type PreviewTier = "new" | "decide" | "duplicate";

/** An existing CalendarItem an incoming event might be the same as. */
export interface MatchCandidate {
  targetId: string; // existing CalendarItem.id
  title: string;
  start: string;
  end: string;
  matchedBy: "uid" | "fuzzy";
  reason?: string; // short human note (e.g. "same UID", "same title, same day")
}

/** AI advice for an ambiguous (tier-2) match — advisory only; the user decides (§6.3). */
export interface DedupSuggestion {
  same: boolean;
  confidence: number; // 0..1
  suggestion: "merge" | "keep_both";
  reason: string; // one line shown in the modal
}

/** One row in the import preview. `tempId` is stable so the client can echo selections back. */
export interface PreviewItem {
  tempId: string;
  incoming: NormalizedEvent;
  tier: PreviewTier;
  match?: MatchCandidate | null; // the resolved duplicate (tier 1) or top candidate (tier 2)
  candidates?: MatchCandidate[]; // ranked options for tier 2
  suggestion?: DedupSuggestion | null; // AI hint (tier 2)
  defaultAction: CommitAction; // pre-selected action
}

/** The preview response: incoming events bucketed by tier. */
export interface PreviewGroups {
  new: PreviewItem[];
  decide: PreviewItem[];
  duplicate: PreviewItem[];
}

/** A user's per-row decision sent to /import/commit. */
export interface CommitSelection {
  tempId: string;
  action: CommitAction;
  targetId?: string; // required when action === "merge"
}

/** The commit response. */
export interface CommitResult {
  created: number;
  merged: number;
  skipped: number;
  failed: number; // events that errored individually (import continues past them)
  removed?: number; // imported copies deleted because they vanished from the source (Apple re-sync)
}

/** An imported event that is no longer present in the source calendar (deleted upstream). */
export interface RemovedItem {
  id: string; // existing CalendarItem.id
  title: string;
  start: string;
  end: string;
}

/** A pending tier-2 dedup decision, as shown in the Triage box (persisted; resolvable any time). */
export interface TriageEntry {
  id: string; // TriageItem.id
  source: ImportSource;
  incoming: NormalizedEvent;
  candidates: MatchCandidate[]; // existing events it might duplicate
  suggestion: DedupSuggestion | null; // AI hint
  createdAt: string; // ISO
}

/** One connected external calendar, as shown in the Connectivity menu. */
export interface ConnectionRow {
  id: string; // CalendarConnection.id
  calName: string;
  accountLabel: string; // EKSource title (iCloud / Google / …)
  color: string | null;
  enabled: boolean;
  lastSyncedAt: string | null; // ISO
}
