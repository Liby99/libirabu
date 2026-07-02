"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createApiKey, updateApiKey, deleteApiKey, revealApiKey } from "@/app/actions/apikeys";
import { APIKEY_STATUSES } from "@/lib/enums";
import { useConfirm } from "@/app/components/ui/confirm";

export interface ApiKeyRow {
  id: string;
  label: string;
  provider: string;
  last4: string | null;
  hasSecret: boolean;
  purpose: string | null;
  environment: string | null;
  status: string;
  issuedToPersonId: string | null;
  issuedToLabel: string | null;
  expiresAt: string | null;
}

export default function KeysManager({
  keys, people,
}: {
  keys: ApiKeyRow[];
  people: { id: string; name: string }[];
}) {
  const router = useRouter();
  const confirm = useConfirm();
  const [label, setLabel] = useState("");
  const [provider, setProvider] = useState("");
  const [secret, setSecret] = useState("");
  const [issuedPerson, setIssuedPerson] = useState("");
  const [issuedLabel, setIssuedLabel] = useState("");
  const [purpose, setPurpose] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [revealed, setRevealed] = useState<Record<string, string>>({});

  const personName = (id: string | null) => people.find((p) => p.id === id)?.name ?? null;
  const wrap = async (fn: () => Promise<unknown>) => {
    setBusy(true); setError(null);
    try { await fn(); router.refresh(); }
    catch (e) { setError(e instanceof Error ? e.message : "Failed"); }
    finally { setBusy(false); }
  };

  async function add() {
    if (!label.trim() || !provider.trim()) { setError("Label and provider required"); return; }
    const payload = {
      label: label.trim(), provider: provider.trim(),
      secret: secret || undefined,
      issuedToPersonId: issuedPerson || null,
      issuedToLabel: issuedLabel || undefined,
      purpose: purpose || undefined,
    };
    setLabel(""); setProvider(""); setSecret(""); setIssuedPerson(""); setIssuedLabel(""); setPurpose("");
    await wrap(() => createApiKey(payload));
  }

  async function reveal(id: string) {
    if (revealed[id]) { setRevealed((r) => { const n = { ...r }; delete n[id]; return n; }); return; }
    setBusy(true); setError(null);
    try {
      const secret = await revealApiKey(id);
      setRevealed((r) => ({ ...r, [id]: secret }));
    } catch (e) { setError(e instanceof Error ? e.message : "Failed"); }
    finally { setBusy(false); }
  }

  return (
    <div className="page">
      <div className="page-head">
        <h1 className="page-h1">API Keys</h1>
        <span className="page-count">{keys.length}</span>
      </div>
      <p className="muted" style={{ marginBottom: 12 }}>
        Prefer metadata-only (provider · last-4 · issued-to). Storing the full secret is optional;
        it is encrypted at rest and every reveal is logged.
      </p>

      <div className="inline-form">
        <input className="auth-input" placeholder="Label" value={label} onChange={(e) => setLabel(e.target.value)} />
        <input className="auth-input" placeholder="Provider (OpenAI, AWS…)" value={provider} onChange={(e) => setProvider(e.target.value)} />
        <input className="auth-input f-grow" placeholder="Secret (optional)" value={secret} onChange={(e) => setSecret(e.target.value)} />
        <select className="auth-input" value={issuedPerson} onChange={(e) => setIssuedPerson(e.target.value)}>
          <option value="">— issued to person —</option>
          {people.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
        </select>
        <input className="auth-input" placeholder="…or service/CI" value={issuedLabel} onChange={(e) => setIssuedLabel(e.target.value)} />
        <input className="auth-input f-grow" placeholder="Purpose" value={purpose} onChange={(e) => setPurpose(e.target.value)} />
        <button className="btn-primary" onClick={add} disabled={busy}>Add</button>
      </div>
      {error && <div className="auth-error">{error}</div>}

      <table className="data-table">
        <thead>
          <tr><th>Provider</th><th>Label</th><th>Secret</th><th>Issued to</th><th>Purpose</th><th>Status</th><th></th></tr>
        </thead>
        <tbody>
          {keys.length === 0 && <tr><td colSpan={7} className="empty">No keys tracked yet.</td></tr>}
          {keys.map((k) => (
            <tr key={k.id} className={k.status !== "ACTIVE" ? "row-dim" : ""}>
              <td className="row-link">{k.provider}</td>
              <td>{k.label}</td>
              <td className="mono">
                {revealed[k.id] ? <span className="secret">{revealed[k.id]}</span> : (k.last4 ? `••••${k.last4}` : "—")}
                {k.hasSecret && (
                  <button className="link-btn" disabled={busy} onClick={() => reveal(k.id)}>
                    {revealed[k.id] ? "hide" : "reveal"}
                  </button>
                )}
              </td>
              <td>{personName(k.issuedToPersonId) || k.issuedToLabel || "—"}</td>
              <td className="muted">{k.purpose || "—"}</td>
              <td>
                <select className="mini-select" value={k.status} disabled={busy}
                  onChange={(e) => wrap(() => updateApiKey({ id: k.id, status: e.target.value as never }))}>
                  {APIKEY_STATUSES.map((s) => <option key={s} value={s}>{s}</option>)}
                </select>
              </td>
              <td><button className="x-btn" disabled={busy}
                onClick={async () => { if (await confirm({ title: "Delete key record?", confirmLabel: "Delete", variant: "danger" })) wrap(() => deleteApiKey(k.id)); }}>×</button></td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
