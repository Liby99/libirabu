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
import { addDays, toDateParam, isSameDay, weekdayLabel } from "@/lib/date";

export default function WeekView({
  weekStart,
  days,
  events,
  tracks,
}: {
  weekStart: string; // YYYY-MM-DD (Monday)
  days: string[]; // 7 × YYYY-MM-DD
  events: CalEventDTO[];
  tracks: TrackDTO[];
}) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const [draft, setDraft] = useState<EventDraft | null>(null);
  const start = new Date(`${weekStart}T00:00:00`);

  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = DEFAULT_SCROLL_HOUR * HOUR_HEIGHT;
    }
  }, []);

  function newAt(dayDate: Date, minutes: number) {
    const snapped = Math.round(minutes / 30) * 30;
    const d0 = new Date(dayDate.getFullYear(), dayDate.getMonth(), dayDate.getDate());
    const s = new Date(d0.getTime() + snapped * 60000);
    const e = new Date(s.getTime() + 60 * 60000);
    setDraft({ title: "", notes: "", start: s, end: e, allDay: false, type: "OTHER", color: "", trackId: "" });
  }

  return (
    <div className="cal">
      <div className="cal-header">
        <Link className="cal-nav" href={`/week?d=${toDateParam(addDays(start, -7))}`}>‹</Link>
        <Link className="cal-nav" href={`/week?d=${toDateParam(new Date())}`}>Today</Link>
        <Link className="cal-nav" href={`/week?d=${toDateParam(addDays(start, 7))}`}>›</Link>
        <span className="cal-title">
          {start.toLocaleDateString(undefined, { month: "short", day: "numeric" })} –{" "}
          {addDays(start, 6).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" })}
        </span>
      </div>

      {/* Day headers */}
      <div className="week-head">
        <div className="cal-gutter-spacer" />
        {days.map((ds) => {
          const d = new Date(`${ds}T00:00:00`);
          const today = isSameDay(d, new Date());
          return (
            <Link key={ds} href={`/day?d=${ds}`} className={`week-day-head${today ? " is-today" : ""}`}>
              <span className="week-day-name">{weekdayLabel(d)}</span>
              <span className="week-day-num">{d.getDate()}</span>
            </Link>
          );
        })}
      </div>

      {/* All-day band */}
      <div className="week-allday">
        <div className="cal-gutter-spacer" />
        {days.map((ds) => {
          const d = new Date(`${ds}T00:00:00`);
          const dayAllDay = events.filter(
            (e) => e.allDay && isSameDay(new Date(e.start), d),
          );
          return (
            <div key={ds} className="week-allday-cell">
              {dayAllDay.map((e) => (
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
          );
        })}
      </div>

      <div className="cal-scroll" ref={scrollRef}>
        <div className="week-grid" style={{ height: DAY_HOURS * HOUR_HEIGHT }}>
          <div className="cal-gutter">
            {Array.from({ length: DAY_HOURS }, (_, h) => (
              <div className="cal-hour-label" key={h} style={{ height: HOUR_HEIGHT }}>
                {String(h).padStart(2, "0")}:00
              </div>
            ))}
          </div>
          {days.map((ds) => {
            const d = new Date(`${ds}T00:00:00`);
            const dayStart = new Date(d.getFullYear(), d.getMonth(), d.getDate());
            const dayEnd = new Date(d.getFullYear(), d.getMonth(), d.getDate(), 23, 59, 59, 999);
            const positioned = layoutDay(events, dayStart, dayEnd);
            const today = isSameDay(d, new Date());
            return (
              <div
                key={ds}
                className={`cal-col week-col${today ? " is-today" : ""}`}
                onClick={(e) => {
                  const rect = e.currentTarget.getBoundingClientRect();
                  newAt(d, ((e.clientY - rect.top) / HOUR_HEIGHT) * 60);
                }}
              >
                {Array.from({ length: DAY_HOURS }, (_, h) => (
                  <div className="cal-hour-line" key={h} style={{ top: h * HOUR_HEIGHT }} />
                ))}
                {positioned.map(({ e, top, height, col, cols }) => (
                  <button
                    key={e.id}
                    className="cal-event"
                    style={{
                      top,
                      height,
                      left: `calc(${(col / cols) * 100}% + 1px)`,
                      width: `calc(${100 / cols}% - 2px)`,
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
            );
          })}
        </div>
      </div>

      {draft && (
        <EventModal draft={draft} tracks={tracks} onClose={() => setDraft(null)} />
      )}
    </div>
  );
}
