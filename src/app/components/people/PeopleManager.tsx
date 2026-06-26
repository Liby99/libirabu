"use client";

import { useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { createPerson } from "@/app/actions/people";
import { PERSON_ROLES } from "@/lib/enums";

export interface PersonRow {
  id: string;
  name: string;
  email: string | null;
  role: string;
  affiliation: string | null;
  advisorId: string | null;
  advisorName: string | null;
}

export default function PeopleManager({ people }: { people: PersonRow[] }) {
  const router = useRouter();
  const [name, setName] = useState("");
  const [role, setRole] = useState("STUDENT");
  const [affiliation, setAffiliation] = useState("");
  const [email, setEmail] = useState("");
  const [advisorId, setAdvisorId] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function add() {
    if (!name.trim()) return;
    setBusy(true);
    setError(null);
    try {
      await createPerson({
        name: name.trim(),
        role: role as never,
        affiliation: affiliation || undefined,
        email: email || undefined,
        advisorId: advisorId || null,
      });
      setName(""); setAffiliation(""); setEmail(""); setAdvisorId("");
      router.refresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to add");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="page">
      <div className="page-head">
        <h1 className="page-h1">People</h1>
        <span className="page-count">{people.length}</span>
      </div>

      <div className="inline-form">
        <input className="auth-input f-grow" placeholder="Name" value={name}
          onChange={(e) => setName(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && add()} />
        <select className="auth-input" value={role} onChange={(e) => setRole(e.target.value)}>
          {PERSON_ROLES.map((r) => <option key={r} value={r}>{r}</option>)}
        </select>
        <input className="auth-input f-grow" placeholder="Affiliation" value={affiliation}
          onChange={(e) => setAffiliation(e.target.value)} />
        <input className="auth-input f-grow" placeholder="Email" value={email}
          onChange={(e) => setEmail(e.target.value)} />
        <select className="auth-input" value={advisorId} onChange={(e) => setAdvisorId(e.target.value)}>
          <option value="">— advisor —</option>
          {people.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
        </select>
        <button className="btn-primary" onClick={add} disabled={busy}>Add</button>
      </div>
      {error && <div className="auth-error">{error}</div>}

      <table className="data-table">
        <thead>
          <tr><th>Name</th><th>Role</th><th>Affiliation</th><th>Advisor</th><th>Email</th></tr>
        </thead>
        <tbody>
          {people.length === 0 && (
            <tr><td colSpan={5} className="empty">No people yet — add your students, collaborators, co-authors…</td></tr>
          )}
          {people.map((p) => (
            <tr key={p.id}>
              <td><Link className="row-link" href={`/people/${p.id}`}>{p.name}</Link></td>
              <td><span className="badge">{p.role}</span></td>
              <td>{p.affiliation || "—"}</td>
              <td>{p.advisorName || "—"}</td>
              <td>{p.email || "—"}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
