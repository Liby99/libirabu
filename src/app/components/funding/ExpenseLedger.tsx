"use client";

import { useRef, useState } from "react";
import { useRouter } from "next/navigation";
import {
  createExpense, updateExpense, deleteExpense, uploadReceipt, deleteAttachment,
} from "@/app/actions/expenses";
import { EXPENSE_CATEGORIES, EXPENSE_STATUSES } from "@/lib/enums";
import { money, shortDate } from "@/lib/format";

interface Opt { id: string; name: string }
export interface ExpenseRow {
  id: string;
  description: string;
  amount: number;
  category: string;
  date: string;
  status: string;
  personId: string | null;
  fundingSourceName: string | null;
  tripTitle: string | null;
  attachments: { id: string; filename: string }[];
}

const today = () => new Date().toISOString().slice(0, 10);

export default function ExpenseLedger({
  expenses, sources, people, trips,
}: {
  expenses: ExpenseRow[];
  sources: Opt[];
  people: Opt[];
  trips: Opt[];
}) {
  const router = useRouter();
  const [desc, setDesc] = useState("");
  const [amount, setAmount] = useState("");
  const [category, setCategory] = useState("OTHER");
  const [date, setDate] = useState(today());
  const [sourceId, setSourceId] = useState("");
  const [personId, setPersonId] = useState("");
  const [tripId, setTripId] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const fileRefs = useRef<Record<string, HTMLInputElement | null>>({});

  const personName = (id: string | null) => people.find((p) => p.id === id)?.name ?? null;
  const wrap = async (fn: () => Promise<unknown>) => {
    setBusy(true); setError(null);
    try { await fn(); router.refresh(); }
    catch (e) { setError(e instanceof Error ? e.message : "Failed"); }
    finally { setBusy(false); }
  };

  async function add() {
    if (!desc.trim() || !amount) { setError("Description and amount required"); return; }
    const payload = {
      description: desc.trim(), amount: Number(amount), category: category as never,
      date: new Date(date).toISOString(), fundingSourceId: sourceId || null,
      personId: personId || null, tripId: tripId || null,
    };
    setDesc(""); setAmount("");
    await wrap(() => createExpense(payload));
  }

  async function onPick(expenseId: string, file: File | undefined) {
    if (!file) return;
    const fd = new FormData();
    fd.set("expenseId", expenseId);
    fd.set("file", file);
    await wrap(() => uploadReceipt(fd));
  }

  const total = expenses.reduce((s, e) => s + e.amount, 0);

  return (
    <section style={{ marginBottom: 24 }}>
      <h2 className="group-h2">EXPENSE LEDGER <span className="page-count">{expenses.length}</span> <span className="muted">total {money(total)}</span></h2>
      <div className="inline-form">
        <input className="auth-input f-grow" placeholder="Description" value={desc} onChange={(e) => setDesc(e.target.value)} />
        <input className="auth-input" style={{ width: 100 }} placeholder="$" value={amount} onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ""))} />
        <select className="auth-input" value={category} onChange={(e) => setCategory(e.target.value)}>
          {EXPENSE_CATEGORIES.map((c) => <option key={c} value={c}>{c}</option>)}
        </select>
        <input className="auth-input" type="date" value={date} onChange={(e) => setDate(e.target.value)} />
        <select className="auth-input" value={sourceId} onChange={(e) => setSourceId(e.target.value)}>
          <option value="">— funding —</option>
          {sources.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
        </select>
        <select className="auth-input" value={personId} onChange={(e) => setPersonId(e.target.value)}>
          <option value="">— person —</option>
          {people.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
        </select>
        <select className="auth-input" value={tripId} onChange={(e) => setTripId(e.target.value)}>
          <option value="">— trip —</option>
          {trips.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
        </select>
        <button className="btn-primary" onClick={add} disabled={busy}>Add</button>
      </div>
      {error && <div className="auth-error">{error}</div>}

      <table className="data-table">
        <thead>
          <tr><th>Date</th><th>Description</th><th>Amount</th><th>Category</th><th>Funding</th><th>Who/Trip</th><th>Status</th><th>Receipts</th><th></th></tr>
        </thead>
        <tbody>
          {expenses.length === 0 && <tr><td colSpan={9} className="empty">No expenses yet.</td></tr>}
          {expenses.map((e) => (
            <tr key={e.id}>
              <td className="muted">{shortDate(e.date)}</td>
              <td>{e.description}</td>
              <td>{money(e.amount)}</td>
              <td><span className="badge">{e.category}</span></td>
              <td className="muted">{e.fundingSourceName || "—"}</td>
              <td className="muted">{personName(e.personId) || e.tripTitle || "—"}</td>
              <td>
                <select className="mini-select" value={e.status} disabled={busy}
                  onChange={(ev) => wrap(() => updateExpense({ id: e.id, status: ev.target.value as never }))}>
                  {EXPENSE_STATUSES.map((s) => <option key={s} value={s}>{s}</option>)}
                </select>
              </td>
              <td className="receipts">
                {e.attachments.map((a) => (
                  <span key={a.id} className="receipt-chip">
                    <a href={`/api/files/${a.id}`} target="_blank" rel="noreferrer">{a.filename}</a>
                    <button className="x-btn" disabled={busy} onClick={() => wrap(() => deleteAttachment(a.id))}>×</button>
                  </span>
                ))}
                <input
                  type="file"
                  style={{ display: "none" }}
                  ref={(el) => { fileRefs.current[e.id] = el; }}
                  onChange={(ev) => onPick(e.id, ev.target.files?.[0])}
                />
                <button className="link-btn" disabled={busy} onClick={() => fileRefs.current[e.id]?.click()}>+ receipt</button>
              </td>
              <td><button className="x-btn" disabled={busy} onClick={() => { if (confirm("Delete expense?")) wrap(() => deleteExpense(e.id)); }}>×</button></td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  );
}
