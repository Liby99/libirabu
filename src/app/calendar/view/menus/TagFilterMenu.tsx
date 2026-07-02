"use client";

// Tag-filter panel (embedded in ViewMenu): show/hide tags with search.

import { useEffect, useMemo, useRef, useState } from "react";

// Sentinel "tag" for events that carry no tags — toggled like any other in the filter.
export const UNTAGGED = " untagged";

export interface TagRow {
  key: string;   // lowercased tag (or UNTAGGED); the identity used by the filter
  label: string; // display casing
  count: number; // how many events carry it
}

interface PanelProps {
  tags: TagRow[];        // real tags, pre-sorted by count desc (NOT including untagged)
  untaggedCount: number;
  hidden: Set<string>;   // toggled-OFF keys; empty = everything shown
  onToggle: (key: string) => void;
  onShowAll: () => void;
  onHideAll: () => void;
  autoFocus?: boolean;   // focus the search on mount (only when opened by an explicit click)
}

const TOP_N = 5; // default (no search) shows this many of the most-frequent tags + untagged

// The tag-filter body: Show All / Hide All, a case-insensitive search, and a toggle list.
// A tag is ON (its events shown) when it is NOT in `hidden`. Semantics are "If Any": an event
// shows if it has any toggled-on tag (see CalendarCanvas). Embedded in the View menu's
// "Tag Filter" flyout.
export function TagFilterPanel({ tags, untaggedCount, hidden, onToggle, onShowAll, onHideAll, autoFocus = false }: PanelProps) {
  const [query, setQuery] = useState("");
  const searchRef = useRef<HTMLInputElement>(null);
  useEffect(() => { if (autoFocus) searchRef.current?.focus(); }, [autoFocus]);

  const untaggedRow: TagRow = { key: UNTAGGED, label: "untagged", count: untaggedCount };

  // No search → the most-frequent few + untagged. Searching → every matching tag (and
  // untagged when it matches), case-insensitively.
  const rows = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return [...tags.slice(0, TOP_N), untaggedRow];
    return [...tags, untaggedRow].filter((r) => r.label.toLowerCase().includes(q));
    // untaggedRow rebuilt each render; intentionally excluded from deps
  }, [query, tags, untaggedCount]); // eslint-disable-line react-hooks/exhaustive-deps

  return (
    <>
      <input
        ref={searchRef}
        className="cc-tag-search"
        placeholder="Search tags…"
        value={query}
        onChange={(e) => setQuery(e.target.value)}
      />
      <div className="cc-tag-list">
        {rows.map((r) => {
          const on = !hidden.has(r.key);
          return (
            <button key={r.key} className={`cc-tag-row${on ? " on" : ""}`} onClick={() => onToggle(r.key)} role="menuitemcheckbox" aria-checked={on}>
              <span className="cc-tag-check">{on ? "✓" : ""}</span>
              <span className={`cc-tag-name${r.key === UNTAGGED ? " cc-tag-untagged" : ""}`}>{r.label}</span>
              <span className="cc-tag-count">{r.count}</span>
            </button>
          );
        })}
        {rows.length === 0 && <div className="cc-tag-empty">No matching tags</div>}
      </div>
      <div className="cc-tag-sep" />
      <div className="cc-tag-allrow">
        <button className="cc-tag-all" onClick={onShowAll}>Show All</button>
        <button className="cc-tag-all" onClick={onHideAll}>Show None</button>
      </div>
    </>
  );
}
