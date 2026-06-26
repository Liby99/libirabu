"use client";

import { useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { createPaper } from "@/app/actions/papers";
import { PAPER_STATUSES } from "@/lib/enums";

export interface PaperRow {
  id: string;
  title: string;
  venue: string | null;
  year: number | null;
  status: string;
  overleafUrl: string | null;
  githubUrl: string | null;
  arxivUrl: string | null;
  doi: string | null;
  projectTitle: string | null;
  authors: string[];
}

export default function PapersManager({
  papers, projects,
}: {
  papers: PaperRow[];
  projects: { id: string; title: string }[];
}) {
  const router = useRouter();
  const [title, setTitle] = useState("");
  const [venue, setVenue] = useState("");
  const [status, setStatus] = useState("IN_PREP");
  const [projectId, setProjectId] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function add() {
    if (!title.trim()) return;
    setBusy(true); setError(null);
    try {
      await createPaper({ title: title.trim(), venue: venue || undefined, status: status as never, projectId: projectId || null });
      setTitle(""); setVenue("");
      router.refresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed");
    } finally { setBusy(false); }
  }

  return (
    <div className="page">
      <div className="page-head">
        <h1 className="page-h1">Papers</h1>
        <span className="page-count">{papers.length}</span>
      </div>

      <div className="inline-form">
        <input className="auth-input f-grow" placeholder="Paper title" value={title}
          onChange={(e) => setTitle(e.target.value)} onKeyDown={(e) => e.key === "Enter" && add()} />
        <input className="auth-input" placeholder="Venue" value={venue} onChange={(e) => setVenue(e.target.value)} />
        <select className="auth-input" value={status} onChange={(e) => setStatus(e.target.value)}>
          {PAPER_STATUSES.map((s) => <option key={s} value={s}>{s}</option>)}
        </select>
        <select className="auth-input" value={projectId} onChange={(e) => setProjectId(e.target.value)}>
          <option value="">— project —</option>
          {projects.map((p) => <option key={p.id} value={p.id}>{p.title}</option>)}
        </select>
        <button className="btn-primary" onClick={add} disabled={busy}>Add</button>
      </div>
      {error && <div className="auth-error">{error}</div>}

      <table className="data-table">
        <thead>
          <tr><th>Title</th><th>Authors</th><th>Venue</th><th>Year</th><th>Status</th><th>Links</th></tr>
        </thead>
        <tbody>
          {papers.length === 0 && <tr><td colSpan={6} className="empty">No papers yet.</td></tr>}
          {papers.map((p) => (
            <tr key={p.id}>
              <td><Link className="row-link" href={`/papers/${p.id}`}>{p.title}</Link>
                {p.projectTitle && <div className="muted">{p.projectTitle}</div>}</td>
              <td className="muted">{p.authors.join(", ") || "—"}</td>
              <td>{p.venue || "—"}</td>
              <td>{p.year || "—"}</td>
              <td><span className="badge">{p.status}</span></td>
              <td className="links-cell">
                {p.overleafUrl && <a href={p.overleafUrl} target="_blank" rel="noreferrer">Overleaf</a>}
                {p.githubUrl && <a href={p.githubUrl} target="_blank" rel="noreferrer">GitHub</a>}
                {p.arxivUrl && <a href={p.arxivUrl} target="_blank" rel="noreferrer">arXiv</a>}
                {p.doi && <a href={`https://doi.org/${p.doi}`} target="_blank" rel="noreferrer">DOI</a>}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
