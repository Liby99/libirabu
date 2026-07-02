// Tier-2 fuzzy matching (docs/calendar-import-design.md §6.2). Pure & deterministic: given one
// incoming event and the pool of existing calendar rows, return the ranked existing events that
// look like the SAME real-world event — a close title AND a start time inside a window. These
// candidates go to the "decide" bucket for the user to confirm (with an AI hint, §6.3). Kept
// separate from diff.ts so it's unit-testable in isolation.

import type { NormalizedEvent, MatchCandidate } from "./types";
import type { ExistingEventRow } from "./diff";

// Candidate thresholds (tunable). Title similarity is a Dice bigram ratio in [0,1]; the time window
// is same-calendar-day for all-day/band events, ±2 h for timed ones (§6.2 / §10 defaults).
const TITLE_THRESHOLD = 0.68;
const TIMED_WINDOW_MS = 2 * 60 * 60 * 1000;

/** Case/punctuation/whitespace-insensitive title key. */
export function normTitle(s: string): string {
  return s.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim().replace(/\s+/g, " ");
}

/** Dice coefficient over character bigrams — cheap, forgiving of small edits ("Sync" vs "sync up"). */
export function titleSim(a: string, b: string): number {
  const na = normTitle(a), nb = normTitle(b);
  if (!na || !nb) return 0;
  if (na === nb) return 1;
  if (na.length < 2 || nb.length < 2) return na === nb ? 1 : 0;
  const bigrams = (s: string) => {
    const m = new Map<string, number>();
    for (let i = 0; i < s.length - 1; i++) { const g = s.slice(i, i + 2); m.set(g, (m.get(g) ?? 0) + 1); }
    return m;
  };
  const ba = bigrams(na), bb = bigrams(nb);
  let inter = 0, total = 0;
  for (const c of ba.values()) total += c;
  for (const c of bb.values()) total += c;
  for (const [g, c] of ba) { const d = bb.get(g); if (d) inter += Math.min(c, d); }
  return total ? (2 * inter) / total : 0;
}

// Wall-clock strings share the app's main tz on both sides, so a naive local parse is fine for a diff.
const isDateOnly = (s: string) => !s.includes("T");
const toMs = (s: string) => new Date(s).getTime();
const sameDay = (a: string, b: string) => a.slice(0, 10) === b.slice(0, 10);

function timeClose(inc: NormalizedEvent, rowStart: string): boolean {
  if (inc.allDay || inc.kind === "band" || isDateOnly(rowStart)) return sameDay(inc.start, rowStart);
  const d = Math.abs(toMs(inc.start) - toMs(rowStart));
  return Number.isFinite(d) && d <= TIMED_WINDOW_MS;
}

/**
 * Rank existing rows that could be the same event as `inc`: normalized-title similarity ≥ threshold
 * AND start time within the window. Hidden (dismissed) rows are never candidates. Returns the top 3,
 * best first (higher title similarity, then closer in time).
 */
export function fuzzyCandidates(inc: NormalizedEvent, pool: ExistingEventRow[]): MatchCandidate[] {
  const scored: { c: MatchCandidate; sim: number; dt: number }[] = [];
  for (const row of pool) {
    if (row.hidden) continue;
    const sim = titleSim(inc.title, row.title);
    if (sim < TITLE_THRESHOLD) continue;
    if (!timeClose(inc, row.start)) continue;
    const dt = isDateOnly(row.start) ? 0 : Math.abs(toMs(inc.start) - toMs(row.start));
    scored.push({
      sim, dt,
      c: {
        targetId: row.id, title: row.title, start: row.start, end: row.end,
        matchedBy: "fuzzy",
        reason: sim > 0.999 ? "same title, same time" : "similar title, same time",
      },
    });
  }
  scored.sort((a, b) => b.sim - a.sim || a.dt - b.dt);
  return scored.slice(0, 3).map((s) => s.c);
}
