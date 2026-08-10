# MagnifiCal — Changelog (private)

The running, developer-facing log for the native apps (macOS MagnifiCal + iOS read-only client).
Not shipped with the app; the public TestFlight "What to Test" notes are distilled from here at
each release.

**Workflow** (see also `CalendarApp/DISTRIBUTE.md`):
- Every user-visible feature or bug fix lands as a bullet under **[Unreleased]** in the same
  change/PR that implements it. Keep bullets one line, user-visible phrasing, most recent last.
- On a version bump: retitle **[Unreleased]** to the new version + date, distill the public
  changelog from it — BOTH the release notes AND the in-app Help ▸ What's New entries
  (`MagnifiCalKit/Sources/CalendarUI/Help/Changelog.swift`) — start a fresh empty
  **[Unreleased]**, bump `MARKETING_VERSION` + `CURRENT_PROJECT_VERSION` in
  `MagnifiCalApp/project.yml`, tag `vX.Y.Z` in git.
- Versions are semver-ish while pre-1.0: **0.MINOR.PATCH** — MINOR for feature releases,
  PATCH for fix-only releases. Build numbers (`CURRENT_PROJECT_VERSION`) are a separate,
  per-upload counter and never appear here.

## [Unreleased]

_(nothing yet)_

## [0.2.0] — 2026-08-10

- Added: the direct (Developer-ID) build updates itself via Sparkle — App menu ▸
  "Check for Updates…", plus a daily background check against the GitHub releases
  appcast. (Mac App Store builds will exclude Sparkle.)
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
- Improved: note preview task checkboxes now match the dashboard TODO list exactly (same custom
  rounded box + accent check), checked items strike through (text only — badges and sub-items
  stay legible), and ticking a box in preview stamps/strips the `done:` time exactly like the
  dashboard toggle. Static note previews show the same done styling.
- Added: project event boxes — a band event whose note (or a recurring band's "This Event"
  occurrence note) carries a bare @project:name line now charts on that project's timeline as a
  rounded region spanning all task tracks over its dates, with the event's name along its top
  edge (clickable to open the event); the box is pointer-transparent so task rows stay usable.
- Fixed: a recurring event's "This Event" (per-occurrence) note was broken twice over — typing
  in This Event scope silently edited the All Events (series) note instead (a stale editor
  binding), and occurrence notes were missing from the CloudKit record mapping so any that WERE
  saved got wiped by the next sync echo. Both fixed; per-occurrence notes now save, preview,
  and round-trip through iCloud correctly.
- Fixed: hover-cursor flicker over events (grab hand fighting the default pointer), worst in
  year view right after launch — the invisible dashboard WebView kept its own mouse tracking
  alive; it is now truly hidden whenever faded out, including at launch.
- Fixed: deleted events could resurrect after a while — records from OTHER calendars' CloudKit
  zones (e.g. migration leftovers) merged into the active calendar on every fetch, while deletes
  only ever targeted the active zone. Inbound sync now filters to the calendar's own zone and
  fetches are zone-scoped. Settings ▸ Developer gains "Prune Orphaned iCloud Zones…" to delete
  the leftover zones (with confirmation; registered calendars and the registry are never touched).
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
- Fixed: clicking a note-sourced TODO row now reliably lands in the note editor — it navigates to
  the note's day/week/month, opens the dashboard's NOTE tab, and leaves the editor focused in edit
  mode with the clicked line selected. Previously the landing's "note has content → preview"
  default flipped the editor back to preview right after the jump (losing focus + selection), and
  the focus itself raced the travel on a timed retry. The focus is now a callback that fires the
  moment the target note's editor mounts (the end of the fly-to animation) and is dropped if the
  jump is superseded first (tab switched away, preview toggled, or the flight interrupted).
- Improved: PROJ panel loading no longer lags — task ranking computed scores inside the sort
  comparator (~90ms release / several× that in debug on a busy year, on the main thread at every
  tab open), and all chart/score date math went through Foundation's Calendar (~6.6µs per call,
  under every bar, tick, and axis label). Scores are now computed once before sorting and day
  arithmetic is pure integer math (~100× faster, golden-tested against Calendar). The full-note
  tokenize that feeds the TODO/PROJ panels now rebuilds on a background queue (serve-stale caches,
  serialized publishes) instead of hitching the main thread after edit/sync bursts, and the launch
  prewarm — previously only active in demo mode by accident — warms both feeds on every launch.
- Fixed: .ics import no longer shifts Outlook/Exchange events by the device's UTC offset (the
  consistent "-4h" bug). TZIDs now resolve through a full chain — IANA names, Windows zone names
  ("Eastern Standard Time" → America/New_York, the complete CLDR table), the file's own VTIMEZONE
  rules (seasonal offsets), Mozilla-style path TZIDs, and embedded "(UTC±HH:MM)" offsets — and an
  unresolvable TZID now keeps the sender's wall clock (floating) instead of silently assuming UTC.
  Also: quoted property parameters parse correctly, DURATION is honored when DTEND is absent, and
  STATUS:CANCELLED stubs are skipped. Applies to both file import and Google Calendar feeds.
- Fixed: typing in a dashboard notepad no longer flickers or loses text, and ⌘S no longer makes
  the rendered preview blink old text — the coalesced data round-trip (keystroke → engine →
  dashboard JSON push) runs a few keystrokes behind the editor, and the editor was adopting those
  stale echoes, wiping the newest characters (for good, when more typing raced the revert). Every
  edit post now carries a sequence number that the engine echoes back inside the payload; the
  editor refuses any payload older than its own latest edit. Genuine external rewrites (checkbox
  toggles, undo, cloud sync) arrive caught-up and still sync in.
- Improved: jumping to a MONTHLY note (todo row / gantt title click) while already in month view
  now animates — a fast month-pagination glide toward the target month instead of an instant snap.
- Fixed: todo-row jumps from month/week view now reliably finish on the NOTE tab with the editor
  focused and the clicked line selected — the tab switch happens on LANDING (a new land callback
  for week/month jumps, and the day jump's landing now fires outside the render pass), so the
  "leaving day view resets to the TODO tab" rule can no longer clobber it mid-flight.
- Fixed: closing the calendar window and reopening it no longer loses the view position — month
  view snapped back to January and week view to the month's first week (day view would have
  snapped to the 1st). The recreated invisible pager scroll views reported their initial offset 0
  into the engine before being positioned; they now stay read-only until the first engine→pager
  sync has been applied.

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
