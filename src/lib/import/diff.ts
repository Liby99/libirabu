// Diff incoming normalized events against existing calendar rows → preview groups
// (docs/calendar-import-design.md §6). Tier-1 (exact UID → duplicate/merge), tier-2 (fuzzy name+time
// with no UID match → "decide", ranked candidates the user confirms, with an AI hint added later),
// tier-3 (nothing similar → new).
//
// Pure: the DB read lives in the API route, which passes ExistingEventRow[] here. The AI suggestion
// (§6.3) is layered on afterward in service.ts — it only annotates the `decide` items diff produces.

import type { NormalizedEvent, PreviewGroups, PreviewItem, MatchCandidate } from "./types";
import { fuzzyCandidates } from "./fuzzy";

/** The slice of an existing CalendarItem needed for matching/preview. */
export interface ExistingEventRow {
  id: string;
  title: string;
  start: string;
  end: string;
  externalUid: string | null;
  connectionId: string | null;
  hidden?: boolean; // soft-deleted → a UID match here suppresses re-import (the user dismissed it)
  externalEtag?: string | null; // change token — a matching etag means the event is unchanged (skip)
}

export function diffEvents(incoming: NormalizedEvent[], existing: ExistingEventRow[]): PreviewGroups {
  // Index existing events by UID (cross-source: the same event from .ics or Apple shares a UID).
  const byUid = new Map<string, ExistingEventRow>();
  for (const row of existing) if (row.externalUid) byUid.set(row.externalUid, row);

  const groups: PreviewGroups = { new: [], decide: [], duplicate: [] };

  incoming.forEach((ev, i) => {
    const tempId = `t${i}`;
    const uidMatch = ev.externalUid ? byUid.get(ev.externalUid) : undefined;

    // Dismissed (hidden) → the user soft-deleted this imported event; don't re-import or re-show it.
    if (uidMatch?.hidden) return;

    // Incremental re-sync: an unchanged event (same change-token) has nothing to do → skip it, so a
    // re-sync only surfaces NEW and CHANGED events instead of every occurrence again.
    if (uidMatch && ev.externalEtag && uidMatch.externalEtag && ev.externalEtag === uidMatch.externalEtag) return;

    if (uidMatch) {
      const match: MatchCandidate = {
        targetId: uidMatch.id,
        title: uidMatch.title,
        start: uidMatch.start,
        end: uidMatch.end,
        matchedBy: "uid",
        reason: "same UID",
      };
      const item: PreviewItem = { tempId, incoming: ev, tier: "duplicate", match, defaultAction: "merge" };
      groups.duplicate.push(item);
    } else {
      // tier-2: no UID match, but a close title + nearby time → ask the user (candidates ranked).
      const candidates = fuzzyCandidates(ev, existing);
      if (candidates.length) {
        // Default to "create" (additive-safe) until the AI hint / user flips it to a merge.
        groups.decide.push({ tempId, incoming: ev, tier: "decide", match: candidates[0], candidates, suggestion: null, defaultAction: "create" });
      } else {
        // tier-3: nothing similar → import as new.
        groups.new.push({ tempId, incoming: ev, tier: "new", defaultAction: "create" });
      }
    }
  });

  return groups;
}
