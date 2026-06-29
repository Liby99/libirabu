"use client";

// Drag handle on the daily timeline's right edge (the timeline ↔ dashboard boundary). A wide,
// invisible hit-zone fades in a thin vertical bar when the cursor approaches (CSS :hover), and
// dragging it resizes the day timeline. The actual resize math lives in CalendarCanvas (it owns
// wrapRef/vp/setDailyFrac); this component is purely the affordance.
interface Props {
  x: number;      // boundary x (the timeline's right edge)
  top: number;    // top of the grabbable strip (band top)
  bottom: number; // bottom of the strip
  onResizeStart: (e: React.MouseEvent) => void;
}

const HIT_W = 24; // grab/approach zone width (centered on the boundary)

export default function DailyResizeHandle({ x, top, bottom, onResizeStart }: Props) {
  return (
    <div
      className="cc-daily-resize"
      style={{ left: x - HIT_W / 2, top, width: HIT_W, height: Math.max(0, bottom - top) }}
      onMouseDown={onResizeStart}
    >
      <div className="cc-daily-resize-bar" />
    </div>
  );
}
