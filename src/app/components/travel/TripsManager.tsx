"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createTrip, deleteTrip } from "@/app/actions/trips";
import { TRIP_PURPOSES } from "@/lib/enums";
import { money, shortDate } from "@/lib/format";

interface Opt { id: string; name: string }
export interface TripRow {
  id: string;
  title: string;
  destination: string;
  purpose: string;
  start: string;
  end: string;
  estCost: number | null;
  actualCost: number | null;
  travelerPersonId: string | null;
  fundingSourceName: string | null;
  spent: number;
}

const today = () => new Date().toISOString().slice(0, 10);

export default function TripsManager({
  trips, sources, people,
}: {
  trips: TripRow[];
  sources: Opt[];
  people: Opt[];
}) {
  const router = useRouter();
  const [title, setTitle] = useState("");
  const [destination, setDestination] = useState("");
  const [purpose, setPurpose] = useState("CONFERENCE");
  const [start, setStart] = useState(today());
  const [end, setEnd] = useState(today());
  const [traveler, setTraveler] = useState("");
  const [sourceId, setSourceId] = useState("");
  const [estCost, setEstCost] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const personName = (id: string | null) => people.find((p) => p.id === id)?.name ?? "me";
  const wrap = async (fn: () => Promise<unknown>) => {
    setBusy(true); setError(null);
    try { await fn(); router.refresh(); }
    catch (e) { setError(e instanceof Error ? e.message : "Failed"); }
    finally { setBusy(false); }
  };

  async function add() {
    if (!title.trim() || !destination.trim()) { setError("Title and destination required"); return; }
    const payload = {
      title: title.trim(), destination: destination.trim(), purpose: purpose as never,
      start: new Date(start).toISOString(), end: new Date(end).toISOString(),
      estCost: estCost ? Number(estCost) : null,
      travelerPersonId: traveler || null, fundingSourceId: sourceId || null,
    };
    setTitle(""); setDestination(""); setEstCost("");
    await wrap(() => createTrip(payload));
  }

  return (
    <div className="page">
      <div className="page-head"><h1 className="page-h1">Travel</h1><span className="page-count">{trips.length}</span></div>
      <div className="inline-form">
        <input className="auth-input f-grow" placeholder="Trip title" value={title} onChange={(e) => setTitle(e.target.value)} />
        <input className="auth-input" placeholder="Destination" value={destination} onChange={(e) => setDestination(e.target.value)} />
        <select className="auth-input" value={purpose} onChange={(e) => setPurpose(e.target.value)}>
          {TRIP_PURPOSES.map((p) => <option key={p} value={p}>{p}</option>)}
        </select>
        <input className="auth-input" type="date" value={start} onChange={(e) => setStart(e.target.value)} />
        <input className="auth-input" type="date" value={end} onChange={(e) => setEnd(e.target.value)} />
        <select className="auth-input" value={traveler} onChange={(e) => setTraveler(e.target.value)}>
          <option value="">— me —</option>
          {people.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
        </select>
        <select className="auth-input" value={sourceId} onChange={(e) => setSourceId(e.target.value)}>
          <option value="">— funding —</option>
          {sources.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
        </select>
        <input className="auth-input" style={{ width: 110 }} placeholder="Est $" value={estCost} onChange={(e) => setEstCost(e.target.value.replace(/[^0-9.]/g, ""))} />
        <button className="btn-primary" onClick={add} disabled={busy}>Add</button>
      </div>
      {error && <div className="auth-error">{error}</div>}

      <table className="data-table">
        <thead>
          <tr><th>Trip</th><th>Destination</th><th>Purpose</th><th>Dates</th><th>Traveler</th><th>Funding</th><th>Est / Spent</th><th></th></tr>
        </thead>
        <tbody>
          {trips.length === 0 && <tr><td colSpan={8} className="empty">No trips yet.</td></tr>}
          {trips.map((t) => (
            <tr key={t.id}>
              <td className="row-link">{t.title}</td>
              <td>{t.destination}</td>
              <td><span className="badge">{t.purpose}</span></td>
              <td className="muted">{shortDate(t.start)} – {shortDate(t.end)}</td>
              <td>{personName(t.travelerPersonId)}</td>
              <td className="muted">{t.fundingSourceName || "—"}</td>
              <td>{money(t.estCost)} / {money(t.spent)}</td>
              <td><button className="x-btn" disabled={busy} onClick={() => { if (confirm("Delete trip?")) wrap(() => deleteTrip(t.id)); }}>×</button></td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
