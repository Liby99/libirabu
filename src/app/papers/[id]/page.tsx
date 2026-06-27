import Link from "next/link";
import { notFound } from "next/navigation";
import { requireUserId } from "@/lib/auth";
import { getPaper } from "@/app/actions/papers";
import { listPeople } from "@/app/actions/people";
import { listProjects } from "@/app/actions/projects";
import PaperDetail from "@/app/components/papers/PaperDetail";

export default async function PaperPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  await requireUserId();
  const { id } = await params;
  const [paper, people, projects] = await Promise.all([getPaper(id), listPeople(), listProjects()]);
  if (!paper) notFound();

  return (
    <>
      <main className="app-main app-scroll">
        <div className="page">
          <Link className="back-link" href="/papers">‹ Papers</Link>
          <PaperDetail
            paper={{
              id: paper.id,
              title: paper.title,
              venue: paper.venue,
              year: paper.year,
              status: paper.status,
              overleafUrl: paper.overleafUrl,
              githubUrl: paper.githubUrl,
              arxivUrl: paper.arxivUrl,
              doi: paper.doi,
              abstract: paper.abstract,
              projectId: paper.projectId,
            }}
            authors={paper.authors.map((a) => ({
              personId: a.person.id,
              name: a.person.name,
              isCorresponding: a.isCorresponding,
            }))}
            allPeople={people.map((p) => ({ id: p.id, name: p.name }))}
            projects={projects.map((p) => ({ id: p.id, title: p.title }))}
          />
        </div>
      </main>
    </>
  );
}
