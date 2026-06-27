import { requireUserId } from "@/lib/auth";
import { listDeadlines } from "@/app/actions/deadlines";
import DeadlinesBoard from "@/app/components/deadlines/DeadlinesBoard";

export default async function DeadlinesPage() {
  await requireUserId();
  const deadlines = await listDeadlines();
  return (
    <>
      <main className="app-main app-scroll">
        <DeadlinesBoard
          deadlines={deadlines.map((d) => ({
            id: d.id,
            venue: d.venue,
            kind: d.kind,
            dueAt: d.dueAt.toISOString(),
            url: d.url,
            watched: d.watched,
          }))}
        />
      </main>
    </>
  );
}
