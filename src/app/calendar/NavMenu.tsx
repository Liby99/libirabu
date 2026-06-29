"use client";

import { useEffect, useRef, useState } from "react";

interface Props {
  onGo: (level: number) => void; // 0 year · 1 month · 2 week · 3 day
}

// Levels deepest-first (Today on top). Each jumps to the CURRENT date at that zoom level,
// taking the shortest animated path (see goToNow in useCalendarInteractions).
const ITEMS: { level: number; label: string; hint: string }[] = [
  { level: 3, label: "Today", hint: "Day" },
  { level: 2, label: "This Week", hint: "Week" },
  { level: 1, label: "This Month", hint: "Month" },
  { level: 0, label: "This Year", hint: "Year" },
];

// "Nav" dropdown in the top bar (replaces the old single "Now" button).
export default function NavMenu({ onGo }: Props) {
  const [open, setOpen] = useState(false);
  const wrapRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => { if (wrapRef.current && !wrapRef.current.contains(e.target as Node)) setOpen(false); };
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    document.addEventListener("mousedown", onDown);
    window.addEventListener("keydown", onKey);
    return () => { document.removeEventListener("mousedown", onDown); window.removeEventListener("keydown", onKey); };
  }, [open]);

  return (
    <div className="cc-year-wrap" ref={wrapRef}>
      <button className="cc-action cc-action-sm cc-action-plain" onClick={() => setOpen((o) => !o)} title="Jump to today / this week / month / year">Nav<span className="cc-caret">▾</span></button>
      {open && (
        <div className="cc-menu cc-menu-left" role="menu">
          {ITEMS.map((it) => (
            <button key={it.level} className="cc-menu-item" onClick={() => { onGo(it.level); setOpen(false); }}>{it.label}<span className="cc-menu-sc">{it.hint}</span></button>
          ))}
        </div>
      )}
    </div>
  );
}
