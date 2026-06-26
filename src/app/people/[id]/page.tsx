import Link from "next/link";
import { notFound } from "next/navigation";
import { requireUserId } from "@/lib/auth";
import { getPerson, listPeople } from "@/app/actions/people";
import AppNav from "@/app/components/app/AppNav";
import PersonEditor from "@/app/components/people/PersonEditor";

export default async function PersonPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  await requireUserId();
  const { id } = await params;
  const [person, all] = await Promise.all([getPerson(id), listPeople()]);
  if (!person) notFound();

  const advisorOptions = all
    .filter((p) => p.id !== person.id)
    .map((p) => ({ id: p.id, name: p.name }));

  return (
    <>
      <AppNav />
      <main className="app-main app-scroll">
        <div className="page">
          <Link className="back-link" href="/people">‹ People</Link>

          <PersonEditor
            person={{
              id: person.id,
              name: person.name,
              email: person.email,
              role: person.role,
              affiliation: person.affiliation,
              advisorId: person.advisorId,
            }}
            advisorOptions={advisorOptions}
          />

          <div className="detail-grid">
            <section className="detail-card">
              <h3 className="detail-h3">Advisees</h3>
              {person.advisees.length === 0 ? <p className="muted">None</p> : (
                <ul className="link-list">
                  {person.advisees.map((a) => (
                    <li key={a.id}><Link href={`/people/${a.id}`}>{a.name}</Link> <span className="badge">{a.role}</span></li>
                  ))}
                </ul>
              )}
            </section>

            <section className="detail-card">
              <h3 className="detail-h3">Projects</h3>
              {person.projects.length === 0 ? <p className="muted">None</p> : (
                <ul className="link-list">
                  {person.projects.map((pp) => (
                    <li key={pp.project.id}>
                      <Link href={`/projects/${pp.project.id}`}>{pp.project.title}</Link>{" "}
                      <span className="badge">{pp.role}</span>
                    </li>
                  ))}
                </ul>
              )}
            </section>

            <section className="detail-card">
              <h3 className="detail-h3">Papers</h3>
              {person.papers.length === 0 ? <p className="muted">None</p> : (
                <ul className="link-list">
                  {person.papers.map((pa) => (
                    <li key={pa.paper.id}>{pa.paper.title} <span className="badge">{pa.paper.status}</span></li>
                  ))}
                </ul>
              )}
            </section>
          </div>
        </div>
      </main>
    </>
  );
}
