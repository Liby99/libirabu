import { requireUserId } from "@/lib/auth";
import { listFundingSources, listSubscriptions } from "@/app/actions/funding";
import { listExpenses } from "@/app/actions/expenses";
import { listTrips } from "@/app/actions/trips";
import { listPeople } from "@/app/actions/people";
import FundingSources from "@/app/components/funding/FundingSources";
import SubscriptionsTable from "@/app/components/funding/SubscriptionsTable";
import ExpenseLedger from "@/app/components/funding/ExpenseLedger";

const num = (d: unknown) => (d == null ? null : Number(d));

export default async function FundingPage() {
  await requireUserId();
  const [sources, subs, expenses, trips, people] = await Promise.all([
    listFundingSources(), listSubscriptions(), listExpenses(), listTrips(), listPeople(),
  ]);

  const sourceDTO = sources.map((s) => ({
    id: s.id,
    name: s.name,
    agency: s.agency,
    awardNumber: s.awardNumber,
    amount: num(s.amount),
    startDate: s.startDate ? s.startDate.toISOString() : null,
    endDate: s.endDate ? s.endDate.toISOString() : null,
    spent: s.expenses.reduce((acc, e) => acc + Number(e.amount), 0),
    subs: s._count.subscriptions,
    trips: s._count.trips,
  }));
  const sourceOpts = sources.map((s) => ({ id: s.id, name: s.name }));
  const peopleOpts = people.map((p) => ({ id: p.id, name: p.name }));
  const tripOpts = trips.map((t) => ({ id: t.id, name: t.title }));

  return (
    <>
      <main className="app-main app-scroll">
        <div className="page">
          <div className="page-head"><h1 className="page-h1">Funding</h1></div>
          <FundingSources sources={sourceDTO} />
          <ExpenseLedger
            expenses={expenses.map((e) => ({
              id: e.id,
              description: e.description,
              amount: Number(e.amount),
              category: e.category,
              date: e.date.toISOString(),
              status: e.status,
              personId: e.personId,
              fundingSourceName: e.fundingSource?.name ?? null,
              tripTitle: e.trip?.title ?? null,
              attachments: e.attachments,
            }))}
            sources={sourceOpts}
            people={peopleOpts}
            trips={tripOpts}
          />
          <SubscriptionsTable
            subscriptions={subs.map((s) => ({
              id: s.id,
              name: s.name,
              vendor: s.vendor,
              cost: Number(s.cost),
              cycle: s.cycle,
              renewalDate: s.renewalDate ? s.renewalDate.toISOString() : null,
              status: s.status,
              fundingSourceName: s.fundingSource?.name ?? null,
            }))}
            sources={sourceOpts}
          />
        </div>
      </main>
    </>
  );
}
