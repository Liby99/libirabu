"use client";

import { useEffect, useRef, useState } from "react";
import { COMMON_TZS } from "./timezones";

interface Props {
  canUndo: boolean;
  onUndo: () => void;
  canRedo: boolean;
  onRedo: () => void;
  canCut: boolean;
  onCut: () => void;
  canCopy: boolean;
  onCopy: () => void;
  canPaste: boolean;
  onPaste: () => void;
  altTz: string | null;
  onAltTz: (tz: string | null) => void;
}

// macOS / Google-Docs-style "Edit" menu: a button that drops a command list — Undo/Redo,
// Cut/Copy/Paste, and an Alternative-Timezone flyout submenu (opens to the left since the
// menu hugs the right edge of the bar).
export default function EditMenu({ canUndo, onUndo, canRedo, onRedo, canCut, onCut, canCopy, onCopy, canPaste, onPaste, altTz, onAltTz }: Props) {
  const [open, setOpen] = useState(false);
  const [tzOpen, setTzOpen] = useState(false);
  const wrapRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => { if (wrapRef.current && !wrapRef.current.contains(e.target as Node)) setOpen(false); };
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    document.addEventListener("mousedown", onDown);
    window.addEventListener("keydown", onKey);
    return () => { document.removeEventListener("mousedown", onDown); window.removeEventListener("keydown", onKey); };
  }, [open]);

  // Run an action and close the menu (no-op when the item is disabled).
  const run = (fn: () => void, enabled: boolean) => () => { if (enabled) { fn(); setOpen(false); } };
  const curTz = COMMON_TZS.find((t) => t.id === altTz);

  return (
    <div className="cc-year-wrap" ref={wrapRef}>
      <button className="cc-action cc-action-sm cc-action-plain" onClick={() => setOpen((o) => !o)}>Edit<span className="cc-caret">▾</span></button>
      {open && (
        <div className="cc-menu" role="menu">
          <button className="cc-menu-item" disabled={!canUndo} onClick={run(onUndo, canUndo)}>Undo<span className="cc-menu-sc">⌘Z</span></button>
          <button className="cc-menu-item" disabled={!canRedo} onClick={run(onRedo, canRedo)}>Redo<span className="cc-menu-sc">⇧⌘Z</span></button>
          <div className="cc-menu-sep" />
          <button className="cc-menu-item" disabled={!canCut} onClick={run(onCut, canCut)}>Cut<span className="cc-menu-sc">⌘X</span></button>
          <button className="cc-menu-item" disabled={!canCopy} onClick={run(onCopy, canCopy)}>Copy<span className="cc-menu-sc">⌘C</span></button>
          <button className="cc-menu-item" disabled={!canPaste} onClick={run(onPaste, canPaste)}>Paste<span className="cc-menu-sc">⌘V</span></button>
          <div className="cc-menu-sep" />
          <div className="cc-menu-sub" onMouseEnter={() => setTzOpen(true)} onMouseLeave={() => setTzOpen(false)}>
            <button className="cc-menu-item">Alternative Timezone<span className="cc-menu-sc">{curTz ? curTz.label : "None"} ›</span></button>
            {tzOpen && (
              <div className="cc-submenu" role="menu">
                <button className={`cc-menu-item${!altTz ? " sel" : ""}`} onClick={() => { onAltTz(null); setOpen(false); }}>None</button>
                {COMMON_TZS.map((t) => (
                  <button key={t.id} className={`cc-menu-item${altTz === t.id ? " sel" : ""}`} onClick={() => { onAltTz(t.id); setOpen(false); }}>{t.label}</button>
                ))}
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
