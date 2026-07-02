"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createSubscription, updateSubscription, deleteSubscription } from "@/app/actions/funding";
import { SUBSCRIPTION_CYCLES } from "@/lib/enums";
import { money, shortDate } from "@/lib/format";
import { useConfirm } from "@/app/components/ui/confirm";

interface Opt { id: string; name: string }
export interface SubRow {
  id: string;
  name: string;
  vendor: string;
  cost: number;
  cycle: string;
  renewalDate: string | null;
  status: string;
  fundingSourceName: string | null;
}

export default function SubscriptionsTable({
  subscriptions, sources,
}: {
  subscriptions: SubRow[];
  sources: Opt[];
}) {
  const router = useRouter();
  const confirm = useConfirm();
  const [name, setName] = useState("");
  const [vendor, setVendor] = useState("");
  const [cost, setCost] = useState("");
  const [cycle, setCycle] = useState("MONTHLY");
  const [sourceId, setSourceId] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const wrap = async (fn: () => Promise<unknown>) => {
    setBusy(true); setError(null);
    try { await fn(); router.refresh(); }
    catch (e) { setError(e instanceof Error ? e.message : "Failed"); }
    finally { setBusy(false); }
  };

  async function add() {
    if (!name.trim() || !vendor.trim() || !cost) { setError("Name, vendor, cost required"); return; }
    const payload = { name: name.trim(), vendor: vendor.trim(), cost: Number(cost), cycle: cycle as never, fundingSourceId: sourceId || null };
    setName(""); setVendor(""); setCost("");
    await wrap(() => createSubscription(payload));
  }

  return (
    <section style={{ marginBottom: 24 }}>
      <h2 className="group-h2">SUBSCRIPTIONS <span className="page-count">{subscriptions.length}</span></h2>
      <div className="inline-form">
        <input className="auth-input f-grow" placeholder="Name (e.g. ChatGPT Team)" value={name} onChange={(e) => setName(e.target.value)} />
        <input className="auth-input" placeholder="Vendor" value={vendor} onChange={(e) => setVendor(e.target.value)} />
        <input className="auth-input" style={{ width: 90 }} placeholder="$" value={cost} onChange={(e) => setCost(e.target.value.replace(/[^0-9.]/g, ""))} />
        <select className="auth-input" value={cycle} onChange={(e) => setCycle(e.target.value)}>
          {SUBSCRIPTION_CYCLES.map((c) => <option key={c} value={c}>{c}</option>)}
        </select>
        <select className="auth-input" value={sourceId} onChange={(e) => setSourceId(e.target.value)}>
          <option value="">— funding —</option>
          {sources.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
        </select>
        <button className="btn-primary" onClick={add} disabled={busy}>Add</button>
      </div>
      {error && <div className="auth-error">{error}</div>}

      <table className="data-table">
        <thead>
          <tr><th>Name</th><th>Vendor</th><th>Cost</th><th>Cycle</th><th>Renews</th><th>Funding</th><th>Status</th><th></th></tr>
        </thead>
        <tbody>
          {subscriptions.length === 0 && <tr><td colSpan={8} className="empty">No subscriptions yet.</td></tr>}
          {subscriptions.map((s) => (
            <tr key={s.id} className={s.status !== "ACTIVE" ? "row-dim" : ""}>
              <td>{s.name}</td>
              <td className="muted">{s.vendor}</td>
              <td>{money(s.cost)}</td>
              <td><span className="badge">{s.cycle}</span></td>
              <td className="muted">{shortDate(s.renewalDate)}</td>
              <td className="muted">{s.fundingSourceName || "—"}</td>
              <td>
                <select className="mini-select" value={s.status} disabled={busy}
                  onChange={(e) => wrap(() => updateSubscription({ id: s.id, status: e.target.value as never }))}>
                  {["ACTIVE", "CANCELLED"].map((x) => <option key={x} value={x}>{x}</option>)}
                </select>
              </td>
              <td><button className="x-btn" disabled={busy} onClick={async () => { if (await confirm({ title: "Delete subscription?", confirmLabel: "Delete", variant: "danger" })) wrap(() => deleteSubscription(s.id)); }}>×</button></td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  );
}
