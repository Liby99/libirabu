import { requireUserId } from "@/lib/auth";
import { listTasks } from "@/app/actions/tasks";
import { listProjects } from "@/app/actions/projects";
import TasksBoard from "@/app/components/tasks/TasksBoard";

export default async function TasksPage() {
  await requireUserId();
  const [tasks, projects] = await Promise.all([listTasks(), listProjects()]);
  return (
    <>
      <main className="app-main app-scroll">
        <TasksBoard
          tasks={tasks.map((t) => ({
            id: t.id,
            title: t.title,
            status: t.status,
            priority: t.priority,
            dueAt: t.dueAt ? t.dueAt.toISOString() : null,
            projectId: t.projectId,
            projectTitle: t.project?.title ?? null,
          }))}
          projects={projects.map((p) => ({ id: p.id, title: p.title }))}
        />
      </main>
    </>
  );
}
