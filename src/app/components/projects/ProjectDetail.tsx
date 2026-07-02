"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import {
  updateProject,
  deleteProject,
  addPersonToProject,
  removePersonFromProject,
} from "@/app/actions/projects";
import { createTask, updateTask, deleteTask } from "@/app/actions/tasks";
import { PROJECT_STATUSES } from "@/lib/enums";
import { useConfirm } from "@/app/components/ui/confirm";

interface ProjectData {
  id: string;
  title: string;
  description: string | null;
  status: string;
  priority: number;
}
interface Member { personId: string; name: string; role: string }
interface TaskRow { id: string; title: string; status: string; priority: number; dueAt: string | null }
interface Ref { id: string; title: string; status: string }

const NEXT_STATUS: Record<string, string> = {
  TODO: "DOING", DOING: "DONE", DONE: "TODO", BLOCKED: "TODO",
};

export default function ProjectDetail({
  project, members, tasks, papers, proposals, allPeople,
}: {
  project: ProjectData;
  members: Member[];
  tasks: TaskRow[];
  papers: Ref[];
  proposals: Ref[];
  allPeople: { id: string; name: string }[];
}) {
  const router = useRouter();
  const confirm = useConfirm();
  const [title, setTitle] = useState(project.title);
  const [description, setDescription] = useState(project.description ?? "");
  const [status, setStatus] = useState(project.status);
  const [newTask, setNewTask] = useState("");
  const [addPersonId, setAddPersonId] = useState("");
  const [busy, setBusy] = useState(false);

  const wrap = async (fn: () => Promise<unknown>) => {
    setBusy(true);
    try { await fn(); router.refresh(); }
    finally { setBusy(false); }
  };

  const available = allPeople.filter((p) => !members.some((m) => m.personId === p.id));

  return (
    <div>
      <div className="editor-card">
        <div className="inline-form">
          <input className="auth-input f-grow" value={title} onChange={(e) => setTitle(e.target.value)} />
          <select className="auth-input" value={status}
            onChange={(e) => { setStatus(e.target.value); wrap(() => updateProject({ id: project.id, status: e.target.value as never })); }}>
            {PROJECT_STATUSES.map((s) => <option key={s} value={s}>{s}</option>)}
          </select>
          <button className="btn-primary" disabled={busy}
            onClick={() => wrap(() => updateProject({ id: project.id, title: title.trim(), description }))}>
            Save
          </button>
          <button className="btn-danger" disabled={busy}
            onClick={async () => { if (await confirm({ title: "Delete project?", confirmLabel: "Delete", variant: "danger" })) wrap(async () => { await deleteProject(project.id); router.push("/projects"); }); }}>
            Delete
          </button>
        </div>
        <textarea className="auth-input" rows={2} placeholder="Description" value={description}
          onChange={(e) => setDescription(e.target.value)} style={{ marginTop: 8 }} />
      </div>

      <div className="detail-grid">
        {/* Tasks */}
        <section className="detail-card">
          <h3 className="detail-h3">Tasks <span className="page-count">{tasks.length}</span></h3>
          <div className="inline-form">
            <input className="auth-input f-grow" placeholder="Add task" value={newTask}
              onChange={(e) => setNewTask(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter" && newTask.trim()) {
                  const t = newTask.trim(); setNewTask("");
                  wrap(() => createTask({ title: t, projectId: project.id }));
                }
              }} />
          </div>
          <ul className="task-list">
            {tasks.map((t) => (
              <li key={t.id} className={`task-item st-${t.status}`}>
                <button className="task-status" title="cycle status" disabled={busy}
                  onClick={() => wrap(() => updateTask({ id: t.id, status: NEXT_STATUS[t.status] as never }))}>
                  {t.status}
                </button>
                <span className="task-title">{t.title}</span>
                {t.dueAt && <span className="muted">{new Date(t.dueAt).toLocaleDateString()}</span>}
                <button className="x-btn" disabled={busy} onClick={() => wrap(() => deleteTask(t.id))}>×</button>
              </li>
            ))}
            {tasks.length === 0 && <li className="muted">No tasks yet</li>}
          </ul>
        </section>

        {/* People */}
        <section className="detail-card">
          <h3 className="detail-h3">People <span className="page-count">{members.length}</span></h3>
          <div className="inline-form">
            <select className="auth-input f-grow" value={addPersonId} onChange={(e) => setAddPersonId(e.target.value)}>
              <option value="">— add person —</option>
              {available.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
            </select>
            <button className="btn-primary" disabled={busy || !addPersonId}
              onClick={() => { const pid = addPersonId; setAddPersonId(""); wrap(() => addPersonToProject(project.id, pid)); }}>
              Add
            </button>
          </div>
          <ul className="link-list">
            {members.map((m) => (
              <li key={m.personId}>
                <a href={`/people/${m.personId}`}>{m.name}</a> <span className="badge">{m.role}</span>
                <button className="x-btn" disabled={busy}
                  onClick={() => wrap(() => removePersonFromProject(project.id, m.personId))}>×</button>
              </li>
            ))}
            {members.length === 0 && <li className="muted">No people linked</li>}
          </ul>
        </section>

        {/* Papers & proposals */}
        <section className="detail-card">
          <h3 className="detail-h3">Papers & Proposals</h3>
          <ul className="link-list">
            {papers.map((p) => <li key={p.id}>📄 {p.title} <span className="badge">{p.status}</span></li>)}
            {proposals.map((p) => <li key={p.id}>📝 {p.title} <span className="badge">{p.status}</span></li>)}
            {papers.length + proposals.length === 0 && <li className="muted">None linked yet</li>}
          </ul>
        </section>
      </div>
    </div>
  );
}
