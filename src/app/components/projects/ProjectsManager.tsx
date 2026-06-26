"use client";

import { useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { createProject } from "@/app/actions/projects";
import { PROJECT_STATUSES } from "@/lib/enums";

export interface ProjectRow {
  id: string;
  title: string;
  description: string | null;
  status: string;
  priority: number;
  tasks: number;
  people: number;
  papers: number;
}

const STATUS_ORDER = ["ACTIVE", "IDEA", "PAUSED", "DONE", "DROPPED"];

export default function ProjectsManager({ projects }: { projects: ProjectRow[] }) {
  const router = useRouter();
  const [title, setTitle] = useState("");
  const [status, setStatus] = useState("ACTIVE");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function add() {
    if (!title.trim()) return;
    setBusy(true);
    setError(null);
    try {
      await createProject({ title: title.trim(), status: status as never });
      setTitle("");
      router.refresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to add");
    } finally {
      setBusy(false);
    }
  }

  const groups = STATUS_ORDER.map((s) => ({
    status: s,
    items: projects.filter((p) => p.status === s),
  })).filter((g) => g.items.length > 0);

  return (
    <div className="page">
      <div className="page-head">
        <h1 className="page-h1">Projects</h1>
        <span className="page-count">{projects.length}</span>
      </div>

      <div className="inline-form">
        <input className="auth-input f-grow" placeholder="New project title" value={title}
          onChange={(e) => setTitle(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && add()} />
        <select className="auth-input" value={status} onChange={(e) => setStatus(e.target.value)}>
          {PROJECT_STATUSES.map((s) => <option key={s} value={s}>{s}</option>)}
        </select>
        <button className="btn-primary" onClick={add} disabled={busy}>Add</button>
      </div>
      {error && <div className="auth-error">{error}</div>}

      {projects.length === 0 && <p className="empty">No projects yet.</p>}

      {groups.map((g) => (
        <div key={g.status} className="proj-group">
          <h2 className="group-h2">{g.status} <span className="page-count">{g.items.length}</span></h2>
          <div className="card-grid">
            {g.items.map((p) => (
              <Link key={p.id} href={`/projects/${p.id}`} className="proj-card">
                <span className="proj-title">{p.title}</span>
                {p.description && <span className="proj-desc">{p.description}</span>}
                <span className="proj-meta">
                  {p.tasks} tasks · {p.people} people · {p.papers} papers
                </span>
              </Link>
            ))}
          </div>
        </div>
      ))}
    </div>
  );
}
