import { requireUserId } from "@/lib/auth";
import { listEvents, listTracks } from "@/app/actions/calendar";
import AppNav from "@/app/components/app/AppNav";
import DayView from "@/app/components/calendar/DayView";
import { parseDateParam, toDateParam, startOfDay, endOfDay } from "@/lib/date";
import { toEventDTO, toTrackDTO } from "@/app/components/calendar/dto";

export default async function DayPage({
  searchParams,
}: {
  searchParams: Promise<{ d?: string }>;
}) {
  await requireUserId();
  const { d } = await searchParams;
  const day = parseDateParam(d);
  const [events, tracks] = await Promise.all([
    listEvents(startOfDay(day).toISOString(), endOfDay(day).toISOString()),
    listTracks(),
  ]);
  return (
    <>
      <AppNav />
      <main className="app-main">
        <DayView
          date={toDateParam(day)}
          events={events.map(toEventDTO)}
          tracks={tracks.map(toTrackDTO)}
        />
      </main>
    </>
  );
}
