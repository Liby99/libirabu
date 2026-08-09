# Publish checklist (delete this file before the repo goes public)

Work top to bottom. The export script staged everything; these are the manual steps.

## Name: MagnifiCal (decided 2026-08-08)

The app is "MagnifiCal" — renamed from "MagiCal", which collided with an existing App
Store calendar (id 1435000259). Repo name, listing, appcast, and README all use
MagnifiCal; magnifical.dev is registered and will host the site.

## Must-do before `git push`

- [ ] **LICENSE**: add the full GPLv3 text —
      `curl -o LICENSE https://www.gnu.org/licenses/gpl-3.0.txt`
- [ ] **Verify the personal-data exclusions took** (the 2026-08 audit found REAL
      attendee emails + meeting links in bench payloads):
      `grep -rniE "ziyang|jh\.edu|jhu\.edu|upenn|zoom\.us|meet\.google" . | grep -v tommy@cs.jhu.edu`
      → should return nothing (tommy@ is a fictional test address and fine).
- [ ] **Fresh eyes pass** over `MagnifiCalApp/project.yml` (team id — public in any signed
      binary, but strip if you prefer) and `docs/` for anything you wouldn't publish.
- [ ] **README TODOs**: record + embed the hero GIF; fix the TestFlight link.
- [ ] `swift build && swift test` INSIDE the exported tree (catches accidental
      dependencies on excluded files — e.g. bench payloads).

## Repo creation

- [ ] `git init && git add -A && git commit -m "MagnifiCal 0.1.0 — first public release"`
- [ ] `gh repo create MagnifiCal --public --source . --push` (or via github.com)
- [ ] Enable **Discussions**; Issues get the three templates automatically.
- [ ] Create labels: `good first issue`, `import`, `perf`, `help wanted`.
- [ ] Seed ~10 `good first issue`s (ICS quirks, Help topics, keyboard gaps, l10n).
- [ ] **CLA bot**: install cla-assistant (free for OSS) with a simple individual CLA
      granting the project rights to distribute contributions in the App Store build.
      Required before merging ANY outside PR (GPL + MAS — see docs/release-roadmap.md).
- [ ] Branch protection on `main`: require CI green.

## Bench payloads (excluded — regenerate synthetic ones)

The private repo's `MagnifiCalKit/bench/*.json` were captured from a real calendar and are
NOT exported. Before advertising the bench workflow to contributors, regenerate dense
payloads synthetically (BenchStaging can seed; keep item counts comparable: ~500 bands /
~3000 events for the dense scenes) and commit those instead.

## After publishing

- [ ] First GitHub Release: notarized DMG + release notes (see DISTRIBUTE.md).
- [ ] Sparkle: generate EdDSA keys (`generate_keys`), KEEP THE PRIVATE KEY OUT OF THE
      REPO (Keychain/password manager), add the public key + appcast URL to the app,
      publish the appcast from Releases. (Direct build only — never in the MAS build.)
- [ ] Point friends/students at `/releases/latest` + the TestFlight link.
