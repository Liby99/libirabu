# MagiCal — Changelog (private)

The running, developer-facing log for the native apps (macOS MagiCal + iOS read-only client).
Not shipped with the app; the public TestFlight "What to Test" notes are distilled from here at
each release.

**Workflow** (see also `CalendarApp/DISTRIBUTE.md`):
- Every user-visible feature or bug fix lands as a bullet under **[Unreleased]** in the same
  change/PR that implements it. Keep bullets one line, user-visible phrasing, most recent last.
- On a version bump: retitle **[Unreleased]** to the new version + date, distill the public
  changelog from it, start a fresh empty **[Unreleased]**, bump `MARKETING_VERSION` in
  `CalendarApp/project.yml`, tag `vX.Y.Z` in git.
- Versions are semver-ish while pre-1.0: **0.MINOR.PATCH** — MINOR for feature releases,
  PATCH for fix-only releases. Build numbers (`CURRENT_PROJECT_VERSION`) are a separate,
  per-upload counter and never appear here.

## [Unreleased]

- Fixed: event marker symbols (recurring/promoted/AI/imported) no longer overflow small event
  boxes — markers that don't fit are dropped, and boxes too small for the row hide it entirely
  (month bands re-center their title when the row hides).
- Added: dashboard TODO layering — each dashboard (daily/weekly/monthly) can choose which
  sources feed its list (event notes / daily / weekly / monthly notes), which collections show,
  and whether deadlines display; configured via a ⚙ cog (bottom-right of the TODO panel) or
  right-click in the list, both popping the same native menu. Defaults: each scope collects
  down to its own granularity (daily skips weekly/monthly notes; weekly skips monthly).
- Improved: the Batch Rename panel is now properly modal — the calendar behind it is blocked,
  Esc cancels from anywhere (reverting the live renames), and the panel has explicit
  Cancel / Rename buttons (Cancel restores the original titles).
- Fixed: weekly/monthly "TODOs this week/month" no longer list a nested sub-task as an
  isolated row — a qualifying sub-item promotes its parent, which renders with its full
  subtree (same rule as the daily dashboard), deduped against "Completed this week/month".
- Fixed: the daily NOTE tab could wedge showing the static preview with the toggle stuck on
  "Editor" (Enter/⌘-click dead) after an interrupted fly-to-today — an interrupted zoom left the
  zoom level a hair off its resting value and a bit-exact gate never mounted the live editor.
  Interrupted zooms now settle on the level, the gate is tolerant, and a panel render error can
  no longer wedge the dashboard pipeline (contained + logged instead).
- Added: gutter auto-hide — in month/week view with the dashboard pinned, when the window gets
  too narrow the month-name/track sidebar slides off-screen left (animated), giving the calendar
  and dashboard its width back; it slides back in when space allows or the dashboard unpins.
- Improved: the delete dialog is now systematic across every case — promoted lane bars offer
  "Remove from Lane" (the default) alongside delete/hide; imported recurring events gain
  "Hide Occurrence" next to "Hide Series"; a recurring event's first occurrence no longer shows
  the redundant "This & Future" (≡ delete series); and an already-hidden imported event offers
  "Unhide" instead of a dead-end notice.

## [0.1.0] — 2026-07-21

Baseline release — first versioned build, covering everything to date:

- Full native calendar: year/month/week/day zoom levels with continuous gesture navigation,
  timed events, multi-day bands, deadlines (with origin timezones), recurrence, promotion to
  band lanes, and full keyboard control (⌘K guide).
- Daily/weekly/monthly dashboards: TODO index over event + daily/scope notes (nested sub-tasks
  with folding), upcoming deadlines, per-scope markdown notes with live editor.
- Markdown notes: CodeMirror editor with task lists, Tab/⇧Tab nesting, todo token DSL
  (`due:` `start:` `p:` `followup:` `done:` `created:` `project:` `#tag` `@entity`), session-end
  `created:` stamping, frosted-glass previews.
- Apple Calendar import (EventKit), .ics import/export, iCloud sync (CloudKit, local-wins),
  multiple calendars, notifications with per-kind preferences.
- AI assistant (read/nav tools + calendar CRUD), event search, tag filtering, Performance Mode.
- iOS read-only companion app over the same CloudKit container.
