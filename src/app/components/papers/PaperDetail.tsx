"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { updatePaper, deletePaper, addAuthor, removeAuthor } from "@/app/actions/papers";
import { PAPER_STATUSES } from "@/lib/enums";

interface PaperData {
  id: string;
  title: string;
  venue: string | null;
  year: number | null;
  status: string;
  overleafUrl: string | null;
  githubUrl: string | null;
  arxivUrl: string | null;
  doi: string | null;
  abstract: string | null;
  projectId: string | null;
}
interface Author { personId: string; name: string; isCorresponding: boolean }

export default function PaperDetail({
  paper, authors, allPeople, projects,
}: {
  paper: PaperData;
  authors: Author[];
  allPeople: { id: string; name: string }[];
  projects: { id: string; title: string }[];
}) {
  const router = useRouter();
  const [f, setF] = useState({
    title: paper.title,
    venue: paper.venue ?? "",
    year: paper.year?.toString() ?? "",
    status: paper.status,
    overleafUrl: paper.overleafUrl ?? "",
    githubUrl: paper.githubUrl ?? "",
    arxivUrl: paper.arxivUrl ?? "",
    doi: paper.doi ?? "",
    abstract: paper.abstract ?? "",
    projectId: paper.projectId ?? "",
  });
  const [addId, setAddId] = useState("");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  const set = (k: keyof typeof f, v: string) => setF((p) => ({ ...p, [k]: v }));
  const wrap = async (fn: () => Promise<unknown>, ok?: string) => {
    setBusy(true); setMsg(null);
    try { await fn(); if (ok) setMsg(ok); router.refresh(); }
    catch (e) { setMsg(e instanceof Error ? e.message : "Failed"); }
    finally { setBusy(false); }
  };

  const available = allPeople.filter((p) => !authors.some((a) => a.personId === p.id));

  return (
    <div>
      <div className="editor-card">
        <input className="auth-input" value={f.title} onChange={(e) => set("title", e.target.value)} style={{ fontSize: "1.05rem", fontWeight: 600 }} />
        <div className="inline-form" style={{ marginTop: 8 }}>
          <input className="auth-input f-grow" placeholder="Venue" value={f.venue} onChange={(e) => set("venue", e.target.value)} />
          <input className="auth-input" style={{ width: 90 }} placeholder="Year" value={f.year} onChange={(e) => set("year", e.target.value)} />
          <select className="auth-input" value={f.status} onChange={(e) => set("status", e.target.value)}>
            {PAPER_STATUSES.map((s) => <option key={s} value={s}>{s}</option>)}
          </select>
          <select className="auth-input" value={f.projectId} onChange={(e) => set("projectId", e.target.value)}>
            <option value="">— project —</option>
            {projects.map((p) => <option key={p.id} value={p.id}>{p.title}</option>)}
          </select>
        </div>
        <div className="inline-form">
          <input className="auth-input f-grow" placeholder="Overleaf URL" value={f.overleafUrl} onChange={(e) => set("overleafUrl", e.target.value)} />
          <input className="auth-input f-grow" placeholder="GitHub URL" value={f.githubUrl} onChange={(e) => set("githubUrl", e.target.value)} />
        </div>
        <div className="inline-form">
          <input className="auth-input f-grow" placeholder="arXiv URL" value={f.arxivUrl} onChange={(e) => set("arxivUrl", e.target.value)} />
          <input className="auth-input f-grow" placeholder="DOI" value={f.doi} onChange={(e) => set("doi", e.target.value)} />
        </div>
        <textarea className="auth-input" rows={3} placeholder="Abstract" value={f.abstract} onChange={(e) => set("abstract", e.target.value)} />
        <div className="modal-actions">
          <button className="btn-danger" disabled={busy}
            onClick={() => { if (confirm("Delete paper?")) wrap(async () => { await deletePaper(paper.id); router.push("/papers"); }); }}>Delete</button>
          <span style={{ flex: 1 }} />
          {msg && <span className="muted">{msg}</span>}
          <button className="btn-primary" disabled={busy}
            onClick={() => wrap(() => updatePaper({
              id: paper.id, title: f.title.trim(), venue: f.venue, year: f.year ? Number(f.year) : null,
              status: f.status as never, overleafUrl: f.overleafUrl, githubUrl: f.githubUrl,
              arxivUrl: f.arxivUrl, doi: f.doi, abstract: f.abstract, projectId: f.projectId || null,
            }), "Saved")}>Save</button>
        </div>
      </div>

      <section className="detail-card">
        <h3 className="detail-h3">Authors <span className="page-count">{authors.length}</span></h3>
        <div className="inline-form">
          <select className="auth-input f-grow" value={addId} onChange={(e) => setAddId(e.target.value)}>
            <option value="">— add author —</option>
            {available.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
          </select>
          <button className="btn-primary" disabled={busy || !addId}
            onClick={() => { const pid = addId; setAddId(""); wrap(() => addAuthor(paper.id, pid)); }}>Add</button>
        </div>
        <ol className="author-list">
          {authors.map((a) => (
            <li key={a.personId}>
              <a href={`/people/${a.personId}`}>{a.name}</a>
              {a.isCorresponding && <span className="badge">corresponding</span>}
              <button className="x-btn" disabled={busy} onClick={() => wrap(() => removeAuthor(paper.id, a.personId))}>×</button>
            </li>
          ))}
          {authors.length === 0 && <li className="muted">No authors yet</li>}
        </ol>
      </section>
    </div>
  );
}
