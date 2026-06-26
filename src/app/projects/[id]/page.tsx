import Link from "next/link";
import { notFound } from "next/navigation";
import { requireUserId } from "@/lib/auth";
import { getProject } from "@/app/actions/projects";
import { listPeople } from "@/app/actions/people";
import AppNav from "@/app/components/app/AppNav";
import ProjectDetail from "@/app/components/projects/ProjectDetail";

export default async function ProjectPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  await requireUserId();
  const { id } = await params;
  const [project, people] = await Promise.all([getProject(id), listPeople()]);
  if (!project) notFound();

  return (
    <>
      <AppNav />
      <main className="app-main app-scroll">
        <div className="page">
          <Link className="back-link" href="/projects">‹ Projects</Link>
          <ProjectDetail
            project={{
              id: project.id,
              title: project.title,
              description: project.description,
              status: project.status,
              priority: project.priority,
            }}
            members={project.people.map((pp) => ({
              personId: pp.person.id,
              name: pp.person.name,
              role: pp.role,
            }))}
            tasks={project.tasks.map((t) => ({
              id: t.id,
              title: t.title,
              status: t.status,
              priority: t.priority,
              dueAt: t.dueAt ? t.dueAt.toISOString() : null,
            }))}
            papers={project.papers}
            proposals={project.proposals}
            allPeople={people.map((p) => ({ id: p.id, name: p.name }))}
          />
        </div>
      </main>
    </>
  );
}
