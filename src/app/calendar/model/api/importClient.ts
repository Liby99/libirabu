// Client calls for calendar import (docs/calendar-import-design.md §9). Thin fetch wrappers over
// /api/calendar/import/{preview,commit}; the pure preview types come from the shared import module.

import type { PreviewGroups, CommitSelection, CommitAction, CommitResult, ConnectionRow, RemovedItem, TriageEntry } from "@/lib/import/types";

export interface BridgeError { code: string; message: string }

export interface IcsPreviewResponse {
  groups: PreviewGroups;
  ignoredAllDay: number;
  stats: { parsed: number; timed: number; allDay: number };
  removed?: RemovedItem[]; // deleted-upstream imported events (Apple re-sync)
}

/** Apple sync returns a preview OR a bridge error (permission/not-built). */
export type SyncResponse = (IcsPreviewResponse & { bridgeError?: undefined }) | { bridgeError: BridgeError };

export interface ConnectionsResponse { calendars: ConnectionRow[]; bridgeError?: BridgeError }

async function req<T>(method: string, url: string, body?: unknown): Promise<T> {
  const res = await fetch(url, {
    method,
    headers: body !== undefined ? { "Content-Type": "application/json" } : undefined,
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) {
    const msg = (await res.json().catch(() => ({} as { message?: string }))).message;
    throw new Error(msg || `request failed (${res.status})`);
  }
  return res.json() as Promise<T>;
}
const post = <T>(url: string, body: unknown) => req<T>("POST", url, body);

// ── .ics ──
export const importPreviewIcs = (icsText: string, filename?: string) =>
  post<IcsPreviewResponse>("/api/calendar/import/preview", { icsText, filename });
export const importCommitIcs = (icsText: string, filename: string | undefined, selections: CommitSelection[]) =>
  post<CommitResult>("/api/calendar/import/commit", { icsText, filename, selections });

// ── Apple Calendar connections ──
export const fetchConnections = () => req<ConnectionsResponse>("GET", "/api/calendar/connections");
export const setConnectionEnabled = (id: string, enabled: boolean) =>
  req<{ ok: true }>("PATCH", `/api/calendar/connections/${id}`, { enabled });
export const syncConnection = (id: string) => post<SyncResponse>(`/api/calendar/connections/${id}/sync`, {});
export const importCommitApple = (connectionId: string, selections: CommitSelection[], removeIds: string[] = []) =>
  post<CommitResult>("/api/calendar/import/commit", { connectionId, selections, removeIds });

/** Debug/reset: delete ALL imported events (incl. hidden) so the next sync re-imports fresh. */
export const clearAllImported = () => post<{ deleted: number }>("/api/calendar/import/clear", {});

// ── Full backup: export (download) / import (destructive restore) ──
/** Trigger a browser download of the full backup .zip (server names it <app>-<user>-<date>.zip). */
export function exportData(): void {
  const a = document.createElement("a");
  a.href = "/api/data/export";
  a.download = ""; // filename comes from the server's Content-Disposition
  document.body.appendChild(a);
  a.click();
  a.remove();
}

export interface ImportDataResult { restored: number; files: number; exportedAt: string | null }
/** Restore from a backup .zip — WIPES and replaces all data. */
export async function importData(file: File): Promise<ImportDataResult> {
  const fd = new FormData();
  fd.append("file", file);
  const res = await fetch("/api/data/import", { method: "POST", body: fd });
  if (!res.ok) throw new Error((await res.json().catch(() => ({} as { message?: string }))).message || `Import failed (${res.status})`);
  return res.json() as Promise<ImportDataResult>;
}

// ── Automatic (background) sync toggle ──
export const fetchAutoSync = () => req<{ enabled: boolean }>("GET", "/api/calendar/auto-sync");
export const setAutoSync = (enabled: boolean) => req<{ enabled: boolean }>("PUT", "/api/calendar/auto-sync", { enabled });

// ── On-demand "Sync now" for all enabled Apple calendars ──
export interface SyncAllResult { created: number; merged: number; toTriage: number; removedFlagged: number; bridgeError?: BridgeError }
export const syncAll = () => post<SyncAllResult>("/api/calendar/sync-all", {});

// ── Triage — pending tier-2 dedup decisions ──
export const fetchTriage = () => req<{ items: TriageEntry[] }>("GET", "/api/calendar/triage");
export const resolveTriageItem = (id: string, action: CommitAction, targetId?: string) =>
  post<CommitResult>("/api/calendar/triage", { id, action, targetId });
