"use client";

import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import {
  CalEventDTO,
  TrackDTO,
  HOUR_HEIGHT,
  DAY_HOURS,
  DEFAULT_SCROLL_HOUR,
  eventColor,
  layoutDay,
} from "./shared";
import EventModal, { EventDraft, draftFromEvent } from "./EventModal";
import { addDays, toDateParam, isSameDay } from "@/lib/date";

export default function DayView({
  date,
  events,
  tracks,
}: {
  date: string; // YYYY-MM-DD
  events: CalEventDTO[];
  tracks: TrackDTO[];
}) {
  const day = new Date(`${date}T00:00:00`);
  const dayStart = new Date(day.getFullYear(), day.getMonth(), day.getDate());
  const dayEnd = new Date(day.getFullYear(), day.getMonth(), day.getDate(), 23, 59, 59, 999);
  const scrollRef = useRef<HTMLDivElement>(null);
  const [draft, setDraft] = useState<EventDraft | null>(null);

  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = DEFAULT_SCROLL_HOUR * HOUR_HEIGHT;
    }
  }, []);

  const allDay = events.filter((e) => e.allDay);
  const positioned = layoutDay(events, dayStart, dayEnd);
  const today = isSameDay(day, new Date());

  function newAt(minutes: number) {
    const snapped = Math.round(minutes / 30) * 30;
    const start = new Date(dayStart.getTime() + snapped * 60000);
    const end = new Date(start.getTime() + 60 * 60000);
    setDraft({ title: "", notes: "", start, end, allDay: false, type: "OTHER", color: "", trackId: "" });
  }

  return (
    <div className="cal">
      <div className="cal-header">
        <Link className="cal-nav" href={`/day?d=${toDateParam(addDays(day, -1))}`}>‹</Link>
        <Link className="cal-nav" href={`/day?d=${toDateParam(new Date())}`}>Today</Link>
        <Link className="cal-nav" href={`/day?d=${toDateParam(addDays(day, 1))}`}>›</Link>
        <span className={`cal-title${today ? " is-today" : ""}`}>
          {day.toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric", year: "numeric" })}
        </span>
      </div>

      {allDay.length > 0 && (
        <div className="cal-allday">
          {allDay.map((e) => (
            <button
              key={e.id}
              className="cal-allday-chip"
              style={{ background: eventColor(e) }}
              onClick={() => setDraft(draftFromEvent(e))}
            >
              {e.title}
            </button>
          ))}
        </div>
      )}

      <div className="cal-scroll" ref={scrollRef}>
        <div className="cal-grid" style={{ height: DAY_HOURS * HOUR_HEIGHT }}>
          <div className="cal-gutter">
            {Array.from({ length: DAY_HOURS }, (_, h) => (
              <div className="cal-hour-label" key={h} style={{ height: HOUR_HEIGHT }}>
                {String(h).padStart(2, "0")}:00
              </div>
            ))}
          </div>
          <div
            className="cal-col"
            onClick={(e) => {
              const rect = e.currentTarget.getBoundingClientRect();
              newAt(((e.clientY - rect.top) / HOUR_HEIGHT) * 60);
            }}
          >
            {Array.from({ length: DAY_HOURS }, (_, h) => (
              <div className="cal-hour-line" key={h} style={{ top: h * HOUR_HEIGHT }} />
            ))}
            {today && <NowLine dayStart={dayStart} />}
            {positioned.map(({ e, top, height, col, cols }) => (
              <button
                key={e.id}
                className="cal-event"
                style={{
                  top,
                  height,
                  left: `calc(${(col / cols) * 100}% + 2px)`,
                  width: `calc(${100 / cols}% - 4px)`,
                  background: eventColor(e),
                }}
                onClick={(ev) => {
                  ev.stopPropagation();
                  setDraft(draftFromEvent(e));
                }}
              >
                <span className="cal-event-title">{e.title}</span>
              </button>
            ))}
          </div>
        </div>
      </div>

      {draft && (
        <EventModal draft={draft} tracks={tracks} onClose={() => setDraft(null)} />
      )}
    </div>
  );
}

function NowLine({ dayStart }: { dayStart: Date }) {
  const [now, setNow] = useState(() => new Date());
  useEffect(() => {
    const t = setInterval(() => setNow(new Date()), 60000);
    return () => clearInterval(t);
  }, []);
  const min = (now.getTime() - dayStart.getTime()) / 60000;
  if (min < 0 || min > DAY_HOURS * 60) return null;
  return <div className="cal-now" style={{ top: (min / 60) * HOUR_HEIGHT }} />;
}
