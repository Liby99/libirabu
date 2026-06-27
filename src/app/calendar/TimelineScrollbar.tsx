"use client";

import { useState } from "react";
import { LABEL_W } from "./constants";
import { clampHourH } from "./eventGeom";

interface Props {
  vp: { w: number; h: number };
  tlTop: number;
  viewH: number;
  hourH: number;
  scroll: number;
  setScroll: (s: number) => void;
  setHourH: (h: number) => void;
}

const MIN_THUMB = 26; // keep the thumb grabbable even when fully zoomed in

// Video-editor-style scrollbar living on the leftmost day's left border. The thumb
// (a vertical line with hollow end circles) shows the visible window: its position is
// the scroll, its length the visible fraction of the day. Dragging the body scrolls;
// dragging an end resizes the thumb → changes the per-hour height (longer = shorter
// hours), anchoring the opposite end.
export default function TimelineScrollbar({ vp, tlTop, viewH, hourH, scroll, setScroll, setHourH }: Props) {
  const [dragging, setDragging] = useState(false);
  const totalH = 24 * hourH;
  const thumbLen = Math.max(MIN_THUMB, (viewH / totalH) * viewH);
  const thumbTop = (scroll / totalH) * viewH;

  // Drag the thumb body → scroll.
  const onBodyDown = (e: React.MouseEvent) => {
    e.preventDefault();
    e.stopPropagation();
    setDragging(true);
    const y0 = e.clientY, scroll0 = scroll;
    const onMove = (me: MouseEvent) => setScroll(scroll0 + (me.clientY - y0) * totalH / viewH);
    const onUp = () => { setDragging(false); window.removeEventListener("mousemove", onMove); window.removeEventListener("mouseup", onUp); };
    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
  };

  // Drag an end → resize (change hour height), keeping the opposite end fixed.
  const onEndDown = (edge: "top" | "bottom") => (e: React.MouseEvent) => {
    e.preventDefault();
    e.stopPropagation();
    setDragging(true);
    const topY = thumbTop, botY = thumbTop + thumbLen; // px within the track at drag start
    const onMove = (me: MouseEvent) => {
      const y = Math.max(0, Math.min(viewH, me.clientY - tlTop));
      const len = Math.max(MIN_THUMB, Math.min(viewH, edge === "bottom" ? y - topY : botY - y));
      const newHourH = clampHourH(viewH * viewH / len / 24);
      const newTotal = 24 * newHourH;
      // keep the anchored end fixed → recompute scroll
      const newScroll = edge === "bottom"
        ? topY * newTotal / viewH
        : botY * newTotal / viewH - viewH;
      setHourH(newHourH);
      setScroll(Math.max(0, Math.min(newTotal - viewH, newScroll)));
    };
    const onUp = () => { setDragging(false); window.removeEventListener("mousemove", onMove); window.removeEventListener("mouseup", onUp); };
    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
  };

  return (
    <div className="cc-tl-scrollbar" style={{ left: LABEL_W, top: tlTop, height: viewH }}>
      <div className={`cc-tl-thumb${dragging ? " dragging" : ""}`} style={{ top: thumbTop, height: thumbLen }} onMouseDown={onBodyDown}>
        <span className="cc-tl-end cc-tl-end-top" onMouseDown={onEndDown("top")} />
        <span className="cc-tl-end cc-tl-end-bottom" onMouseDown={onEndDown("bottom")} />
      </div>
    </div>
  );
}
