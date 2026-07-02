"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { createDeadline, deleteDeadline, toggleWatched } from "@/app/actions/deadlines";
import { DEADLINE_KINDS } from "@/lib/enums";
import { useConfirm } from "@/app/components/ui/confirm";

export interface DeadlineRow {
  id: string;
  venue: string;
  kind: string;
  dueAt: string;
  url: string | null;
  watched: boolean;
}

function daysUntil(iso: string, now: number): number {
  const ms = new Date(iso).getTime() - now;
  return Math.ceil(ms / 86400000);
}
function countdownLabel(d: number): string {
  if (d === 0) return "today";
  if (d === 1) return "tomorrow";
  if (d > 1) return `in ${d} days`;
  if (d === -1) return "yesterday";
  return `${-d} days ago`;
}
function urgency(d: number): string {
  if (d < 0) return "past";
  if (d <= 7) return "soon";
  if (d <= 30) return "near";
  return "far";
}

export default function DeadlinesBoard({ deadlines }: { deadlines: DeadlineRow[] }) {
  const router = useRouter();
  const confirm = useConfirm();
  const [now, setNow] = useState<number>(() => Date.now());
  const [venue, setVenue] = useState("");
  const [kind, setKind] = useState("CONF_FULL");
  const [due, setDue] = useState("");
  const [url, setUrl] = useState("");
  const [showPast, setShowPast] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 60000);
    return () => clearInterval(t);
  }, []);

  const wrap = async (fn: () => Promise<unknown>) => {
    setBusy(true); setError(null);
    try { await fn(); router.refresh(); }
    catch (e) { setError(e instanceof Error ? e.message : "Failed"); }
    finally { setBusy(false); }
  };

  async function add() {
    if (!venue.trim() || !due) { setError("Venue and due date required"); return; }
    const payload = { venue: venue.trim(), kind: kind as never, dueAt: new Date(due).toISOString(), url: url || undefined };
    setVenue(""); setDue(""); setUrl("");
    await wrap(() => createDeadline(payload));
  }

  const visible = deadlines.filter((d) => showPast || daysUntil(d.dueAt, now) >= 0);

  return (
    <div className="page">
      <div className="page-head">
        <h1 className="page-h1">Deadlines</h1>
        <span className="page-count">{visible.length}</span>
        <label className="muted" style={{ marginLeft: "auto", display: "flex", gap: 5, alignItems: "center" }}>
          <input type="checkbox" checked={showPast} onChange={(e) => setShowPast(e.target.checked)} /> show past
        </label>
      </div>

      <div className="inline-form">
        <input className="auth-input f-grow" placeholder="Venue (e.g. NeurIPS 2026)" value={venue} onChange={(e) => setVenue(e.target.value)} />
        <select className="auth-input" value={kind} onChange={(e) => setKind(e.target.value)}>
          {DEADLINE_KINDS.map((k) => <option key={k} value={k}>{k}</option>)}
        </select>
        <input className="auth-input" type="datetime-local" value={due} onChange={(e) => setDue(e.target.value)} />
        <input className="auth-input f-grow" placeholder="CFP URL (optional)" value={url} onChange={(e) => setUrl(e.target.value)} />
        <button className="btn-primary" onClick={add} disabled={busy}>Add</button>
      </div>
      {error && <div className="auth-error">{error}</div>}

      <div className="dl-list">
        {visible.length === 0 && <p className="empty">No upcoming deadlines.</p>}
        {visible.map((d) => {
          const n = daysUntil(d.dueAt, now);
          return (
            <div key={d.id} className={`dl-card u-${urgency(n)}${d.watched ? "" : " row-dim"}`}>
              <div className="dl-count">{n >= 0 ? n : "—"}<span className="dl-count-unit">{n >= 0 ? (n === 1 ? "day" : "days") : ""}</span></div>
              <div className="dl-main">
                <div className="dl-venue">
                  {d.url ? <a href={d.url} target="_blank" rel="noreferrer">{d.venue}</a> : d.venue}
                  <span className="badge">{d.kind}</span>
                </div>
                <div className="muted">{new Date(d.dueAt).toLocaleString(undefined, { weekday: "short", month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" })} · {countdownLabel(n)}</div>
              </div>
              <div className="dl-actions">
                <button className="link-btn" disabled={busy} onClick={() => wrap(() => toggleWatched(d.id, !d.watched))}>{d.watched ? "unwatch" : "watch"}</button>
                <button className="x-btn" disabled={busy} onClick={async () => { if (await confirm({ title: "Delete deadline?", confirmLabel: "Delete", variant: "danger" })) wrap(() => deleteDeadline(d.id)); }}>×</button>
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
