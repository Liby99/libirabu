# Yearly Tracker → Personal Life & Research OS — Roadmap

> Vision: evolve the current high-level year planner into a single, AI-assisted
> operating system for managing research, teaching, service, side projects, and
> music — across calendar, projects, people, and travel — surfaced on desktop,
> phone, and an office TV.

This is a living planning document. Decisions marked **[LOCKED]** are settled;
**[OPEN]** items still need a call.

---

## 1. Where we are today

The current app is a **high-level visual year planner**:

- Data shape: `CalendarData → { years: { [year]: YearData } }`; a `YearData` has
  quarterly notes + 12 months; an `Event` is `{ start, end, name, color }` keyed
  by **day-of-year integers** (no clock times).
- Storage: **offline-first `localStorage`**, synced to Postgres as **one JSON
  blob per `(user, year)`** via `/api/calendar-data` (`SyncManager`).
- Auth: next-auth (credentials + Google), Prisma 7 → Neon Postgres.
- Clients: Next.js web app (mobile-responsive, PWA manifest present) + an
  Electron shell that loads the deployed URL.

**Implication:** the year-blob is perfect for the painterly year view but cannot
answer relational questions ("all deadlines for project X", "every meeting with
student Y", "what's due this week"). The expansion requires a **relational data
model**. The existing year view is an asset we keep and build *on top of*.

---

## 2. What you want (structured summary)

Five capability areas:

### A. Time & calendars
- **Year view** (evolve the current grid), **month grid**, and **day timeline**
  with real clock times.
- **Read-only sync** from **Google Calendar** (OAuth API) and **Apple Calendar**
  (CalDAV + app-specific password) into a unified view, color-coded by source.
- Travel, conferences, rehearsals, performances, lessons, classes, meetings, and
  deadlines all visible in one place.

### B. Domains & projects (the "work" layer)
Life is organized into **domains**, each holding **projects** and **tasks**:
- **Research:** papers, projects, proposals/grants, collaborations, conference
  attendance + their deadlines.
- **Group management:** advising students, recurring 1:1s, ad-hoc meetings.
- **Service:** committees, reviewing, program-committee work.
- **Teaching:** courses, lectures, grading deadlines, office hours.
- **Side projects:** need *steady, tracked progress* (not deadline-driven).
- **Music:** gigs/performances (with travel), rehearsals, private piano lessons,
  lesson homework/practice.

### C. People & relationships
Students (advisees), collaborators, co-authors, committee members, bandmates,
piano teacher — linked to meetings, projects, and notes.

### D. AI assistant (agentic) **[LOCKED: agentic with confirmation]**
A Claude-powered chatbot that can answer questions **and act via tool-use**:
schedule/move meetings, create tasks & deadlines, draft project plans, build the
TV briefing — with **confirmation required before any consequential write**.

### E. Surfaces / clients
- **Mac Electron app** — open like a native app.
- **Mobile web (PWA)** — installable on phone.
- **Office TV display** — a dedicated, auto-refreshing, *read-only*, sanitized
  high-level view of the group plan (key travel, conf/paper/proposal deadlines,
  teaching at a glance).

---

## 3. Locked decisions

| Area | Decision |
|---|---|
| Calendar sync | **[LOCKED]** Read-only import first (Google API + Apple CalDAV); two-way write-back in a later phase. |
| AI assistant | **[LOCKED]** Agentic (tool-use) with confirmation gating + audit log for writes. |
| Hosting | **[LOCKED]** Vercel (app + API) + Neon (Postgres). Anthropic key server-side only; sensitive fields encrypted at rest. |
| First phase | **[LOCKED]** Relational foundation + richer calendar (unblocks everything else). |

---

## 4. Proposed domain model (relational)

New Prisma models (alongside the existing `User`/`Account`/`Session`). The old
`CalendarData` blob is **migrated** into `Event`s and retired (or kept read-only
for the legacy year-paint view during transition).

```
Domain        id, userId, key (RESEARCH|TEACHING|SERVICE|SIDE|MUSIC|PERSONAL),
              name, color, order

Project       id, userId, domainId, parentId?, title, description, status
              (IDEA|ACTIVE|PAUSED|DONE|DROPPED), priority, startDate?,
              targetDate?, cadence? (for "steady progress" side projects),
              metadata Json

Milestone     id, projectId, title, dueAt, kind (PAPER|PROPOSAL|GRANT|
              CONF_DEADLINE|GRADING|CUSTOM), status, eventId?  // surfaced on cal

Task          id, userId, projectId?, domainId?, title, notes?, status
              (TODO|DOING|DONE|BLOCKED), priority, dueAt?, scheduledStart?,
              scheduledEnd?, estimateMins?, recurrence? (RRULE)

Event         id, userId, source (INTERNAL|GOOGLE|APPLE), externalId?, etag?,
              calendarAccountId?, title, start (DateTime), end (DateTime),
              allDay, location?, type (MEETING|TRAVEL|CONFERENCE|REHEARSAL|
              PERFORMANCE|LESSON|CLASS|DEADLINE|FOCUS|OTHER), recurrence? (RRULE),
              projectId?, tripId?, color?, notes?
              // legacy day-of-year bars import here as allDay date ranges

Person        id, userId, name, role (STUDENT|COLLABORATOR|COAUTHOR|COMMITTEE|
              BANDMATE|TEACHER|OTHER), affiliation?, email?, relation?, notes(enc)

EventPerson   eventId, personId, role        // meeting attendees / participants
ProjectPerson projectId, personId, role      // collaborators on a project

Trip          id, userId, title, destination, start, end, purpose
              (CONFERENCE|PERFORMANCE|VISIT|OTHER), projectId?  // groups events

CalendarAccount id, userId, provider (GOOGLE|APPLE), label, credentials(enc),
              syncToken?, lastSyncedAt, status

Note          id, userId, body(enc?), projectId?|personId?|eventId?|date?

AIConversation id, userId, title, createdAt
AIMessage      id, conversationId, role, content Json, toolCalls Json?
ActionLog      id, userId, actor (USER|AI), kind, payload Json, status
              (PROPOSED|CONFIRMED|APPLIED|REVERTED), createdAt   // agentic audit
```

Notes:
- **Recurrence** via RRULE strings (the `rrule` lib) for 1:1s, lessons, classes,
  rehearsals.
- **Encrypted fields** (`enc`): student/research notes, CalDAV passwords —
  AES-GCM with a key from Vercel env.
- The **TV view** reads only non-sensitive, high-level fields (never `Note` bodies
  or `Person.notes`).

---

## 5. Architecture

- **Framework:** keep Next.js App Router on Vercel; Server Components +
  Server Actions for mutations; Route Handlers for sync/AI/webhooks. `zod` for
  validation everywhere.
- **DB:** Neon Postgres via Prisma 7 (already migrated to the driver adapter).
- **AI service:** server route using `@anthropic-ai/sdk` with the latest Claude
  model, in a **tool-use loop**. Tools (e.g. `query_schedule`, `create_event`,
  `move_event`, `create_task`, `create_project`, `generate_briefing`) map to DB
  ops. **Writes return a proposal** that the user confirms in the UI; confirmed
  actions are applied and recorded in `ActionLog` (enables undo). Stream
  responses. Key is server-only.
- **Calendar sync:**
  - *Google:* extend the existing `GoogleProvider` to request
    `calendar.readonly`; pull with the Calendar API using incremental
    **sync tokens**; store tokens on the existing `Account`.
  - *Apple:* CalDAV via `tsdav` + app-specific password (encrypted in
    `CalendarAccount`).
  - Normalize into `Event` with `source`+`externalId`+`etag` for dedup/update;
    run on a schedule via **Vercel Cron** + manual "sync now".
- **Surfaces:**
  - *Mobile:* harden the existing PWA (manifest present) → installable; add push.
  - *Electron:* keep the remote-URL shell; add menubar presence, native
    notifications, a global hotkey, deep links. (Optionally bundle the app later.)
  - *TV:* a dedicated `/display` kiosk route — full-screen, auto-refresh
    (poll/SSE), **device token auth** (no interactive login), sanitized data.
- **Security:** Anthropic key + all provider secrets server-side; AES-GCM for
  sensitive columns; strict separation so the TV surface can't read private notes.

---

## 6. Phased roadmap

### Phase 0 — Foundation prep (small, do first)
- ✅ Dependencies modernized (done).
- **Verify Prisma 7 DB connection** against live Neon before further work.
- Add `zod`, `rrule`, `@anthropic-ai/sdk`, `googleapis`, `tsdav`, an encryption
  helper. Decide migration strategy for legacy year-blob data.

### Phase 1 — Relational core + richer calendar **[FIRST]**
- Author the new Prisma schema (§4) + migrations; one-time importer that converts
  existing `(user, year)` blobs into `Event`s (day-of-year → all-day ranges).
- **Day / month / year** views; evolve the current year grid into the year view.
- **Read-only Google + Apple import**; unified, source-colored display; Vercel
  Cron + "sync now".
- Outcome: one place that shows everything happening, from real sources.

### Phase 2 — Projects, people & work management
- Domain → Project → Task UI; status/priority; side-project "steady progress"
  cadence tracking.
- People + meetings (recurring 1:1s, ad-hoc); committees; collaborators.
- Milestones/deadlines (paper/proposal/grant/conference/grading) on calendar +
  lists; Trips grouping travel.

### Phase 3 — Agentic AI assistant
- Chat UI (web + Electron); server tool-use loop; confirmation gating + `ActionLog`.
- Briefings ("plan my week", "what's due", conflict detection), scheduling help,
  plan drafting.
- Proactive: weekly digest + deadline reminders (email/push).

### Phase 4 — Surfaces & polish
- **TV office dashboard** (`/display`): high-level group plan, sanitized,
  auto-refresh, kiosk.
- Electron enhancements; mobile PWA polish + push notifications.

### Phase 5 — Two-way calendar sync + smart scheduling
- Write-back to Google/Apple with conflict resolution & dedup.
- Slot-finding for meetings, workload balancing to protect side-project/practice
  time.

---

## 7. Open questions

- **[OPEN]** Keep the legacy "paint bars" year interaction, or replace it with a
  derived year view over `Event`s? (Recommendation: keep as an optional layer.)
- **[OPEN]** Multi-user later (e.g., students see a slice), or strictly single-user?
- **[OPEN]** Notifications channel preference: email, web push, native, or all?
- **[OPEN]** How much should the TV view show about people/students vs. purely
  deadlines & travel (privacy boundary)?
- **[OPEN]** AI: which actions are "consequential" enough to always require
  confirmation vs. auto-apply (e.g., creating a private task vs. moving a meeting
  with an external attendee)?

---

## 8. Risks & considerations

- **Apple CalDAV** is the fiddliest integration; isolate it behind an adapter.
- **Sensitive data** (students, research, committee) — encryption + the TV/data
  boundary must be designed in, not bolted on.
- **Sync correctness** (dedup across sources, recurrence expansion) is the main
  source of subtle bugs — model `externalId`/`etag`/RRULE carefully.
- **Scope** is large; each phase should ship usable on its own.

---

## 9. Immediate next steps

1. Smoke-test Prisma 7 against the live DB (the one outstanding item from the
   dependency upgrade).
2. Confirm the §4 model and the legacy-data migration approach.
3. Start Phase 1: schema + migration + day/month/year views + Google read-only
   import (Apple second).
