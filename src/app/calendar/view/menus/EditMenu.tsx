"use client";

// Edit dropdown: undo/redo, cut/copy/paste, timezone + dim-past settings flyout.

import { useEffect, useRef, useState } from "react";
import { AUTO_TZ, COMMON_TZS, MAIN_TZS, systemTz, tzAbbrev, tzShortInfo } from "../../util/timezones";
import MenuBackdrop from "./MenuBackdrop";

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
  mainTz: string; // the stored main-tz setting (a concrete id, or AUTO_TZ)
  onMainTz: (tz: string) => void;
  dimPast: boolean;
  onToggleDimPast: () => void;
}

// macOS / Google-Docs-style "Edit" menu: a button that drops a command list — Undo/Redo,
// Cut/Copy/Paste, and an Alternative-Timezone flyout submenu (opens to the left since the
// menu hugs the right edge of the bar).
export default function EditMenu({ canUndo, onUndo, canRedo, onRedo, canCut, onCut, canCopy, onCopy, canPaste, onPaste, altTz, onAltTz, mainTz, onMainTz, dimPast, onToggleDimPast }: Props) {
  const [open, setOpen] = useState(false);
  const [tzOpen, setTzOpen] = useState(false);
  const [mainTzOpen, setMainTzOpen] = useState(false);
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
  // Zone acronym + UTC offset (e.g. "EST · UTC-5") shown per menu row; computed only when the
  // menu is open (client-side) so there's no SSR/hydration mismatch from new Date()/Intl.
  const tzNow = new Date();
  const sysTz = systemTz();
  const autoLabel = open ? `Auto: ${tzAbbrev(sysTz, tzNow)}` : "Auto"; // compact summary for the parent row
  const isAuto = mainTz === AUTO_TZ;
  const mainLabel = isAuto ? autoLabel : (MAIN_TZS.find((t) => t.id === mainTz)?.label ?? mainTz);

  return (
    <div className="cc-year-wrap" ref={wrapRef}>
      <button className="cc-action cc-action-sm cc-action-plain" onClick={() => setOpen((o) => !o)}>Edit<span className="cc-caret">▾</span></button>
      {open && (
        <>
        <MenuBackdrop onClose={() => setOpen(false)} />
        <div className="cc-menu" role="menu">
          <button className="cc-menu-item" disabled={!canUndo} onClick={run(onUndo, canUndo)}>Undo<span className="cc-menu-sc">⌘Z</span></button>
          <button className="cc-menu-item" disabled={!canRedo} onClick={run(onRedo, canRedo)}>Redo<span className="cc-menu-sc">⇧⌘Z</span></button>
          <div className="cc-menu-sep" />
          <button className="cc-menu-item" disabled={!canCut} onClick={run(onCut, canCut)}>Cut<span className="cc-menu-sc">⌘X</span></button>
          <button className="cc-menu-item" disabled={!canCopy} onClick={run(onCopy, canCopy)}>Copy<span className="cc-menu-sc">⌘C</span></button>
          <button className="cc-menu-item" disabled={!canPaste} onClick={run(onPaste, canPaste)}>Paste<span className="cc-menu-sc">⌘V</span></button>
          <div className="cc-menu-sep" />
          {/* view toggle: kept open on click so the checkmark visibly flips */}
          <button className="cc-menu-item" role="menuitemcheckbox" aria-checked={dimPast} onClick={onToggleDimPast}>Dim past events<span className="cc-menu-sc">{dimPast ? "✓" : ""}</span></button>
          <div className="cc-menu-sep" />
          <div className="cc-menu-sub" onMouseEnter={() => setMainTzOpen(true)} onMouseLeave={() => setMainTzOpen(false)}>
            <button className="cc-menu-item">Current Timezone<span className="cc-menu-sc">{mainLabel} ›</span></button>
            {mainTzOpen && (
              <div className="cc-submenu" role="menu">
                <button className={`cc-menu-item${isAuto ? " sel" : ""}`} onClick={() => { onMainTz(AUTO_TZ); setOpen(false); }}>Auto<span className="cc-menu-sc">{tzShortInfo(sysTz, tzNow)}</span></button>
                {MAIN_TZS.map((t) => (
                  <button key={t.id} className={`cc-menu-item${mainTz === t.id ? " sel" : ""}`} onClick={() => { onMainTz(t.id); setOpen(false); }}>{t.label}<span className="cc-menu-sc">{tzShortInfo(t.id, tzNow)}</span></button>
                ))}
              </div>
            )}
          </div>
          <div className="cc-menu-sub" onMouseEnter={() => setTzOpen(true)} onMouseLeave={() => setTzOpen(false)}>
            <button className="cc-menu-item">Alternative Timezone<span className="cc-menu-sc">{curTz ? curTz.label : "None"} ›</span></button>
            {tzOpen && (
              <div className="cc-submenu" role="menu">
                <button className={`cc-menu-item${!altTz ? " sel" : ""}`} onClick={() => { onAltTz(null); setOpen(false); }}>None</button>
                {COMMON_TZS.map((t) => (
                  <button key={t.id} className={`cc-menu-item${altTz === t.id ? " sel" : ""}`} onClick={() => { onAltTz(t.id); setOpen(false); }}>{t.label}<span className="cc-menu-sc">{tzShortInfo(t.id, tzNow)}</span></button>
                ))}
              </div>
            )}
          </div>
        </div>
        </>
      )}
    </div>
  );
}
