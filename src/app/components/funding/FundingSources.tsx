"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createFundingSource, deleteFundingSource } from "@/app/actions/funding";
import { money, shortDate } from "@/lib/format";

export interface SourceRow {
  id: string;
  name: string;
  agency: string | null;
  awardNumber: string | null;
  amount: number | null;
  startDate: string | null;
  endDate: string | null;
  spent: number;
  subs: number;
  trips: number;
}

export default function FundingSources({ sources }: { sources: SourceRow[] }) {
  const router = useRouter();
  const [name, setName] = useState("");
  const [agency, setAgency] = useState("");
  const [awardNumber, setAwardNumber] = useState("");
  const [amount, setAmount] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const wrap = async (fn: () => Promise<unknown>) => {
    setBusy(true); setError(null);
    try { await fn(); router.refresh(); }
    catch (e) { setError(e instanceof Error ? e.message : "Failed"); }
    finally { setBusy(false); }
  };

  async function add() {
    if (!name.trim()) return;
    const payload = { name: name.trim(), agency: agency || undefined, awardNumber: awardNumber || undefined, amount: amount ? Number(amount) : null };
    setName(""); setAgency(""); setAwardNumber(""); setAmount("");
    await wrap(() => createFundingSource(payload));
  }

  return (
    <section style={{ marginBottom: 24 }}>
      <h2 className="group-h2">GRANTS / FUNDING SOURCES <span className="page-count">{sources.length}</span></h2>
      <div className="inline-form">
        <input className="auth-input f-grow" placeholder="Name (e.g. NSF CAREER)" value={name} onChange={(e) => setName(e.target.value)} onKeyDown={(e) => e.key === "Enter" && add()} />
        <input className="auth-input" placeholder="Agency" value={agency} onChange={(e) => setAgency(e.target.value)} />
        <input className="auth-input" placeholder="Award #" value={awardNumber} onChange={(e) => setAwardNumber(e.target.value)} />
        <input className="auth-input" style={{ width: 120 }} placeholder="Amount $" value={amount} onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ""))} />
        <button className="btn-primary" onClick={add} disabled={busy}>Add</button>
      </div>
      {error && <div className="auth-error">{error}</div>}
      <div className="card-grid">
        {sources.length === 0 && <p className="empty">No funding sources yet.</p>}
        {sources.map((s) => {
          const remaining = s.amount == null ? null : s.amount - s.spent;
          const pct = s.amount ? Math.min(100, Math.round((s.spent / s.amount) * 100)) : 0;
          return (
            <div key={s.id} className="proj-card" style={{ cursor: "default" }}>
              <div style={{ display: "flex", justifyContent: "space-between" }}>
                <span className="proj-title">{s.name}</span>
                <button className="x-btn" disabled={busy} onClick={() => { if (confirm("Delete funding source?")) wrap(() => deleteFundingSource(s.id)); }}>×</button>
              </div>
              <span className="proj-meta">{s.agency || "—"}{s.awardNumber ? ` · ${s.awardNumber}` : ""}</span>
              <span className="proj-meta">{shortDate(s.startDate)} – {shortDate(s.endDate)}</span>
              <div className="fund-bar"><div className="fund-bar-fill" style={{ width: `${pct}%` }} /></div>
              <span className="proj-meta">
                {money(s.spent)} spent{s.amount != null ? ` of ${money(s.amount)} · ${money(remaining)} left` : ""}
              </span>
            </div>
          );
        })}
      </div>
    </section>
  );
}
