"use client";

import { useEffect, useState } from "react";
import { Trash2 } from "lucide-react";
import { MENU_COLORS } from "./eventTypes";

interface Props {
  x: number;        // anchor: event top-center (viewport coords)
  y: number;
  color: string;
  onColor: (c: string) => void;
  onDelete: () => void;           // delete the whole event / series
  recurring?: boolean;            // event repeats → offer this / this-and-after / all
  onDeleteThis?: () => void;      // remove just this occurrence (adds an exception)
  onDeleteFuture?: () => void;    // end the series before this occurrence
  onClose: () => void;
}

// GridCal-style right-click callout: a row of color swatches + a trash button. For a
// recurring event the trash opens a this / this-and-after / all choice.
export default function EventContextMenu({ x, y, color, onColor, onDelete, recurring, onDeleteThis, onDeleteFuture, onClose }: Props) {
  const [confirming, setConfirming] = useState(false);
  useEffect(() => {
    const onDown = (e: MouseEvent) => { if (!(e.target as HTMLElement).closest(".cc-sticker")) onClose(); };
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("mousedown", onDown, true);
    window.addEventListener("keydown", onKey);
    return () => { window.removeEventListener("mousedown", onDown, true); window.removeEventListener("keydown", onKey); };
  }, [onClose]);

  return (
    <div
      className="cc-sticker"
      style={{ left: x, top: y }}
      onMouseDown={(e) => e.stopPropagation()}
      onClick={(e) => e.stopPropagation()}
    >
      {confirming ? (
        <div className="cc-sticker-del">
          {onDeleteThis && <button onClick={() => { onDeleteThis(); onClose(); }}>Just this one</button>}
          {onDeleteFuture && <button onClick={() => { onDeleteFuture(); onClose(); }}>This &amp; all after</button>}
          <button onClick={() => { onDelete(); onClose(); }}>All events</button>
        </div>
      ) : (
        <div className="cc-sticker-row">
          {MENU_COLORS.map((c) => (
            <button key={c} className={`cc-swatch cc-ev-${c}${color === c ? " sel" : ""}`} title={c} onClick={() => { onColor(c); onClose(); }} />
          ))}
          <span className="cc-sticker-div" />
          <button className="cc-sticker-trash" title="Delete" onClick={() => { if (recurring) setConfirming(true); else { onDelete(); onClose(); } }}>
            <Trash2 size={14} />
          </button>
        </div>
      )}
      <span className="cc-sticker-caret" />
    </div>
  );
}
