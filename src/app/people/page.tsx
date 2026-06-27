import { requireUserId } from "@/lib/auth";
import { listPeople } from "@/app/actions/people";
import PeopleManager from "@/app/components/people/PeopleManager";

export default async function PeoplePage() {
  await requireUserId();
  const people = await listPeople();
  const dto = people.map((p) => ({
    id: p.id,
    name: p.name,
    email: p.email,
    role: p.role,
    affiliation: p.affiliation,
    advisorId: p.advisorId,
    advisorName: p.advisor?.name ?? null,
  }));
  return (
    <>
      <main className="app-main app-scroll">
        <PeopleManager people={dto} />
      </main>
    </>
  );
}
