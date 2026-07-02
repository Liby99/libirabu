"use client";

// Right-click menu on an event: color swatches + a trash button.

import { useEffect } from "react";
import { Trash2 } from "lucide-react";
import { MENU_COLORS } from "../../model/types/eventTypes";

interface Props {
  x: number;        // anchor: event top-center (viewport coords)
  y: number;
  color: string;
  onColor: (c: string) => void;
  onDelete: () => void; // routes through the host's requestDelete: imported → hide, recurring →
                        // the shared scope dialog, otherwise a plain delete. The menu no longer
                        // asks for scope itself — all three delete paths share one dialog.
  imported?: boolean;   // only affects the trash tooltip (the hide vs delete wording)
  onClose: () => void;
}

// GridCal-style right-click callout: a row of color swatches + a trash button. The trash
// defers to the host (onDelete) so every entry point — this menu, the Delete key, and the
// drawer — opens the same confirm dialog for recurring events.
export default function EventContextMenu({ x, y, color, onColor, onDelete, imported, onClose }: Props) {
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
      <div className="cc-sticker-row">
        {MENU_COLORS.map((c) => (
          <button key={c} className={`cc-swatch cc-ev-${c}${color === c ? " sel" : ""}`} title={c} onClick={() => { onColor(c); onClose(); }} />
        ))}
        <span className="cc-sticker-div" />
        <button className="cc-sticker-trash" title={imported ? "Hide (synced event)" : "Delete"} onClick={() => { onDelete(); onClose(); }}>
          <Trash2 size={14} />
        </button>
      </div>
      <span className="cc-sticker-caret" />
    </div>
  );
}
