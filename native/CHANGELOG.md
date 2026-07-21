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

_(nothing yet — next entries go here)_

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
