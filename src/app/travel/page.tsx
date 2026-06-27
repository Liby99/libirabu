import { requireUserId } from "@/lib/auth";
import { listTrips } from "@/app/actions/trips";
import { listFundingSources } from "@/app/actions/funding";
import { listPeople } from "@/app/actions/people";
import TripsManager from "@/app/components/travel/TripsManager";

export default async function TravelPage() {
  await requireUserId();
  const [trips, sources, people] = await Promise.all([listTrips(), listFundingSources(), listPeople()]);
  return (
    <>
      <main className="app-main app-scroll">
        <TripsManager
          trips={trips.map((t) => ({
            id: t.id,
            title: t.title,
            destination: t.destination,
            purpose: t.purpose,
            start: t.start.toISOString(),
            end: t.end.toISOString(),
            estCost: t.estCost == null ? null : Number(t.estCost),
            actualCost: t.actualCost == null ? null : Number(t.actualCost),
            travelerPersonId: t.travelerPersonId,
            fundingSourceName: t.fundingSource?.name ?? null,
            spent: t.expenses.reduce((s, e) => s + Number(e.amount), 0),
          }))}
          sources={sources.map((s) => ({ id: s.id, name: s.name }))}
          people={people.map((p) => ({ id: p.id, name: p.name }))}
        />
      </main>
    </>
  );
}
