import { requireUserId } from "@/lib/auth";
import { listProjects } from "@/app/actions/projects";
import AppNav from "@/app/components/app/AppNav";
import ProjectsManager from "@/app/components/projects/ProjectsManager";

export default async function ProjectsPage() {
  await requireUserId();
  const projects = await listProjects();
  const dto = projects.map((p) => ({
    id: p.id,
    title: p.title,
    description: p.description,
    status: p.status,
    priority: p.priority,
    tasks: p._count.tasks,
    people: p._count.people,
    papers: p._count.papers,
  }));
  return (
    <>
      <AppNav />
      <main className="app-main app-scroll">
        <ProjectsManager projects={dto} />
      </main>
    </>
  );
}
