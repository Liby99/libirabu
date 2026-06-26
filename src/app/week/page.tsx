import { requireUserId } from "@/lib/auth";
import { listEvents, listTracks } from "@/app/actions/calendar";
import AppNav from "@/app/components/app/AppNav";
import WeekView from "@/app/components/calendar/WeekView";
import {
  parseDateParam,
  toDateParam,
  startOfWeek,
  weekDays,
  addDays,
  startOfDay,
} from "@/lib/date";
import { toEventDTO, toTrackDTO } from "@/app/components/calendar/dto";

export default async function WeekPage({
  searchParams,
}: {
  searchParams: Promise<{ d?: string }>;
}) {
  await requireUserId();
  const { d } = await searchParams;
  const anchor = parseDateParam(d);
  const start = startOfWeek(anchor);
  const days = weekDays(anchor);
  const rangeEnd = addDays(start, 7);
  const [events, tracks] = await Promise.all([
    listEvents(startOfDay(start).toISOString(), rangeEnd.toISOString()),
    listTracks(),
  ]);
  return (
    <>
      <AppNav />
      <main className="app-main">
        <WeekView
          weekStart={toDateParam(start)}
          days={days.map(toDateParam)}
          events={events.map(toEventDTO)}
          tracks={tracks.map(toTrackDTO)}
        />
      </main>
    </>
  );
}
