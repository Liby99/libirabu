// In-process background sync scheduler (docs/calendar-import-design.md §12.3). Started once from
// instrumentation.ts when the server boots. Every ~20 min it pulls each user's enabled Apple
// calendars and applies the safe tiers (autoSyncAll in ./service.ts). It runs INSIDE the Next
// server process, so the EventKit bridge inherits the server's Calendar (TCC) grant — which only
// holds under the LaunchServices-launched menu-bar app, hence we gate on production in
// instrumentation.ts. The latest result is kept in memory for the client to poll (sync-status).

import { autoSyncAll, usersWithEnabledConnections } from "./service";

const DEFAULT_INTERVAL_MS = 20 * 60 * 1000; // 20 min — calendars don't change second-to-second
const FIRST_RUN_DELAY_MS = 30 * 1000; // let the server settle before the first pull

export interface AutoSyncStatus {
  lastRunAt: string | null; // ISO of the last completed tick
  running: boolean;
  created: number; // totals from the last tick
  merged: number;
  toTriage: number;
  removedFlagged: number;
}

let status: AutoSyncStatus = { lastRunAt: null, running: false, created: 0, merged: 0, toTriage: 0, removedFlagged: 0 };
export function getAutoSyncStatus(): AutoSyncStatus { return status; }

let ticking = false;
async function tick(): Promise<void> {
  if (ticking) return; // never overlap a slow pull with the next tick
  ticking = true;
  status = { ...status, running: true };
  try {
    let created = 0, merged = 0, toTriage = 0, removedFlagged = 0;
    for (const userId of await usersWithEnabledConnections()) {
      const s = await autoSyncAll(userId);
      created += s.created; merged += s.merged; toTriage += s.toTriage; removedFlagged += s.removedFlagged;
    }
    status = { lastRunAt: new Date().toISOString(), running: false, created, merged, toTriage, removedFlagged };
    if (created || merged || toTriage || removedFlagged) {
      console.log(`[autosync] +${created} new · ~${merged} updated · ${toTriage}→triage · ${removedFlagged} removed-flagged`);
    }
  } catch (e) {
    console.warn("[autosync] tick error:", e instanceof Error ? e.message : e);
    status = { ...status, running: false };
  } finally {
    ticking = false;
  }
}

/** Start the periodic sync. Idempotent — guarded so double-registration (HMR / re-import) is a no-op. */
export function startAutoSync(): void {
  const g = globalThis as unknown as { __libAutoSyncStarted?: boolean };
  if (g.__libAutoSyncStarted) return;
  g.__libAutoSyncStarted = true;
  const interval = Number(process.env.AUTO_SYNC_INTERVAL_MS) || DEFAULT_INTERVAL_MS;
  console.log(`[autosync] enabled — every ${Math.round(interval / 60000)} min`);
  setTimeout(() => { void tick(); }, FIRST_RUN_DELAY_MS);
  setInterval(() => { void tick(); }, interval);
}
