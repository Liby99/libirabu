"use client";

// Connectivity — a top-bar dropdown (like View/Edit) whose items each open a focused modal
// (docs/calendar-import-design.md §9.2): a sync-state line, Apple Calendars, Import .ics, Inbox,
// Triage. Apple sync + .ics both funnel into the shared preview → Apply flow (New / Changed /
// Removed). On commit it dispatches "calendar:changed" so the canvas hooks refetch.

import { useCallback, useEffect, useRef, useState, type DragEvent } from "react";
import MenuBackdrop from "./MenuBackdrop";
import { Dialog, DialogButton } from "@/app/components/ui/Dialog";
import type { CommitSelection, CommitAction, PreviewItem, ConnectionRow, TriageEntry } from "@/lib/import/types";
import {
  importPreviewIcs, importCommitIcs, syncConnection, importCommitApple, clearAllImported,
  fetchConnections, setConnectionEnabled, fetchTriage, resolveTriageItem, type IcsPreviewResponse, type BridgeError,
} from "../../model/api/importClient";

type Phase = "idle" | "loading" | "review" | "committing" | "done";
type Source = { kind: "ics"; icsText: string; fileName: string } | { kind: "apple"; connectionId: string; calName: string };
type Modal = "calendars" | "ics" | "triage";

function whenLabel(it: PreviewItem): string {
  const ev = it.incoming;
  if (ev.allDay || ev.kind === "band") return ev.start === ev.end ? ev.start : `${ev.start} → ${ev.end}`;
  const [d, t] = ev.start.split("T");
  return `${d} ${t?.slice(0, 5) ?? ""}`.trim();
}

function ago(iso: string | null): string {
  if (!iso) return "never";
  const mins = Math.round((Date.now() - new Date(iso).getTime()) / 60000);
  if (mins < 1) return "just now";
  if (mins < 60) return `${mins}m ago`;
  const h = Math.round(mins / 60);
  return h < 24 ? `${h}h ago` : `${Math.round(h / 24)}d ago`;
}

const MODAL_TITLE: Record<Modal, string> = { calendars: "Apple Calendars", ics: "Import a .ics file", triage: "Triage" };

export default function ConnectivityMenu() {
  const [menuOpen, setMenuOpen] = useState(false);
  const [modal, setModal] = useState<Modal | null>(null);

  const [connections, setConnections] = useState<ConnectionRow[] | null>(null);
  const [bridgeError, setBridgeError] = useState<BridgeError | null>(null);
  const [connLoading, setConnLoading] = useState(false);

  const [source, setSource] = useState<Source | null>(null);
  const [phase, setPhase] = useState<Phase>("idle");
  const [preview, setPreview] = useState<IcsPreviewResponse | null>(null);
  const [excluded, setExcluded] = useState<Set<string>>(new Set());
  const [removeChecked, setRemoveChecked] = useState<Set<string>>(new Set());

  // Triage box: pending tier-2 dedup decisions, resolved one at a time.
  const [triage, setTriage] = useState<TriageEntry[] | null>(null);
  const [triageN, setTriageN] = useState(0); // count for the menu badge
  const [triageBusy, setTriageBusy] = useState<string | null>(null); // id being resolved
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<{ created: number; merged: number; skipped: number; failed: number; removed?: number } | null>(null);
  const [dragOver, setDragOver] = useState(false);
  const [clearConfirm, setClearConfirm] = useState(false);
  const [clearing, setClearing] = useState(false);
  const [clearedCount, setClearedCount] = useState<number | null>(null);
  const fileInput = useRef<HTMLInputElement>(null);

  const loadConnections = useCallback(async () => {
    setConnLoading(true);
    try {
      const r = await fetchConnections();
      setConnections(r.calendars);
      setBridgeError(r.bridgeError ?? null);
    } catch (e) {
      setBridgeError({ code: "failed", message: e instanceof Error ? e.message : "Failed to list calendars" });
    } finally { setConnLoading(false); }
  }, []);

  const loadTriage = useCallback(async () => {
    try { const r = await fetchTriage(); setTriage(r.items); setTriageN(r.items.length); }
    catch { setTriage([]); }
  }, []);

  // When the dropdown opens: load connections (for the sync-state line) once, and refresh the
  // Triage badge count each time.
  useEffect(() => {
    if (!menuOpen) return;
    if (connections === null) void loadConnections();
    void loadTriage();
  }, [menuOpen, connections, loadConnections, loadTriage]);

  const resetPreview = () => { setSource(null); setPreview(null); setPhase("idle"); setExcluded(new Set()); setRemoveChecked(new Set()); setError(null); setResult(null); };
  const openModal = (m: Modal) => { setMenuOpen(false); resetPreview(); setModal(m); if (m === "calendars" && connections === null) void loadConnections(); if (m === "triage") { setTriage(null); void loadTriage(); } };
  const closeModal = () => { setModal(null); resetPreview(); };
  const backToList = () => { resetPreview(); void loadConnections(); };

  async function runIcs(file: File) {
    setError(null); setPhase("loading"); setSource({ kind: "ics", icsText: "", fileName: file.name });
    try {
      const text = await file.text();
      setSource({ kind: "ics", icsText: text, fileName: file.name });
      setPreview(await importPreviewIcs(text, file.name));
      setPhase("review");
    } catch (e) { setError(e instanceof Error ? e.message : "Failed to read file"); setPhase("idle"); setSource(null); }
  }

  async function runSync(conn: ConnectionRow) {
    setError(null); setPhase("loading"); setSource({ kind: "apple", connectionId: conn.id, calName: conn.calName });
    try {
      const r = await syncConnection(conn.id);
      if ("bridgeError" in r && r.bridgeError) { setBridgeError(r.bridgeError); setPhase("idle"); setSource(null); return; }
      setPreview(r as IcsPreviewResponse);
      setPhase("review");
    } catch (e) { setError(e instanceof Error ? e.message : "Sync failed"); setPhase("idle"); setSource(null); }
  }

  const onDrop = (e: DragEvent) => { e.preventDefault(); setDragOver(false); const f = e.dataTransfer.files?.[0]; if (f) void runIcs(f); };
  const toggleItem = (tempId: string) => setExcluded((prev) => { const n = new Set(prev); if (n.has(tempId)) n.delete(tempId); else n.add(tempId); return n; });

  async function resolveTriage(entry: TriageEntry, action: CommitAction) {
    setTriageBusy(entry.id);
    try {
      await resolveTriageItem(entry.id, action, action === "merge" ? entry.candidates[0]?.targetId : undefined);
      setTriage((prev) => { const next = (prev ?? []).filter((t) => t.id !== entry.id); setTriageN(next.length); return next; });
      if (action !== "skip" && typeof window !== "undefined") window.dispatchEvent(new CustomEvent("calendar:changed"));
    } catch { /* leave the item in place on failure */ } finally { setTriageBusy(null); }
  }
  const toggleRemove = (id: string) => setRemoveChecked((prev) => { const n = new Set(prev); if (n.has(id)) n.delete(id); else n.add(id); return n; });

  async function toggleCalendar(conn: ConnectionRow) {
    setConnections((cs) => cs?.map((c) => (c.id === conn.id ? { ...c, enabled: !c.enabled } : c)) ?? cs);
    try { await setConnectionEnabled(conn.id, !conn.enabled); } catch { void loadConnections(); }
  }

  async function doClearAll() {
    setClearing(true);
    try {
      const r = await clearAllImported();
      setClearedCount(r.deleted);
      if (typeof window !== "undefined") window.dispatchEvent(new CustomEvent("calendar:changed"));
      await loadConnections(); // refresh the sync-state line (lastSyncedAt was reset)
    } catch { /* keep the dialog open on failure */ } finally { setClearing(false); }
  }

  async function doImport() {
    if (!preview || !source) return;
    const sels: CommitSelection[] = [];
    for (const it of preview.groups.new) sels.push({ tempId: it.tempId, action: excluded.has(it.tempId) ? "skip" : "create" });
    for (const it of preview.groups.duplicate) sels.push({ tempId: it.tempId, action: excluded.has(it.tempId) ? "skip" : "merge", targetId: it.match?.targetId });
    // tier-2 "decide" items are NOT committed here — they were persisted to Triage for later.
    setPhase("committing"); setError(null);
    try {
      const r = source.kind === "apple" ? await importCommitApple(source.connectionId, sels, [...removeChecked]) : await importCommitIcs(source.icsText, source.fileName, sels);
      setResult(r); setPhase("done");
      if (typeof window !== "undefined") window.dispatchEvent(new CustomEvent("calendar:changed"));
    } catch (e) { setError(e instanceof Error ? e.message : "Import failed"); setPhase("review"); }
  }

  const newItems = preview?.groups.new ?? [];
  const dupItems = preview?.groups.duplicate ?? [];
  const decideItems = preview?.groups.decide ?? [];
  const removedItems = preview?.removed ?? [];
  const selectedCount = newItems.filter((it) => !excluded.has(it.tempId)).length
    + dupItems.filter((it) => !excluded.has(it.tempId)).length;
  const actionCount = selectedCount + removeChecked.size;
  const inPreview = source !== null && phase !== "idle";

  const renderRow = (it: PreviewItem, kind: "new" | "dup") => (
    <label key={it.tempId} className="cc-import-row">
      <input type="checkbox" checked={!excluded.has(it.tempId)} onChange={() => toggleItem(it.tempId)} />
      <span className="cc-import-row-title">{it.incoming.title}</span>
      <span className="cc-import-when">{whenLabel(it)}</span>
      {kind === "dup" && <span className="cc-import-tag">merge</span>}
      {it.incoming.repeatSimplified && <span className="cc-import-tag warn">recurrence simplified</span>}
    </label>
  );

  // A pending Triage entry: the incoming event, the existing one it might duplicate, an AI hint, and
  // a Merge / Import-new / Skip choice that resolves immediately.
  const candWhen = (s: string) => (s.includes("T") ? `${s.slice(0, 10)} ${s.slice(11, 16)}` : s);
  const incWhen = (e: TriageEntry["incoming"]) => {
    if (e.allDay || e.kind === "band") return e.start === e.end ? e.start : `${e.start} → ${e.end}`;
    return `${e.start.slice(0, 10)} ${e.start.slice(11, 16)}`;
  };
  const renderTriage = (entry: TriageEntry) => {
    const cand = entry.candidates[0];
    const s = entry.suggestion;
    const busy = triageBusy === entry.id;
    return (
      <div key={entry.id} className="cc-import-decide">
        <div className="cc-import-decide-main">
          <span className="cc-import-row-title">{entry.incoming.title}</span>
          <span className="cc-import-when">{incWhen(entry.incoming)}</span>
        </div>
        {cand && <div className="cc-import-decide-cand">looks like <strong>{cand.title}</strong> · {candWhen(cand.start)}</div>}
        {s && <div className={`cc-import-ai${s.suggestion === "merge" ? " merge" : ""}`}>AI: {s.suggestion === "merge" ? "likely the same" : "probably different"}{s.reason ? ` — ${s.reason}` : ""}</div>}
        <div className="cc-import-seg" role="group" aria-label="What to do">
          <button type="button" disabled={busy || !cand} onClick={() => void resolveTriage(entry, "merge")}>Merge</button>
          <button type="button" disabled={busy} onClick={() => void resolveTriage(entry, "create")}>Import new</button>
          <button type="button" disabled={busy} onClick={() => void resolveTriage(entry, "skip")}>Skip</button>
        </div>
      </div>
    );
  };

  const triageBody = triage === null
    ? <div className="cc-import-muted">Loading…</div>
    : triage.length === 0
      ? <div className="cc-import-muted">Nothing to triage. Ambiguous duplicates from a sync (a close title + nearby time, but no matching UID) land here for you to resolve.</div>
      : <div className="cc-import-body">{triage.map(renderTriage)}</div>;

  // Sync-state summary for the dropdown header.
  const enabledCount = connections?.filter((c) => c.enabled).length ?? 0;
  const lastSync = (connections ?? []).reduce<string | null>((max, c) => (c.lastSyncedAt && (!max || c.lastSyncedAt > max) ? c.lastSyncedAt : max), null);
  const syncState = bridgeError ? "⚠ Calendar access needed"
    : connections === null ? (connLoading ? "Checking calendars…" : "")
    : `${enabledCount} calendar${enabledCount === 1 ? "" : "s"} on · last sync ${ago(lastSync)}`;

  const grouped = new Map<string, ConnectionRow[]>();
  for (const c of connections ?? []) { const a = grouped.get(c.accountLabel); if (a) a.push(c); else grouped.set(c.accountLabel, [c]); }

  const modalTitle = modal ? (inPreview
    ? (source?.kind === "apple" ? `Sync — ${source.calName}` : `Import — ${source?.kind === "ics" ? source.fileName : ""}`)
    : MODAL_TITLE[modal]) : "";

  // ── the shared preview (New / Changed / Removed → Apply) ─────────────────────────────────────
  const previewBody = preview && (
    <div className="cc-import-body">
      {preview.ignoredAllDay > 0 && <div className="cc-import-muted">{preview.ignoredAllDay} all-day event(s) ignored (birthdays/holidays).</div>}
      {newItems.length === 0 && dupItems.length === 0 && decideItems.length === 0 && removedItems.length === 0 && (
        <div className="cc-import-muted">
          {source?.kind === "apple" ? "Up to date — nothing new or changed." : "Nothing to import"} — parsed {preview.stats.parsed} event(s)
          {preview.stats.parsed > 0 && ` (${preview.stats.timed} timed, ${preview.stats.allDay} all-day)`}.
        </div>
      )}
      {newItems.length > 0 && <div className="cc-import-group"><div className="cc-import-group-head">New · {newItems.length}</div>{newItems.map((it) => renderRow(it, "new"))}</div>}
      {dupItems.length > 0 && <div className="cc-import-group"><div className="cc-import-group-head">{source?.kind === "apple" ? "Changed" : "Duplicates (already imported)"} · {dupItems.length}</div>{dupItems.map((it) => renderRow(it, "dup"))}</div>}
      {decideItems.length > 0 && (
        <div className="cc-import-muted">{decideItems.length} possible duplicate{decideItems.length === 1 ? "" : "s"} sent to <strong>Triage</strong> — resolve under Connectivity → Triage.</div>
      )}
      {removedItems.length > 0 && (
        <div className="cc-import-group">
          <div className="cc-import-group-head">No longer in the calendar · {removedItems.length}</div>
          {removedItems.map((r) => (
            <label key={r.id} className="cc-import-row">
              <input type="checkbox" checked={removeChecked.has(r.id)} onChange={() => toggleRemove(r.id)} />
              <span className="cc-import-row-title">{r.title}</span>
              <span className="cc-import-when">{r.start.replace("T", " ").slice(0, 16)}</span>
              <span className="cc-import-tag warn">delete?</span>
            </label>
          ))}
        </div>
      )}
    </div>
  );

  const calendarsBody = bridgeError ? (
    <div className="cc-import-muted">
      {bridgeError.code === "not-built"
        ? <>The EventKit bridge isn’t built yet. Run <code>native/eventkit-bridge/build-app.sh</code>.</>
        : <>Can’t read your calendars ({bridgeError.message}). Grant Calendar access to the app, then </>}
      <button className="cc-import-linkbtn" onClick={() => void loadConnections()}>recheck</button>.
    </div>
  ) : (connections && connections.length > 0) ? (
    <div className="cc-import-body">
      {[...grouped.entries()].map(([account, cals]) => (
        <div className="cc-import-group" key={account}>
          <div className="cc-import-subhead">{account}</div>
          {cals.map((c) => (
            <div className="cc-import-cal" key={c.id}>
              <label className="cc-import-cal-name">
                <input type="checkbox" checked={c.enabled} onChange={() => void toggleCalendar(c)} />
                <span className="cc-import-cal-dot" style={{ background: c.color || "var(--accent-grey)" }} />
                <span className="cc-import-row-title">{c.calName}</span>
              </label>
              <span className="cc-import-when">{ago(c.lastSyncedAt)}</span>
              <button className="cc-action cc-action-sm cc-action-plain" disabled={!c.enabled} onClick={() => void runSync(c)}>Sync</button>
            </div>
          ))}
        </div>
      ))}
    </div>
  ) : (
    <div className="cc-import-muted">{connLoading ? "Loading calendars…" : "No Apple calendars found."}</div>
  );

  const icsBody = (
    <>
      <div
        className={`cc-import-drop${dragOver ? " over" : ""}`}
        onDragOver={(e) => { e.preventDefault(); setDragOver(true); }}
        onDragLeave={() => setDragOver(false)}
        onDrop={onDrop}
        onClick={() => fileInput.current?.click()}
      >
        Drop a .ics file here, or click to choose
        <input ref={fileInput} type="file" accept=".ics,text/calendar" hidden
          onChange={(e) => { const f = e.target.files?.[0]; if (f) void runIcs(f); e.target.value = ""; }} />
      </div>
      {error && <div className="cc-import-error">{error}</div>}
    </>
  );

  return (
    <div className="cc-year-wrap">
      <button className="cc-action cc-action-sm cc-action-plain" onClick={() => setMenuOpen((o) => !o)}>
        Connectivity<span className="cc-caret">▾</span>
      </button>

      {menuOpen && (
        <>
          <MenuBackdrop onClose={() => setMenuOpen(false)} />
          <div className="cc-menu" role="menu">
            {syncState && <div className="cc-menu-status">{syncState}</div>}
            <div className="cc-menu-sep" />
            <button className="cc-menu-item" onClick={() => openModal("calendars")}>Apple Calendars<span className="cc-menu-sc">{connections ? `${enabledCount} on ›` : "›"}</span></button>
            <button className="cc-menu-item" onClick={() => openModal("ics")}>Import .ics file<span className="cc-menu-sc">›</span></button>
            <div className="cc-menu-sep" />
            <button className="cc-menu-item" onClick={() => openModal("triage")}>Triage<span className="cc-menu-sc">{triageN > 0 ? `${triageN} ›` : "›"}</span></button>
            <div className="cc-menu-sep" />
            <button className="cc-menu-item cc-menu-item-danger" onClick={() => { setMenuOpen(false); setClearedCount(null); setClearConfirm(true); }}>Clear all imported<span className="cc-menu-sc">reset</span></button>
          </div>
        </>
      )}

      <Dialog
        open={clearConfirm}
        onClose={() => setClearConfirm(false)}
        title="Clear all imported events?"
        actions={clearedCount != null
          ? <DialogButton variant="primary" onClick={() => setClearConfirm(false)}>Done</DialogButton>
          : <>
              <DialogButton variant="ghost" onClick={() => setClearConfirm(false)}>Cancel</DialogButton>
              <DialogButton variant="danger" disabled={clearing} onClick={doClearAll}>{clearing ? "Clearing…" : "Clear all"}</DialogButton>
            </>}
      >
        {clearedCount != null
          ? <p className="ui-dlg-msg">Removed {clearedCount} imported event{clearedCount === 1 ? "" : "s"}. Run a Sync to re-import from scratch.</p>
          : <p className="ui-dlg-msg">This deletes <strong>every</strong> imported event (Apple &amp; .ics), including hidden ones. Your own events and internalized copies are kept. The next Sync re-imports from scratch.</p>}
      </Dialog>

      <Dialog
        open={modal != null}
        onClose={closeModal}
        title={modalTitle}
        showClose
        cardClassName="cc-conn-card"
        actions={modal ? (
          inPreview
            ? (phase === "done"
                ? <DialogButton variant="primary" onClick={backToList}>Done</DialogButton>
                : <>
                    <DialogButton variant="ghost" onClick={backToList}>← Back</DialogButton>
                    <DialogButton variant="primary" disabled={phase !== "review" || actionCount === 0} onClick={doImport}>
                      {phase === "committing" ? "Applying…" : `Apply ${actionCount || ""}`.trim()}
                    </DialogButton>
                  </>)
            : <DialogButton variant="ghost" onClick={closeModal}>Close</DialogButton>
        ) : undefined}
      >
        {phase === "loading" && <div className="cc-import-muted">Reading &amp; matching…</div>}
        {inPreview ? (
          <>
            {error && <div className="cc-import-error">{error}</div>}
            {phase === "review" && previewBody}
            {phase === "done" && result && (
              <div className="cc-import-done">✅ Synced — {result.created} added, {result.merged} updated, {result.skipped} skipped{result.failed ? `, ${result.failed} failed` : ""}{result.removed ? `, ${result.removed} removed` : ""}.</div>
            )}
          </>
        ) : modal === "calendars" ? calendarsBody
          : modal === "ics" ? icsBody
          : modal === "triage" ? triageBody
          : null}
      </Dialog>
    </div>
  );
}
