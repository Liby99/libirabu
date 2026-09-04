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

### Fixed
- Dragging a deadline by its label pill moves the moment line WITH the pill again — the line's
  canvas never re-recorded during a label drag (its inputs were read inside the draw closure,
  invisible to SwiftUI); it now invalidates exactly when a deadline or its activation changes.

## [0.3.1] — 2026-08-20

### Added
- iPhone: the dashboard drawer — the Mac's TODO / PROJ / NOTE panels as a read-only bottom
  sheet (checklist toolbar button); scope follows the zoom level.
- iPhone: configuration lives in Settings ▸ MagnifiCal (frame-rate HUD, calendar switching,
  version); the toolbar Menu button is gone.
- Settings ▸ Developer ▸ "Push Everything to iCloud" — re-offers the active calendar + the
  calendar registry to the server (recovery for a never-populated production environment).

### Fixed
- iPhone: a fresh install now adopts the primary cloud calendar instead of rendering the empty
  bootstrap default forever, and Debug phone builds read the PRODUCTION CloudKit environment
  (where the shipped Mac app's data lives).
- Cloud sync logs its lifecycle and failures (subsystem dev.magnifical.calendar, category
  cloud) — fetch/send errors were silently swallowed.

### Improved
- iPhone: compact breadcrumb ("2026 › Aug › Wk 4 › 19").
- Improved: the app is ~12MB lighter. Tutorial demos are compact mp4 clips now (sharper
  AND smaller than the old GIFs), and the Help browser's demos/screenshots stream from
  GitHub on first view (cached locally, pinned to the release) instead of shipping in
  the bundle. Also fixed: the dark-theme markdown-notes tutorial slide was a broken
  4KB stub - re-recorded.
- Improved: the menu-bar item is now a calendar (not the AI sparkles), with "Open
  MagnifiCal" on top and a new "Past Conversations" that opens the chat with the
  conversations sidebar revealed.

## [0.3.0] — 2026-08-19

- Added: Help ▸ What's New — the changelog in its own window, each release's entries
  formatted with Added/Improved/Fixed badges (curated in Changelog.swift).
- Added: the Welcome tutorial's dashboard-tour slide is recorded (light + dark); demo
  recordings no longer inherit this device's dashboard prefs (deterministic scenes).
- Improved: the pinned monthly dashboard opens wider by default (0.25 → 0.32 of the
  window; a width you dragged yourself is kept).
- Added: per-subscription default colors for Google/Outlook feeds — a swatch dropdown on
  each Settings row, palette-cycled on subscribe; changing it re-colors the feed's
  imported events you haven't individually recolored (and imported all-day bands now
  honor color choices at all).
- Improved: fully native — removed the retired web-based note editor and its ~3MB of
  bundled JavaScript (smaller app, one less rendering stack).
- Fixed: typing in a note — especially a `#tag` — no longer gets laggier with every
  character. Each keystroke was re-parsing the note's tags and invalidating the display
  caches + the autocomplete index (a full rescan per keypress); the tag cache now settles
  once, ~0.35s after typing pauses.
- Fixed: a line beginning with a `#tag` (no space after `#`) no longer renders as a huge
  heading in note previews — it chips as a tag, matching CommonMark and the editor's own
  highlighting. Real headings (`# Title`, with the space) are unchanged.
- Changed: tags are markdown now — type `#tag` anywhere in an event's note (a space after
  `#` still makes a heading); the drawer's separate Tags UI is gone. Existing tags migrate
  into the notes as `#tokens` automatically (illegal characters become `-`), previews keep
  rendering them as chips, and search/filter/dashboards keep working (the old tags field
  lives on as a cache recomputed on every note save).
- Week/day timelines: events scrolled out of view now hold as small cards pinned at the
  top/bottom edge — event color + accent bar, stacked Apple-Calendar-style as a staircase
  (nearest event tallest and innermost, up to 3 per day column), morphing smoothly with the
  scroll; clicking a stack scrolls the nearest hidden event back into view.
- Fixed: with two note editors open (e.g. the dashboard notepad and an event's note in
  the drawer), Cmd+S could save the editor you weren't typing in - it now saves exactly
  the note holding the cursor.
- Fixed: the Help browser's "Projects & Gantt charts" / "How tokens show up" screenshots
  and the tutorial's AI-assistant recording were stale or mis-captured (wrong tab, a grey
  veil, an interrupted take) - re-captured from the scripted scenes in both themes.

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
