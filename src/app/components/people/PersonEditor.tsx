"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { updatePerson, deletePerson } from "@/app/actions/people";
import { PERSON_ROLES } from "@/lib/enums";

interface PersonData {
  id: string;
  name: string;
  email: string | null;
  role: string;
  affiliation: string | null;
  advisorId: string | null;
}

export default function PersonEditor({
  person,
  advisorOptions,
}: {
  person: PersonData;
  advisorOptions: { id: string; name: string }[];
}) {
  const router = useRouter();
  const [name, setName] = useState(person.name);
  const [role, setRole] = useState(person.role);
  const [affiliation, setAffiliation] = useState(person.affiliation ?? "");
  const [email, setEmail] = useState(person.email ?? "");
  const [advisorId, setAdvisorId] = useState(person.advisorId ?? "");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  async function save() {
    setBusy(true);
    setMsg(null);
    try {
      await updatePerson({
        id: person.id,
        name: name.trim(),
        role: role as never,
        affiliation,
        email,
        advisorId: advisorId || null,
      });
      setMsg("Saved");
      router.refresh();
    } catch (e) {
      setMsg(e instanceof Error ? e.message : "Failed");
    } finally {
      setBusy(false);
    }
  }

  async function remove() {
    if (!confirm(`Delete ${person.name}?`)) return;
    setBusy(true);
    try {
      await deletePerson(person.id);
      router.push("/people");
    } catch (e) {
      setMsg(e instanceof Error ? e.message : "Failed");
      setBusy(false);
    }
  }

  return (
    <div className="editor-card">
      <div className="inline-form">
        <input className="auth-input f-grow" value={name} onChange={(e) => setName(e.target.value)} />
        <select className="auth-input" value={role} onChange={(e) => setRole(e.target.value)}>
          {PERSON_ROLES.map((r) => <option key={r} value={r}>{r}</option>)}
        </select>
        <input className="auth-input f-grow" placeholder="Affiliation" value={affiliation}
          onChange={(e) => setAffiliation(e.target.value)} />
        <input className="auth-input f-grow" placeholder="Email" value={email}
          onChange={(e) => setEmail(e.target.value)} />
        <select className="auth-input" value={advisorId} onChange={(e) => setAdvisorId(e.target.value)}>
          <option value="">— advisor —</option>
          {advisorOptions.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
        </select>
        <button className="btn-primary" onClick={save} disabled={busy}>Save</button>
        <button className="btn-danger" onClick={remove} disabled={busy}>Delete</button>
      </div>
      {msg && <div className="muted" style={{ marginTop: 6 }}>{msg}</div>}
    </div>
  );
}
