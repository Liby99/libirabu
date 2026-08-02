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
SCENE="${SCENE:-bench-year-scroll}"   # bench-year-scroll | bench-year-fling | bench-month-swipe | bench-week-swipe
TMP="$(mktemp -d /tmp/cc-bench.XXXXXX)"
BIN=".build/$CONFIG/CalendarMac"

echo "Building CalendarMac ($CONFIG)…"
swift build -c "$CONFIG" >/dev/null

case "${PAYLOAD:-display}" in
  display) cp bench/year-display-2026.json "$TMP/data.json" ;;  # expanded real load (recurrence + ghosts) — the default
  bands)   cp bench/year-bands-2026.json "$TMP/data.json" ;;
  empty)   cp bench/empty.json "$TMP/data.json" ;;    # stored 2026 bands only (the light fixture)
  dump)    cp "$HOME/.magical-bench/data.json" "$TMP/data.json" ;;  # CC_DUMP_DISPLAY of the REAL app (heavy: 1007 ev)
  dense)   cp bench/year-dense-2026.json "$TMP/data.json" ;;  # stress: real dump densified (3000 ev / ~500 bands @87% lane fill)
  todos)   cp bench/todo-dense-2026.json "$TMP/data.json" ;;  # stress: real store + ~500 July todos (scripts/gen-todo-dense.py)
  full)    cp "$HOME/Library/Application Support/CalendarKit/data.json" "$TMP/data.json" ;;  # raw live store (LEGACY single-file — misses calendars/!)
  store)   cp -R "$HOME/Library/Application Support/CalendarKit/." "$TMP/" ;;  # the WHOLE real base dir: registry + every calendar (incl. imports) + all notes — the true payload
  *) echo "unknown PAYLOAD=${PAYLOAD}"; exit 1 ;;
esac
echo "Launching bench scene (throwaway store at $TMP; payload=${PAYLOAD:-display} window=${WINDOW:-default} hover=${HOVER:-0})…"
# `env` so the optional ${…:+VAR=val} expansions are still parsed as environment assignments.
env CC_DEMO="$SCENE" CC_DEMO_DATADIR="$TMP" \
  ${WINDOW:+CC_WINDOW="$WINDOW"} ${HOVER:+CC_BENCH_HOVER=1} ${DWELL:+CC_BENCH_DWELL=1} ${MONTHS:+CC_BENCH_MONTHS="$MONTHS"} ${MOUNTALL:+CC_BENCH_MOUNT_ALL=1} \
  ${WEEKS:+CC_BENCH_WEEKS="$WEEKS"} ${WEEK_MONTH:+CC_BENCH_WEEK_MONTH="$WEEK_MONTH"} \
  ${DASH:+CC_BENCH_DASH=1} ${DASH_LEVEL:+CC_BENCH_DASH_LEVEL="$DASH_LEVEL"} ${DASH_TAB:+CC_BENCH_DASH_TAB="$DASH_TAB"} ${HOTKEY:+CC_BENCH_HOTKEY="$HOTKEY"} ${TRACE:+CC_TRACE=1} \
  ${DASH_PERIOD:+CC_BENCH_DASH_PERIOD="$DASH_PERIOD"} ${DASH_TOGGLES:+CC_BENCH_DASH_TOGGLES="$DASH_TOGGLES"} ${NATIVE:+CC_NATIVE_DASH=1} ${NATIVE_OFF:+CC_NATIVE_DASH_OFF=1} \
  ${PROF:+CC_PROF=1} ${PERF_OFF:+CC_PERF_OFF=1} ${DASHJSON_OFF:+CC_DASHJSON_OFF=1} ${WEB120_OFF:+CC_WEB120_OFF=1} ${WEB_DEFER_OFF:+CC_WEB_DEFER_OFF=1} ${FLING_STEPS:+CC_BENCH_FLING_STEPS="$FLING_STEPS"} \
  ${SWIPE_STEPS:+CC_BENCH_SWIPE_STEPS="$SWIPE_STEPS"} ${SWIPE_GAP:+CC_BENCH_SWIPE_GAP="$SWIPE_GAP"} "$BIN" &
APP_PID=$!
trap 'kill "$APP_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT
# SAMPLE=1 → capture a call-stack profile (sample(1)) over the scene's moving phase; knobs
# SAMPLE_DELAY (secs after launch, default 3.5) and SAMPLE_SECS (default 4). The raw call tree
# lands in bench/last-sample.txt for flamegraph collapsing.
if [ -n "${SAMPLE:-}" ]; then
  ( sleep "${SAMPLE_DELAY:-3.5}"; sample "$APP_PID" "${SAMPLE_SECS:-4}" -f "$TMP/sample.txt" >/dev/null 2>&1
    cp "$TMP/sample.txt" bench/last-sample.txt 2>/dev/null ) &
fi

# The scene takes ~10s (settle + two pace-locked glides); wait for its results file.
for _ in $(seq 1 300); do [ -f "$TMP/bench.json" ] && break; sleep 0.2; done
[ -f "$TMP/todofeed-ms.txt" ] && echo "cold todoFeed rebuild: $(cat "$TMP/todofeed-ms.txt") ms"
[ -f "$TMP/bench.json" ] || { echo "bench never produced results"; exit 1; }
sleep 0.2

# Tag results with the git branch (worktree-aware) so per-optimization branches compare cleanly.
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
python3 - "$TMP/bench.json" "$BRANCH|$SCENE/$CONFIG/${PAYLOAD:-display}/${WINDOW:-1440x840}/hover=${HOVER:-0}/dwell=${DWELL:-0}${MONTHS:+/m=$MONTHS}${WEEKS:+/w=$WEEKS}${WEEK_MONTH:+/wm=$WEEK_MONTH}${SWIPE_STEPS:+/ss=$SWIPE_STEPS}${DASH:+/dash=1}${DASH_LEVEL:+/dl=$DASH_LEVEL}${DASH_PERIOD:+/dp=$DASH_PERIOD}${NATIVE:+/native=1}${DASHJSON_OFF:+/djoff=1}${WEB120_OFF:+/w120off=1}${WEB_DEFER_OFF:+/wdoff=1}" <<'PY'
import json, sys, datetime
r = json.load(open(sys.argv[1]))
line = (f"{datetime.datetime.now():%Y-%m-%d %H:%M} [{sys.argv[2]}] "
        f"avg {r['avg_fps']:.1f} fps | HUD-min {r.get('hud_min_fps', float('nan')):.1f} fps | "
        f"p50 {r['frame_ms_p50']:.2f} ms | p95 {r['frame_ms_p95']:.2f} ms | "
        f"max {r['frame_ms_max']:.1f} ms | hitches(>33ms) {r['hitches_over_33ms']} | "
        + (f"MOVING: {r['moving_avg_fps']:.1f} fps p95 {r['moving_p95_ms']:.1f} ms hitches {r['moving_hitches']} | " if 'moving_avg_fps' in r else '')
        + (f"WEB: {r['web_avg_fps']:.1f} fps p50 {r['web_p50_ms']:.1f} p95 {r['web_p95_ms']:.1f} max {r['web_max_ms']:.1f} ms hitches {r['web_hitches']} | " if 'web_avg_fps' in r else '')
        + (f"WEB-MOVING: p95 {r['web_moving_p95_ms']:.1f} max {r['web_moving_max_ms']:.1f} ms hitches {r['web_moving_hitches']} | " if 'web_moving_p95_ms' in r else '')
        + (f"WEB-SLOWTICK: {r['web_longtasks']}x {r['web_longtask_ms']:.0f} ms (max {r['web_longtask_max_ms']:.0f}) | " if 'web_longtasks' in r else '')
        + f"{r['frames']} frames / {r['seconds']:.2f} s")
print("\n== bench ==\n" + line)
if 'hitch_offsets_s' in r: print('hitch offsets within turn (s):', r['hitch_offsets_s'])
if 'web_units' in r: print('web units >2ms (name ms):', ', '.join(r['web_units']))
if 'web_gaps' in r: print('web gaps >25ms (len@offset-from-turn):', ', '.join(r['web_gaps']))
if 'layers_ms' in r:
    print("\n-- per-layer CPU (main thread) --")
    print(f"  {'layer':<16}{'samples':>9}{'avg ms':>9}{'total ms':>10}{'peak ms':>9}")
    for k in sorted(r['layers_ms']):
        n, avg, tot, peak = r['layers_ms'][k]
        print(f"  {k:<16}{int(n):>9}{avg:>9.3f}{tot:>10.1f}{peak:>9.3f}")
open("bench/results.log", "a").write(line + "\n")
PY
