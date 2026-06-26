"use client";

import { useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { createTask, updateTask, deleteTask } from "@/app/actions/tasks";
import { TASK_STATUSES } from "@/lib/enums";

interface TaskRow {
  id: string;
  title: string;
  status: string;
  priority: number;
  dueAt: string | null;
  projectId: string | null;
  projectTitle: string | null;
}

const NEXT_STATUS: Record<string, string> = {
  TODO: "DOING", DOING: "DONE", DONE: "TODO", BLOCKED: "TODO",
};

export default function TasksBoard({
  tasks, projects,
}: {
  tasks: TaskRow[];
  projects: { id: string; title: string }[];
}) {
  const router = useRouter();
  const [title, setTitle] = useState("");
  const [projectId, setProjectId] = useState("");
  const [busy, setBusy] = useState(false);

  const wrap = async (fn: () => Promise<unknown>) => {
    setBusy(true);
    try { await fn(); router.refresh(); }
    finally { setBusy(false); }
  };

  async function add() {
    if (!title.trim()) return;
    const t = title.trim();
    setTitle("");
    await wrap(() => createTask({ title: t, projectId: projectId || null }));
  }

  return (
    <div className="page">
      <div className="page-head">
        <h1 className="page-h1">Tasks</h1>
        <span className="page-count">{tasks.length}</span>
      </div>

      <div className="inline-form">
        <input className="auth-input f-grow" placeholder="New task" value={title}
          onChange={(e) => setTitle(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && add()} />
        <select className="auth-input" value={projectId} onChange={(e) => setProjectId(e.target.value)}>
          <option value="">— no project —</option>
          {projects.map((p) => <option key={p.id} value={p.id}>{p.title}</option>)}
        </select>
        <button className="btn-primary" onClick={add} disabled={busy}>Add</button>
      </div>

      <div className="board">
        {TASK_STATUSES.map((s) => {
          const items = tasks.filter((t) => t.status === s);
          return (
            <div key={s} className="board-col">
              <h2 className="board-col-h">{s} <span className="page-count">{items.length}</span></h2>
              {items.map((t) => (
                <div key={t.id} className={`board-card st-${t.status}`}>
                  <div className="board-card-top">
                    <button className="task-status" disabled={busy}
                      onClick={() => wrap(() => updateTask({ id: t.id, status: NEXT_STATUS[t.status] as never }))}>
                      ↻
                    </button>
                    <span className="task-title">{t.title}</span>
                    <button className="x-btn" disabled={busy} onClick={() => wrap(() => deleteTask(t.id))}>×</button>
                  </div>
                  <div className="board-card-meta">
                    {t.projectTitle && <Link className="badge" href={`/projects/${t.projectId}`}>{t.projectTitle}</Link>}
                    {t.dueAt && <span className="muted">{new Date(t.dueAt).toLocaleDateString()}</span>}
                  </div>
                </div>
              ))}
              {items.length === 0 && <p className="muted empty-col">—</p>}
            </div>
          );
        })}
      </div>
    </div>
  );
}
