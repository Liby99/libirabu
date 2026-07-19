#!/bin/bash
# Year-view scroll benchmark: loads a REAL year of bands (bench/year-bands-2026.json, dumped from the
# testing calendar) into a throwaway store, launches the app in CC_DEMO=bench-year-scroll (which glides
# Jan→Dec→Jan with the pace-locked scroll tween while counting rendered frames), then prints the stats.
#
#   ./scripts/bench-year.sh                 # release build (real perf numbers)
#   CONFIG=debug ./scripts/bench-year.sh    # debug build (matches day-to-day dev feel)
#   PAYLOAD=full   — copy the ENTIRE current store (events+deadlines+bands) instead of the bands fixture
#   WINDOW=2560x1400 — bench at a bigger window (raster cost scales with pixels)
#   HOVER=1        — wiggle the pointer during the scroll (real trackpad scrolls pay per-move hit-tests)
#
# Results are also appended to bench/results.log so runs before/after an optimization can be compared.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
TMP="$(mktemp -d /tmp/cc-bench.XXXXXX)"
BIN=".build/$CONFIG/CalendarMac"

echo "Building CalendarMac ($CONFIG)…"
swift build -c "$CONFIG" >/dev/null

case "${PAYLOAD:-display}" in
  display) cp bench/year-display-2026.json "$TMP/data.json" ;;  # expanded real load (recurrence + ghosts) — the default
  bands)   cp bench/year-bands-2026.json "$TMP/data.json" ;;    # stored 2026 bands only (the light fixture)
  full)    cp "$HOME/Library/Application Support/CalendarKit/data.json" "$TMP/data.json" ;;  # raw live store
  *) echo "unknown PAYLOAD=${PAYLOAD}"; exit 1 ;;
esac
echo "Launching bench scene (throwaway store at $TMP; payload=${PAYLOAD:-display} window=${WINDOW:-default} hover=${HOVER:-0})…"
# `env` so the optional ${…:+VAR=val} expansions are still parsed as environment assignments.
env CC_DEMO=bench-year-scroll CC_DEMO_DATADIR="$TMP" \
  ${WINDOW:+CC_WINDOW="$WINDOW"} ${HOVER:+CC_BENCH_HOVER=1} "$BIN" &
APP_PID=$!
trap 'kill "$APP_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT

# The scene takes ~10s (settle + two pace-locked glides); wait for its results file.
for _ in $(seq 1 300); do [ -f "$TMP/bench.json" ] && break; sleep 0.2; done
[ -f "$TMP/bench.json" ] || { echo "bench never produced results"; exit 1; }
sleep 0.2

python3 - "$TMP/bench.json" "$CONFIG/${PAYLOAD:-display}/${WINDOW:-1440x840}/hover=${HOVER:-0}" <<'PY'
import json, sys, datetime
r = json.load(open(sys.argv[1]))
line = (f"{datetime.datetime.now():%Y-%m-%d %H:%M} [{sys.argv[2]}] "
        f"avg {r['avg_fps']:.1f} fps | p50 {r['frame_ms_p50']:.2f} ms | p95 {r['frame_ms_p95']:.2f} ms | "
        f"max {r['frame_ms_max']:.1f} ms | hitches(>33ms) {r['hitches_over_33ms']} | "
        f"{r['frames']} frames / {r['seconds']:.2f} s")
print("\n== year-scroll benchmark ==\n" + line)
open("bench/results.log", "a").write(line + "\n")
PY
