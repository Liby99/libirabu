#!/bin/bash
# Sync the PUBLIC MagnifiCal repository working tree from this private monorepo.
#
# The public repo is the user's clone of github.com/Liby99/magnifical, living at
# ../magnifical next to this monorepo (override with $1). This script makes its working
# tree an exact mirror of the publishable subset — rsync --delete, so removals in the
# monorepo propagate — leaving .git and LICENSE alone. Review + commit + push happen in
# the public repo afterward, by hand:
#
#   native/scripts/export-public-repo.sh            # sync to ../magnifical
#   cd ../magnifical && git add -A && git commit && git push
#
# What it deliberately EXCLUDES (see docs/release-roadmap.md, Phase 2 audit):
#   • MagnifiCalKit/bench/*.json      — REAL personal calendar payloads (attendee emails,
#                                     meeting links). Regenerate synthetic ones before
#                                     publishing bench workflows publicly.
#   • MagnifiCalKit/legacy/           — retired webview experiments, monorepo-only.
#   • PUBLISH-CHECKLIST.md          — operator notes (stays in native/public-repo/).
#   • build products, xcuserdata, .DS_Store, results logs.
# What it ADDS: the boilerplate staged in native/public-repo/ (README, CONTRIBUTING,
#   .github templates + CI, .gitignore) at the repo root.

set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"           # native/
root="$(cd "$here/.." && pwd)"                     # monorepo root
target="${1:-$root/../magnifical}"

if [ ! -d "$target/.git" ]; then
    echo "error: $target is not a git repository (expected the magnifical clone)." >&2
    echo "       clone it first: git clone git@github.com:Liby99/magnifical.git $target" >&2
    exit 1
fi

# Stage the publishable subset in a temp tree, then mirror it into the repo in ONE
# rsync --delete pass (so files removed from the monorepo disappear from the repo too).
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

copy() { # copy a tree, pruning junk
    rsync -a \
        --exclude '.DS_Store' --exclude 'build/' --exclude '.build/' \
        --exclude 'xcuserdata/' --exclude '*.xcuserstate' \
        --exclude 'results*.log' \
        "$1" "$2"
}

echo "→ CalendarKit (sans bench payloads + legacy)"
copy "$here/MagnifiCalKit/" "$stage/MagnifiCalKit/"
rm -rf "$stage/MagnifiCalKit/legacy"
# Bench HARNESS docs stay (they document the workflow); the real-data payloads go.
find "$stage/MagnifiCalKit/bench" -name '*.json' -delete 2>/dev/null || true

echo "→ CalendarApp"
copy "$here/MagnifiCalApp/" "$stage/MagnifiCalApp/"

echo "→ eventkit-bridge + scripts"
[ -d "$here/eventkit-bridge" ] && copy "$here/eventkit-bridge/" "$stage/eventkit-bridge/"
mkdir -p "$stage/scripts"
copy "$here/scripts/" "$stage/scripts/"
rm -f "$stage/scripts/export-public-repo.sh" # monorepo-only tool

echo "→ design docs (ai-assistant-design stays private: university-gateway internals)"
mkdir -p "$stage/docs"
for d in calendar-import-design.md keyboard-navigation.md; do
    [ -f "$root/docs/$d" ] && cp "$root/docs/$d" "$stage/docs/"
done

echo "→ public-repo boilerplate (README, CONTRIBUTING, .github, .gitignore) + format config"
copy "$here/public-repo/" "$stage/"
rm -f "$stage/PUBLISH-CHECKLIST.md" # operator notes never publish
cp "$here/.swiftformat" "$stage/.swiftformat" # CI's lint step + contributors format against it

echo "→ sanitize operator docs (author ids, signing identity)"
perl -pi -e 's/ziyang\@cs\.jhu\.edu/<your-apple-id>/g' "$stage/MagnifiCalApp/DISTRIBUTE.md"
perl -pi -e 's/ · Owner: ziyang//g' "$stage"/docs/*.md "$stage"/MagnifiCalKit/docs/*.md 2>/dev/null || true

echo "→ safety: no personal data may leave the monorepo"
# Allowlisted survivors: the fictional test address, fabricated example links in design
# docs/scenarios, and CODE that merely detects meeting-link hosts (ManagedNote).
hits="$(grep -rniE "ziyang|jh\.edu|jhu\.edu|upenn|zoom\.us|meet\.google" "$stage" \
    | grep -viE 'tommy@cs\.jhu\.edu|meet\.google\.com/abc|zoom\.us/j/9876|contains\("meet\.google|contains\("zoom|linkLabel' \
    || true)"
if [ -n "$hits" ]; then
    echo "error: personal-data grep hit — aborting before anything reaches $target:" >&2
    echo "$hits" | head >&2
    exit 1
fi

echo "→ mirror into $target (keeping .git + LICENSE)"
rsync -a --delete --exclude '.git' --exclude 'LICENSE' "$stage/" "$target/"

echo
echo "Synced. Review + ship:  cd $target && git status && git add -A && git commit && git push"
