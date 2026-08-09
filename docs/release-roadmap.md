# MagnifiCal: Open-Source + App Store Release Roadmap

The plan, decided 2026-08: **IINA-style dual track** — the source is public under GPLv3 on
GitHub (issues, PRs, community), and a convenience build ships on the Mac App Store at
**$7.99 one-time**. Direct notarized downloads stay free forever (that's the GPL promise);
the MAS price buys auto-updates, one-click install, and supporting the project. Two-way
sync and other server-shaped features are explicitly **out of scope** for v1 — the app
ships as-is: local-first, iCloud sync, read-only imports.

The phases are ordered so that each one is independently useful: friends get the app in
Phase 1 even if Phase 3 never happens.

---

## Phase 1 — Smooth delivery to friends & students (1–2 weeks)

The nearest goal: anyone you hand a link can install and stay current with zero ceremony.

- [ ] **GitHub Releases as the distribution channel.** Notarized Developer-ID DMG uploaded
      per release (the signing + notarization pipeline already exists — see DISTRIBUTE.md).
      A stable link like `github.com/<you>/MagnifiCal/releases/latest` goes in every message
      to friends.
- [ ] **Sparkle auto-updates.** This is the single biggest "smooth delivery" lever for the
      direct build: friends install once and never re-download a DMG. Sparkle 2 is the
      standard (used by IINA); the appcast XML can be hosted straight from GitHub Pages or
      Releases. Wire the "Check for Updates…" item into the shared AppMenu spec so both
      shells stay in sync.
- [ ] **Crash visibility without telemetry.** No analytics (it's a selling point — see
      Privacy below). Instead: a Help ▸ "Report a Problem…" item that opens a prefilled
      GitHub issue, and a documented way to attach the unified-log output.
- [ ] **iPhone companion via TestFlight** (already working). Put the public TestFlight
      link next to the DMG link.
- [ ] **Versioning discipline.** Keep semver + CHANGELOG.md (already in place); every
      Release gets human release notes — these become marketing copy later.

## Phase 2 — Open-sourcing the repo (2–3 weeks, can overlap Phase 1)

Publish a **fresh, extracted repository** (working name: `MagnifiCal`), not this monorepo:
the private repo's history carries personal fixtures, private changelog notes, and the
unrelated web-app lineage. Curated clean history from day one; the private repo stays as
the archive.

- [ ] **Extract** `native/CalendarKit`, `native/CalendarApp`, `native/eventkit-bridge`,
      `native/scripts`, and the relevant `docs/` design notes into the new repo. Keep the
      package layering (Geometry → Engine → Render → UI) — it is the architecture story
      contributors will navigate by.
- [ ] **Secrets & privacy audit before the first push:** no API keys (Keychain-only —
      verify), no personal calendar data in fixtures/demo payloads, no JHU-gateway
      specifics beyond a generic "OpenAI-compatible endpoint" config, team id scrubbed
      from project.yml if desired (it's public in any signed binary anyway).
- [ ] **License: GPLv3** + a lightweight **CLA** (cla-assistant bot). The CLA is not
      optional in this plan: as sole copyright holder you can ship the MAS build despite
      the GPL/App-Store friction (the VLC problem), but the moment an outside PR merges,
      you need contributors' grant to distribute their code under MAS terms. One checkbox
      per contributor, automated, done.
- [ ] **README that sells.** Hero GIF at the top (the pinch-zoom year→day dive — the demo
      recorder already produces exactly these), a 3-line pitch ("a calendar you zoom,
      with notes and todos living inside it"), feature GIFs, install links (DMG / MAS /
      build-from-source), and the "why GPL + paid MAS build" paragraph borrowed from
      IINA's playbook.
- [ ] **Contribution surface.** CONTRIBUTING.md covering: `swift build` / `swift test`
      (181 hermetic tests, no signing needed — contributors can verify without Xcode
      app targets), the swiftformat config, the bench harness for perf-sensitive PRs,
      and the "docs/ design notes are the spec" convention. Issue templates (bug /
      feature / import-quirk), PR template with a "ran swift test" checkbox.
- [ ] **CI: GitHub Actions** running `swift build && swift test` on macOS runners for
      every PR. The package tests are already hermetic (temp-dir stores) — this is nearly
      free to set up and is what makes drive-by PRs reviewable.
- [ ] **Seed ~10 `good first issue`s.** Realistic contributor lanes for a calendar app:
      ICS provider quirks (every vendor's feed is weird in a new way), localization,
      Help-book topics, theme/palette work, keyboard-shortcut gaps, import edge cases
      with attached .ics fixtures. Label them before announcing anything.
- [ ] **GitHub Discussions on, Issues for bugs only** — keeps the tracker triageable.
      CODEOWNERS: you.

## Phase 3 — Mac App Store at $7.99 (2–4 weeks after Phase 2)

- [ ] **App Sandbox adoption** — the one real engineering item (tracked as the known
      blocker in the release process). Entitlements needed: calendars (EventKit import —
      plus the usage strings already present), network client (ICS feeds, AI providers),
      user-selected file read/write (.ics/.mdc import/export via NSOpenPanel — already
      panel-based, so this is mostly config), CloudKit + push (already entitled),
      Keychain. Audit file paths: everything under the app container; the calendars/
      data dir already lives in Application Support.
- [x] **Name decision — RESOLVED (2026-08-08): the app is "MagnifiCal".** The former
      name "MagiCal" collided: an existing $1.99 Mac App Store menu-bar calendar
      (id 1435000259), an older classic-macOS app of the same name on MacUpdate, and
      "Magical" (getmagical.com), a funded startup with calendar products. "MagnifiCal"
      (a real archaic word for "magnificent", containing "magnify" — the zoom) has no
      findable app, GitHub, or product collisions; magnifical.dev is registered (ours).
      The rename was display-only — internal ids (dev.libirabu.calendar, store paths,
      CloudKit zones) unchanged, per the Madocal→MagiCal precedent.
- [ ] **App Review prep:** AI assistant is BYO-key (allowed; describe it plainly),
      age rating, no private APIs (TransparentTitlebar's view-hierarchy walk is worth a
      re-check — it inspects but doesn't use private API; keep a fallback if review
      objects), demo video for the reviewer.
- [ ] **Privacy story — lean into it.** App Privacy label: "Data Not Collected" (no
      analytics, no servers, keys in Keychain, sync via the user's own iCloud). A
      one-page privacy policy on the website states exactly that. This is a genuine
      differentiator against subscription calendars.
- [ ] **Listing assets:** screenshots at each zoom level (light + dark), the 30-second
      App Preview cut from the demo recorder scenes, $7.99 tier, in the Productivity
      category.
- [ ] **Messaging discipline:** MAS listing and README both say the same thing — "MagnifiCal
      is free software (GPLv3). The App Store version is identical and supports
      development." Price friction disappears when the free path is honest and visible.

## Phase 4 — Zero-budget promotion (ongoing; first push at MAS launch)

Assets first, posts second. Everything below costs time only.

- [ ] **The 60–90s hero video**: one continuous take — year fling → pinch to month →
      week → day, drag an event, type a todo in the dashboard, ⌘J gantt. The existing
      GIF-recording infrastructure (deterministic demo scenes, both themes) makes this
      unusually cheap to produce well. This one asset feeds every channel below.
- [ ] **Website on GitHub Pages** (free): single page, hero video, three GIFs, download
      buttons (MAS / DMG / GitHub), privacy line. Custom domain optional later.
- [ ] **Launch sequence, one channel at a time** (so each gets a real day of attention):
      1. **Show HN** ("Show HN: MagnifiCal – a zoomable calendar for macOS, GPL, built in
         SwiftUI") — lead with the engineering story; HN loves the 120fps + open-source
         angle. Be present in comments all day.
      2. **Product Hunt** a week later — lead with the product story; the video carries it.
      3. **Reddit**: r/macapps (very receptive to indie + open-source), r/macOS,
         r/opensource, r/productivity — each with channel-native phrasing, spaced out.
      4. **Mastodon + X**: the mac-dev community (#macdev, #SwiftUI) with the zoom GIF;
         short thread on how the canvas renderer works — dev-community posts travel.
      5. **Tips emails**: MacStories, 9to5Mac, MacRumors, Daring Fireball — two
         sentences, the video link, the GPL angle. Low hit-rate, huge payoff if one lands.
      6. **Newsletters/aggregators**: iOS Dev Weekly (engineering write-up), Dense
         Discovery, AlternativeTo listing (free), OpenAlternative-style directories.
- [ ] **The engineering blog post** (repo `docs/` or the website): "Rendering a 120fps
      zoomable year in SwiftUI" — the canvas fast path, layer caches, and glass fallback
      story. This is your strongest organic asset: it markets the app to exactly the
      people who star repos and write PRs.
- [ ] **Friends & students as the seed community**: personally onboard them via the
      Releases link, ask each for one GitHub issue (bug or wish) in week one — a tracker
      with 30 real issues makes the project look alive before any public launch.
- [ ] **Cadence over splash**: after launch week, one visible artifact per month is
      enough — a release with notes, a short demo clip, or a blog post. Dead repos lose
      the audience that launches win.

## Explicit non-goals for v1

- Two-way Google/Outlook sync (position the app honestly: "shows your external
  calendars, read-only; owns its own data"). Revisit only on demonstrated demand.
- Windows/web/Android, teams/sharing, any server component, any analytics.

## Sequencing summary

Phase 1 unblocks friends immediately → Phase 2 makes the project public and credible →
Phase 3 adds the $7.99 MAS build (sandbox is the only hard dependency) → Phase 4 fires
when there's something installable from two channels. Total calendar time at a relaxed
solo pace: roughly two months to the MAS launch post.
