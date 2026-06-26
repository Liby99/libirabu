import { requireUserId } from "@/lib/auth";
import { listProposals } from "@/app/actions/proposals";
import { listProjects } from "@/app/actions/projects";
import AppNav from "@/app/components/app/AppNav";
import ProposalsManager from "@/app/components/proposals/ProposalsManager";

export default async function ProposalsPage() {
  await requireUserId();
  const [proposals, projects] = await Promise.all([listProposals(), listProjects()]);
  return (
    <>
      <AppNav />
      <main className="app-main app-scroll">
        <ProposalsManager
          proposals={proposals.map((p) => ({
            id: p.id,
            title: p.title,
            agency: p.agency,
            program: p.program,
            role: p.role,
            status: p.status,
            amount: p.amount == null ? null : Number(p.amount),
            submittedAt: p.submittedAt ? p.submittedAt.toISOString() : null,
            projectTitle: p.project?.title ?? null,
          }))}
          projects={projects.map((p) => ({ id: p.id, title: p.title }))}
        />
      </main>
    </>
  );
}
