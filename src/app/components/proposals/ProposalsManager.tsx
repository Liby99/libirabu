"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createProposal, updateProposal, deleteProposal } from "@/app/actions/proposals";
import { PROPOSAL_STATUSES, PROPOSAL_ROLES } from "@/lib/enums";
import { useConfirm } from "@/app/components/ui/confirm";

export interface ProposalRow {
  id: string;
  title: string;
  agency: string | null;
  program: string | null;
  role: string | null;
  status: string;
  amount: number | null;
  submittedAt: string | null;
  projectTitle: string | null;
}

const money = (n: number | null) =>
  n == null ? "—" : n.toLocaleString(undefined, { style: "currency", currency: "USD", maximumFractionDigits: 0 });

export default function ProposalsManager({
  proposals, projects,
}: {
  proposals: ProposalRow[];
  projects: { id: string; title: string }[];
}) {
  const router = useRouter();
  const confirm = useConfirm();
  const [title, setTitle] = useState("");
  const [agency, setAgency] = useState("");
  const [role, setRole] = useState("PI");
  const [amount, setAmount] = useState("");
  const [projectId, setProjectId] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const wrap = async (fn: () => Promise<unknown>) => {
    setBusy(true); setError(null);
    try { await fn(); router.refresh(); }
    catch (e) { setError(e instanceof Error ? e.message : "Failed"); }
    finally { setBusy(false); }
  };

  async function add() {
    if (!title.trim()) return;
    const payload = {
      title: title.trim(), agency: agency || undefined, role: role as never,
      amount: amount ? Number(amount) : null, projectId: projectId || null,
    };
    setTitle(""); setAgency(""); setAmount("");
    await wrap(() => createProposal(payload));
  }

  const total = proposals.filter((p) => p.status === "AWARDED").reduce((s, p) => s + (p.amount ?? 0), 0);

  return (
    <div className="page">
      <div className="page-head">
        <h1 className="page-h1">Proposals</h1>
        <span className="page-count">{proposals.length}</span>
        {total > 0 && <span className="muted">awarded: {money(total)}</span>}
      </div>

      <div className="inline-form">
        <input className="auth-input f-grow" placeholder="Proposal title" value={title}
          onChange={(e) => setTitle(e.target.value)} onKeyDown={(e) => e.key === "Enter" && add()} />
        <input className="auth-input" placeholder="Agency" value={agency} onChange={(e) => setAgency(e.target.value)} />
        <select className="auth-input" value={role} onChange={(e) => setRole(e.target.value)}>
          {PROPOSAL_ROLES.map((r) => <option key={r} value={r}>{r}</option>)}
        </select>
        <input className="auth-input" style={{ width: 120 }} placeholder="Amount $" value={amount}
          onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ""))} />
        <select className="auth-input" value={projectId} onChange={(e) => setProjectId(e.target.value)}>
          <option value="">— project —</option>
          {projects.map((p) => <option key={p.id} value={p.id}>{p.title}</option>)}
        </select>
        <button className="btn-primary" onClick={add} disabled={busy}>Add</button>
      </div>
      {error && <div className="auth-error">{error}</div>}

      <table className="data-table">
        <thead>
          <tr><th>Title</th><th>Agency</th><th>Role</th><th>Amount</th><th>Status</th><th>Project</th><th></th></tr>
        </thead>
        <tbody>
          {proposals.length === 0 && <tr><td colSpan={7} className="empty">No proposals yet.</td></tr>}
          {proposals.map((p) => (
            <tr key={p.id}>
              <td className="row-link">{p.title}</td>
              <td>{p.agency || "—"}{p.program ? ` · ${p.program}` : ""}</td>
              <td>{p.role || "—"}</td>
              <td>{money(p.amount)}</td>
              <td>
                <select className="mini-select" value={p.status} disabled={busy}
                  onChange={(e) => wrap(() => updateProposal({ id: p.id, status: e.target.value as never }))}>
                  {PROPOSAL_STATUSES.map((s) => <option key={s} value={s}>{s}</option>)}
                </select>
              </td>
              <td className="muted">{p.projectTitle || "—"}</td>
              <td><button className="x-btn" disabled={busy}
                onClick={async () => { if (await confirm({ title: "Delete proposal?", confirmLabel: "Delete", variant: "danger" })) wrap(() => deleteProposal(p.id)); }}>×</button></td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
