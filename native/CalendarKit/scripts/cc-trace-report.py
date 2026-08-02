#!/usr/bin/env python3
"""Analyze a cc-trace file (CC_TRACE=1 interaction profiler dump).

Usage: python3 scripts/cc-trace-report.py /path/to/cc-trace-*.trace [--top N]

Reconstructs, from the user's OWN interaction session:
  1. A frame-rate timeline segmented by input events (which action → which frame rate).
  2. The worst windows (lowest fps / longest frame stalls), each with its FOLDED main-thread
     stacks — a text flamegraph of what the main thread was doing while frames stalled.
"""
import sys
import collections

def main():
    path = sys.argv[1]
    top_n = int(sys.argv[sys.argv.index("--top") + 1]) if "--top" in sys.argv else 8

    events = []   # (t_ms, label)
    frames = []   # (t_ms, z, pin)
    samples = []  # (t_ms, [addr,...]) leaf-first
    syms = {}

    for line in open(path):
        parts = line.rstrip("\n").split(" ")
        if not parts:
            continue
        if parts[0] == "E":
            events.append((float(parts[1]), " ".join(parts[2:])))
        elif parts[0] == "F":
            frames.append((float(parts[1]), float(parts[2]), float(parts[3])))
        elif parts[0] == "S":
            samples.append((float(parts[1]), parts[2:]))
        elif parts[0] == "Y":
            syms[parts[1]] = " ".join(parts[2:])

    print(f"trace: {len(frames)} frames, {len(samples)} samples, {len(events)} events, "
          f"{len(syms)} symbols")
    if not frames:
        return

    def sym(addr):
        return syms.get(addr, "0x" + addr)

    # ── 1. Interaction segments: event → next event, with frame stats ──
    print("\n== interaction timeline (event → fps until next event) ==")
    bounds = [(t, lbl) for t, lbl in events] + [(frames[-1][0], "<end>")]
    for i in range(len(bounds) - 1):
        t0, lbl = bounds[i]
        t1 = bounds[i + 1][0]
        if t1 - t0 < 30:
            continue
        fs = [t for t, _, _ in frames if t0 <= t < t1]
        if len(fs) < 2:
            print(f"  {t0/1000:7.2f}s {lbl:<28} {(t1-t0)/1000:6.2f}s   NO FRAMES")
            continue
        dur = (fs[-1] - fs[0]) / 1000
        fps = (len(fs) - 1) / dur if dur > 0 else 0
        gaps = [b - a for a, b in zip(fs, fs[1:])]
        worst = max(gaps)
        n_hitch = sum(1 for g in gaps if g > 33)
        flag = "  <<<" if fps < 60 or worst > 100 else ""
        print(f"  {t0/1000:7.2f}s {lbl:<28} {(t1-t0)/1000:6.2f}s  "
              f"{fps:6.1f} fps  worst {worst:6.0f}ms  hitches {n_hitch}{flag}")

    # ── 2. Worst stall windows with folded stacks ──
    print(f"\n== top {top_n} frame stalls, with main-thread stacks during each ==")
    gaps = []
    for (a, _, _), (b, _, _) in zip(frames, frames[1:]):
        if b - a > 50:
            gaps.append((b - a, a, b))
    gaps.sort(reverse=True)
    for gap_ms, a, b in gaps[:top_n]:
        near = [lbl for t, lbl in events if a - 800 <= t <= b]
        print(f"\n-- stall {gap_ms:.0f}ms at {a/1000:.2f}s  (recent events: {near[-3:]}) --")
        window = [s for t, s in samples if a - 5 <= t <= b + 5]
        if not window:
            print("   (no samples in window)")
            continue
        folded = collections.Counter()
        for addrs in window:
            names = [sym(x) for x in addrs]
            # collapse to the most-informative frames: drop leaf runloop noise
            folded[";".join(reversed(names[:24]))] += 1
        for stack, w in folded.most_common(4):
            frames_list = stack.split(";")
            print(f"   {w:3d}× " + "\n        ".join(frames_list[-14:]))

    # ── 3. Whole-trace hot self frames (context) ──
    print("\n== whole-trace top leaf frames ==")
    leaf = collections.Counter()
    for _, addrs in samples:
        if addrs:
            leaf[sym(addrs[0])] += 1
    total = sum(leaf.values()) or 1
    for name, w in leaf.most_common(15):
        print(f"  {w:6d} ({100*w/total:4.1f}%)  {name[:100]}")

if __name__ == "__main__":
    main()
