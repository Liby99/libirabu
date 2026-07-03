#!/usr/bin/env bash
# Production server for the "this Mac is the persistent server" setup
# (docs/calendar-import-design.md §12 packaging). Orchestrates the whole stack on :8100:
#   1) ensure Postgres (docker) is up   2) refresh the Prisma client   3) apply migrations
#   4) build if there's no production build yet   5) run `next start` (NOT the dev server)
#
# Run manually with `npm run serve`, or let the Libirabu menu-bar app exec this on launch.
# Because it's `next start` (a real build), first launch is slow (it builds) and code changes need a
# rebuild — quit the app and re-run, or run `npm run build` then restart.
set -euo pipefail
cd "$(dirname "$0")/.."

# Prefer the Node baked into the app (LIBIRABU_NODE); fall back to PATH / Homebrew. Then make sure
# node + docker are findable even under the minimal PATH a LaunchServices-launched app inherits.
NODE="${LIBIRABU_NODE:-$(command -v node || echo /opt/homebrew/bin/node)}"
export PATH="$(dirname "$NODE"):/opt/homebrew/bin:/usr/local/bin:$HOME/.docker/bin:/usr/bin:/bin"
PORT="${PORT:-8100}"
BIN=./node_modules/.bin

log() { echo "[serve] $*"; }

log "ensuring Postgres is up…"
docker compose up -d db

log "waiting for Postgres to accept connections…"
for _ in $(seq 1 30); do
  docker compose exec -T db pg_isready -U libirabu >/dev/null 2>&1 && break
  sleep 1
done

# Keep the generated client in lock-step with the schema on every boot — this is what makes a
# schema change "just work" after a restart (no more stale-client 500s).
log "refreshing Prisma client…"
"$BIN/prisma" generate

log "applying migrations…"
"$BIN/prisma" migrate deploy

if [ ! -f .next/BUILD_ID ]; then
  log "no production build found — building (first launch is slow)…"
  "$BIN/next" build
fi

log "starting Next (production) on :$PORT"
exec "$BIN/next" start -p "$PORT"
