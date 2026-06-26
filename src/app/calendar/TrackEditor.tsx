import { useMemo } from "react";
import { Vp } from "./types";
import { LABEL_W, MNAME_W, RIGHT_PAD, TRACK_H } from "./constants";
import { bandYFor } from "./frames";

interface Props {
  trackNames: string[][];
  editTrack: (m: number, i: number, val: string) => void;
  vp: Vp;
  z: number;
  focus: number;
  week: number;
  scrollY: number;
}

// Per-month track-name editor. The 4 inputs of each month are memoized (so they
// never re-reconcile during a zoom); each month's container is translated to its
// live band position every frame, so the inputs travel with the band.
export default function TrackEditor({ trackNames, editTrack, vp, z, focus, week, scrollY }: Props) {
  const monthInputs = useMemo(() => {
    const left = MNAME_W;
    const width = LABEL_W - MNAME_W - RIGHT_PAD;
    return Array.from({ length: 12 }, (_, m) =>
      [0, 1, 2, 3].map((i) => (
        <div
          key={i}
          className={`cc-track-cell${i === 0 ? " cc-tc-first" : ""}${i === 3 ? " cc-tc-last" : ""}`}
          style={{ top: i * TRACK_H, left, width, height: TRACK_H }}
        >
          <input
            className="cc-track-input"
            value={trackNames[m]?.[i] ?? ""}
            placeholder="track…"
            onChange={(e) => editTrack(m, i, e.target.value)}
            onClick={(e) => e.stopPropagation()}
            onMouseDown={(e) => e.stopPropagation()}
          />
        </div>
      )),
    );
  }, [trackNames, editTrack]);

  if (vp.w === 0) return null;
  return (
    <div className="cc-track-edit">
      {Array.from({ length: 12 }, (_, m) => m).map((m) => {
        const by = bandYFor(m, z, focus, week, vp, scrollY);
        if (by + TRACK_H * 4 < -4 || by > vp.h + 4) return null;
        return (
          <div key={m} className="cc-track-month" style={{ transform: `translateY(${by}px)` }}>
            {monthInputs[m]}
          </div>
        );
      })}
    </div>
  );
}
