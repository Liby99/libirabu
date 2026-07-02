// Read-only calendar tools for the assistant (P0): get_screen_state + list_events.
// They read the same Postgres source of truth as the calendar UI (design §8).

import { prisma } from "@/lib/prisma";
import { EVENT_KINDS, EventKind, Repeat, toApiEvent, wallClock, parseWallClock } from "@/lib/calendar/api";
import { createEventForUser, updateEventForUser } from "@/app/api/calendar/_helpers";
import type { AssistantTool } from "../types";

// LLMs sometimes emit literal escape sequences in string fields (a backslash + "n" instead of a
// real newline), which then render as `\n` in the note. Turn those back into real whitespace.
// Only touches literal escape sequences — real newlines the model wrote correctly are left alone.
function unescapeText<T>(v: T): T {
  if (typeof v !== "string") return v;
  return v.replace(/\\r\\n|\\n|\\r/g, "\n").replace(/\\t/g, "\t") as unknown as T;
}
// Normalize the note-bearing fields of a create/update payload from the AI.
function normalizeNotes(obj: Record<string, unknown>): Record<string, unknown> {
  const out = { ...obj };
  if (typeof out.notes === "string") out.notes = unescapeText(out.notes);
  if (out.occurrenceNotes && typeof out.occurrenceNotes === "object") {
    out.occurrenceNotes = Object.fromEntries(
      Object.entries(out.occurrenceNotes as Record<string, unknown>).map(([k, val]) => [k, unescapeText(val)]),
    );
  }
  return out;
}

const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
const WEEKDAY = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
// Weekday of a floating wall-clock string, read with UTC getters (matches how the app stores time).
const weekdayOf = (start: string): string => WEEKDAY[parseWallClock(start).getUTCDay()];

const getScreenState: AssistantTool = {
  readOnly: true,
  actionKind: "get_screen_state",
  summarize: () => "Checked what's on screen",
  def: {
    name: "get_screen_state",
    description:
      "Return the user's current calendar view: the focused year, zoom level (year/month/week), focused month (0–11) and focused week start. Use this to ground references like 'this week' or 'next month'.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },
  async run(_args, ctx) {
    return ctx.view;
  },
};

const listEvents: AssistantTool = {
  readOnly: true,
  actionKind: "read_calendar",
  summarize: (a) => {
    const kind = typeof a.kind === "string" ? ` ${a.kind}` : "";
    if (a.from && a.to) return `Read${kind} events ${a.from} → ${a.to}`;
    if (a.year) return `Read${kind} events in ${a.year}`;
    return `Read${kind} events`;
  },
  def: {
    name: "list_events",
    description:
      "List the user's calendar events overlapping a window. Provide either `year` (whole year) or both `from` and `to` (YYYY-MM-DD, [from,to) exclusive). `kind` filters to timed (hourly), band (all-day), or deadline — but when SEARCHING for a specific event by name, OMIT kind and scan all kinds: a 'deadline' the user mentions may be stored as a timed or all-day (band) event. Returns event objects (id, kind, title, color, tags, notes, start, end, track, promoteTrack, repeat) each with a `weekday` field (e.g. \"Mon\") — use it; do not compute weekdays yourself. `track` = the band's lane (band only); `promoteTrack` = the lane a timed/deadline event is mirrored onto as a ghost band (null = not promoted).",
    parameters: {
      type: "object",
      properties: {
        year: { type: "integer", description: "Whole calendar year, e.g. 2026." },
        from: { type: "string", description: "Range start YYYY-MM-DD (inclusive)." },
        to: { type: "string", description: "Range end YYYY-MM-DD (exclusive)." },
        kind: { type: "string", enum: [...EVENT_KINDS], description: "Filter by event kind." },
      },
      additionalProperties: false,
    },
  },
  async run(args, ctx) {
    const kind = typeof args.kind === "string" ? args.kind : undefined;
    if (kind && !EVENT_KINDS.includes(kind as EventKind)) {
      throw new Error(`kind must be one of ${EVENT_KINDS.join(", ")}`);
    }

    let rangeStart: Date;
    let rangeEnd: Date;
    const dateRe = /^\d{4}-\d{2}-\d{2}$/;
    if (typeof args.from === "string" && typeof args.to === "string") {
      if (!dateRe.test(args.from) || !dateRe.test(args.to)) throw new Error("from/to must be YYYY-MM-DD");
      rangeStart = new Date(`${args.from}T00:00:00.000Z`);
      rangeEnd = new Date(`${args.to}T00:00:00.000Z`);
    } else {
      const year = Number.isInteger(args.year) ? (args.year as number) : ctx.view.year;
      rangeStart = wallClock(year, 0, 1);
      rangeEnd = wallClock(year + 1, 0, 1);
    }

    const rows = await prisma.calendarItem.findMany({
      where: {
        userId: ctx.userId,
        ...(kind ? { kind } : {}),
        start: { lt: rangeEnd },
        end: { gte: rangeStart },
      },
      orderBy: { start: "asc" },
    });
    return {
      events: rows.map((r) => {
        const ev = toApiEvent(r);
        return { ...ev, weekday: weekdayOf(ev.start) };
      }),
    };
  },
};

const getTracks: AssistantTool = {
  readOnly: true,
  actionKind: "read_calendar",
  summarize: (a) => `Read track names${a.year ? ` for ${a.year}` : ""}`,
  def: {
    name: "get_tracks",
    description:
      "Return the names of the 4 monthly track lanes (index 0–3) for a year — the lanes a timed/deadline event can be PROMOTED onto (promoteTrack). Names are PER-MONTH (they can differ by month) and may be blank. Use this to map a lane NAME to its index before promoting: find the target month's row, then the lane whose name matches (e.g. a paper-submission deadline in a month whose lane 3 is 'research' → promoteTrack 3).",
    parameters: {
      type: "object",
      properties: {
        year: { type: "integer", description: "Year, e.g. 2026. Defaults to the focused year." },
      },
      additionalProperties: false,
    },
  },
  async run(args, ctx) {
    const year = Number.isInteger(args.year) ? (args.year as number) : ctx.view.year;
    const prefs = await prisma.calendarPrefs.findUnique({ where: { userId: ctx.userId }, select: { trackNames: true } });
    const grid = ((prefs?.trackNames as Record<string, string[][]> | null) ?? {})[String(year)] ?? [];
    const months = MONTHS.map((name, m) => ({
      month: m,
      monthName: name,
      lanes: Array.from({ length: 4 }, (_, l) => grid[m]?.[l] ?? ""),
    }));
    return { year, months, note: "lanes are index 0–3; blank = unnamed. Match a lane name to its index to set promoteTrack." };
  },
};

const createEvent: AssistantTool = {
  readOnly: false, // mutating → gated by the auditor; emits calendar_changed
  actionKind: "create_event",
  summarize: (a) => `Added ${a.kind ? `${a.kind} ` : ""}"${String(a.title ?? "event")}"`,
  def: {
    name: "create_event",
    description:
      "Create a calendar event. kind: 'timed' (hourly, single day), 'band' (all-day, multi-day, requires track 0–3), or 'deadline' (a single moment; for conference CFP deadlines use originTz:'AOE' + originAt). PREFER timed/deadline over band when the thing has a time or is a due-moment — those carry finer info and can be 'promoted' (see promoteTrack) to also appear on a monthly track, so you do NOT need a separate all-day event. Colors are palette keys: default, red, orange, yellow, green, blue, purple — match the user's existing convention when known. notes is markdown and may contain TODO checkboxes with DSL tokens (e.g. '- [ ] submit abstract due:2026-07-01 p:!! #paper-submission start:2026-06-01'). Priority uses the `p:` prefix with a bang-count (`p:!` low … `p:!!!!!` top) — NOT bare '!!!'. Returns the created event.",
    parameters: {
      type: "object",
      properties: {
        kind: { type: "string", enum: [...EVENT_KINDS] },
        title: { type: "string" },
        start: { type: "string", description: "timed: 'YYYY-MM-DDTHH:MM:SS' (main tz); band: 'YYYY-MM-DD' (first day); deadline: omit when using originAt+originTz." },
        end: { type: "string", description: "timed: same-day end 'YYYY-MM-DDTHH:MM:SS'; band: 'YYYY-MM-DD' last day (inclusive). Omit for deadline." },
        track: { type: "integer", minimum: 0, maximum: 3, description: "band lane 0–3 (band only)." },
        promoteTrack: { type: "integer", minimum: 0, maximum: 3, description: "timed/deadline only: also show this event as a ghost band on monthly track lane 0–3 (use get_tracks to map a lane NAME like 'research' to its index). null/omit = not promoted." },
        originTz: { type: "string", description: "deadline timezone, e.g. 'AOE', 'UTC', or an IANA id." },
        originAt: { type: "string", description: "deadline wall-clock in originTz, 'YYYY-MM-DDTHH:MM:SS' (server converts to main tz)." },
        color: { type: "string", description: "palette key: default, red, orange, yellow, green, blue, purple." },
        tags: { type: "array", items: { type: "string" } },
        notes: { type: "string", description: "markdown notes; may include '- [ ] ...' TODO lines with DSL tokens." },
        repeat: {
          type: "object",
          description: "recurrence. days: 0=Sun..6=Sat.",
          properties: {
            kind: { type: "string", enum: ["none", "daily", "weekly", "weekdays", "yearly"] },
            days: { type: "array", items: { type: "integer", minimum: 0, maximum: 6 } },
            until: { type: "string", description: "'YYYY-MM-DD' inclusive end." },
            exdates: { type: "array", items: { type: "string" }, description: "'YYYY-MM-DD' occurrences to skip (holidays etc.)." },
          },
        },
      },
      required: ["kind", "title"],
      additionalProperties: false,
    },
  },
  async run(args, ctx) {
    return createEventForUser(ctx.userId, normalizeNotes(args), "ai"); // flag AI provenance → AI badge on the event
  },
};

const setView: AssistantTool = {
  readOnly: true, // UI navigation only — not audited; emits view_change (handled in the loop)
  actionKind: "set_view",
  summarize: (a) => {
    if (typeof a.focusedMonth === "number") return `Showing ${MONTHS[a.focusedMonth] ?? ""} ${a.year ?? ""}`.trim();
    if (a.zoom) return `Showing ${a.zoom} view${a.year ? ` of ${a.year}` : ""}`;
    if (a.year) return `Showing ${a.year}`;
    return "Changed the view";
  },
  def: {
    name: "set_view",
    description:
      "Navigate the user's calendar view (UI only — does not change any events). Set year, zoom ('year'|'month'|'week'), and/or focusedMonth (0=Jan..11=Dec). Use when the user asks to go to / show a month, year, or week. Note: week requests currently land on the containing month.",
    parameters: {
      type: "object",
      properties: {
        year: { type: "integer" },
        zoom: { type: "string", enum: ["year", "month", "week"] },
        focusedMonth: { type: "integer", minimum: 0, maximum: 11 },
        focusedWeekStart: { type: "string", description: "'YYYY-MM-DD' of the target week (optional)." },
      },
      additionalProperties: false,
    },
  },
  async run(args, ctx) {
    const view = { ...ctx.view };
    if (Number.isInteger(args.year)) view.year = args.year as number;
    if (args.zoom === "year" || args.zoom === "month" || args.zoom === "week") view.zoom = args.zoom;
    if (Number.isInteger(args.focusedMonth)) view.focusedMonth = Math.max(0, Math.min(11, args.focusedMonth as number));
    if (typeof args.focusedWeekStart === "string") view.focusedWeekStart = args.focusedWeekStart;
    return view;
  },
};

const updateEvent: AssistantTool = {
  readOnly: false, // mutating → auditor-gated; applies immediately (auto-update policy)
  actionKind: "update_event",
  summarize: (a) => {
    const p = a.patch as Record<string, unknown> | undefined;
    return `Updated ${p && typeof p.title === "string" ? `"${p.title}"` : "an event"}`;
  },
  def: {
    name: "update_event",
    description:
      "Edit an existing event by id. `patch` may include any of: title, notes, color, start, end, track, promoteTrack, originTz, originAt, tags, repeat (kind cannot change). Times use the same formats as create_event. Use this to move/rename/recolor an event, change its notes/tags, or PROMOTE a timed/deadline event onto a monthly track (set promoteTrack to a lane 0–3; set it to null to un-promote).",
    parameters: {
      type: "object",
      properties: {
        id: { type: "string" },
        patch: {
          type: "object",
          properties: {
            title: { type: "string" }, notes: { type: "string" }, color: { type: "string" },
            start: { type: "string" }, end: { type: "string" }, track: { type: "integer", minimum: 0, maximum: 3 },
            promoteTrack: { type: ["integer", "null"], minimum: 0, maximum: 3, description: "timed/deadline: mirror onto monthly track lane 0–3 (get its index from get_tracks); null = un-promote." },
            originTz: { type: "string" }, originAt: { type: "string" },
            tags: { type: "array", items: { type: "string" } },
            repeat: { type: "object" },
          },
        },
      },
      required: ["id", "patch"],
      additionalProperties: false,
    },
  },
  async run(args, ctx) {
    const patch = (args.patch as Record<string, unknown> | undefined) ?? {};
    return updateEventForUser(ctx.userId, String(args.id), normalizeNotes(patch), "ai");
  },
};

const deleteEvent: AssistantTool = {
  readOnly: false, // mutating → auditor-gated…
  confirm: true,   // …AND requires explicit human confirmation in the UI before executing
  actionKind: "delete_event",
  summarize: (a) =>
    typeof a.occurrenceDate === "string" ? `Delete one occurrence (${a.occurrenceDate})` : "Delete an event",
  def: {
    name: "delete_event",
    description:
      "Delete an event by id. To remove only ONE occurrence of a recurring event (a one-time skip), pass occurrenceDate 'YYYY-MM-DD' — never delete the whole series for a single skip. Deletion REQUIRES the user to confirm in the UI; after calling this, tell the user you've queued the deletion for their confirmation (do not say it's already deleted).",
    parameters: {
      type: "object",
      properties: {
        id: { type: "string" },
        occurrenceDate: { type: "string", description: "YYYY-MM-DD to remove just that occurrence of a recurring event." },
      },
      required: ["id"],
      additionalProperties: false,
    },
  },
  // RESOLVE ONLY — no deletion here. Returns the spec the user confirms; /api/assistant/execute
  // performs the actual delete on confirmation.
  async run(args, ctx) {
    const id = String(args.id);
    const row = await prisma.calendarItem.findFirst({ where: { id, userId: ctx.userId } });
    if (!row) throw new Error("event not found");
    const occ = typeof args.occurrenceDate === "string" ? args.occurrenceDate : null;
    const repeat = (row.repeat as Repeat | null) ?? { kind: "none" };
    const recurring = !!repeat.kind && repeat.kind !== "none";
    const pad = (n: number) => String(n).padStart(2, "0");
    const s = row.start;
    const baseWall = `${s.getUTCFullYear()}-${pad(s.getUTCMonth() + 1)}-${pad(s.getUTCDate())}T${pad(s.getUTCHours())}:${pad(s.getUTCMinutes())}:00`;
    return { id, title: row.title, occurrenceDate: occ, mode: occ && recurring ? "occurrence" : "series", date: occ ?? baseWall, kind: row.kind };
  },
};

export const calendarTools: AssistantTool[] = [getScreenState, listEvents, getTracks, createEvent, updateEvent, deleteEvent, setView];
