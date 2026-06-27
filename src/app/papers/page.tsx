import { requireUserId } from "@/lib/auth";
import { listPapers } from "@/app/actions/papers";
import { listProjects } from "@/app/actions/projects";
import PapersManager from "@/app/components/papers/PapersManager";

export default async function PapersPage() {
  await requireUserId();
  const [papers, projects] = await Promise.all([listPapers(), listProjects()]);
  return (
    <>
      <main className="app-main app-scroll">
        <PapersManager
          papers={papers.map((p) => ({
            id: p.id,
            title: p.title,
            venue: p.venue,
            year: p.year,
            status: p.status,
            overleafUrl: p.overleafUrl,
            githubUrl: p.githubUrl,
            arxivUrl: p.arxivUrl,
            doi: p.doi,
            projectTitle: p.project?.title ?? null,
            authors: p.authors.map((a) => a.person.name),
          }))}
          projects={projects.map((p) => ({ id: p.id, title: p.title }))}
        />
      </main>
    </>
  );
}
