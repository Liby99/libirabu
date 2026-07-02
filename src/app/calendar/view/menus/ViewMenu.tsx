"use client";

// View dropdown: jump-to-now actions + tag-filter flyout.

import { useEffect, useRef, useState } from "react";
import { TagFilterPanel, TagRow } from "./TagFilterMenu";
import MenuBackdrop from "./MenuBackdrop";

interface Props {
  onGo: (level: number) => void; // 0 year · 1 month · 2 week · 3 day
  // Tag filter (lives in a "Tag Filter" flyout):
  tags: TagRow[];
  untaggedCount: number;
  hidden: Set<string>;
  onToggle: (key: string) => void;
  onShowAll: () => void;
  onHideAll: () => void;
  // "Show hidden events" — reveal soft-deleted (dismissed) imported events, dimmed.
  showHidden: boolean;
  onToggleShowHidden: () => void;
  // "Dim past events" — fade events whose time has already elapsed.
  dimPast: boolean;
  onToggleDimPast: () => void;
}

// Levels deepest-first (Today on top). Each jumps to the CURRENT date at that zoom level,
// taking the shortest animated path (see goToNow in useCalendarInteractions).
const ITEMS: { level: number; label: string; hint: string }[] = [
  { level: 3, label: "Today", hint: "Day" },
  { level: 2, label: "This Week", hint: "Week" },
  { level: 1, label: "This Month", hint: "Month" },
  { level: 0, label: "This Year", hint: "Year" },
];

// "View" dropdown in the top bar: jump-to-now levels + a Tag Filter flyout.
export default function ViewMenu({ onGo, tags, untaggedCount, hidden, onToggle, onShowAll, onHideAll, showHidden, onToggleShowHidden, dimPast, onToggleDimPast }: Props) {
  const [open, setOpen] = useState(false);
  const [tagOpen, setTagOpen] = useState(false);
  const wrapRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const close = () => { setOpen(false); setTagOpen(false); };
    const onDown = (e: MouseEvent) => { if (wrapRef.current && !wrapRef.current.contains(e.target as Node)) close(); };
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") close(); };
    document.addEventListener("mousedown", onDown);
    window.addEventListener("keydown", onKey);
    return () => { document.removeEventListener("mousedown", onDown); window.removeEventListener("keydown", onKey); };
  }, [open]);

  const filtering = hidden.size > 0; // any tag filtering in effect → mark the button + the flyout row

  return (
    <div className="cc-year-wrap" ref={wrapRef}>
      <button className={`cc-action cc-action-sm cc-action-plain${filtering ? " cc-action-accent" : ""}`} onClick={() => setOpen((o) => !o)} title="Jump to today / week / month / year · filter by tag">
        View<span className="cc-caret">▾</span>
      </button>
      {open && (
        <>
        <MenuBackdrop onClose={() => { setOpen(false); setTagOpen(false); }} />
        <div className="cc-menu" role="menu">
          {ITEMS.map((it) => (
            <button key={it.level} className="cc-menu-item" onClick={() => { onGo(it.level); setOpen(false); }}>{it.label}<span className="cc-menu-sc">{it.hint}</span></button>
          ))}
          <div className="cc-menu-sep" />
          {/* view toggles: kept open on click so the checkmark visibly flips */}
          <button className="cc-menu-item" role="menuitemcheckbox" aria-checked={dimPast} onClick={onToggleDimPast}>Dim past events<span className="cc-menu-sc">{dimPast ? "✓" : ""}</span></button>
          <button className="cc-menu-item" role="menuitemcheckbox" aria-checked={showHidden} onClick={onToggleShowHidden}>Show hidden events<span className="cc-menu-sc">{showHidden ? "✓" : ""}</span></button>
          <div className="cc-menu-sep" />
          <div className="cc-menu-sub" onMouseEnter={() => setTagOpen(true)} onMouseLeave={() => setTagOpen(false)}>
            <button className="cc-menu-item">Tag Filter<span className="cc-menu-sc">{filtering ? "Filtered ›" : "›"}</span></button>
            {tagOpen && (
              <div className="cc-submenu cc-tag-submenu" role="menu">
                <TagFilterPanel tags={tags} untaggedCount={untaggedCount} hidden={hidden} onToggle={onToggle} onShowAll={onShowAll} onHideAll={onHideAll} />
              </div>
            )}
          </div>
        </div>
        </>
      )}
    </div>
  );
}
