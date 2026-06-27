"use client";

import { Repeat, RepeatKind } from "@/lib/calendar/api";

const TABS: { kind: RepeatKind; label: string }[] = [
  { kind: "none", label: "None" },
  { kind: "daily", label: "Daily" },
  { kind: "weekly", label: "Weekly" },
  { kind: "weekdays", label: "Weekdays" },
];
const DOW = ["Su", "M", "Tu", "W", "Th", "F", "Sa"];

const withAnchor = (days: number[] | undefined, anchor: number) => {
  const set = new Set(days ?? []);
  set.add(anchor);
  return [...set].sort((a, b) => a - b);
};

// Recurrence editor: 4 equal tabs; the fields below depend on the chosen kind. The
// event's own weekday is pre-selected and locked in the "Weekdays" toggle group.
export default function RepeatEditor({ repeat, anchorDow, focusOcc, onChange }: { repeat: Repeat; anchorDow: number; focusOcc?: string | null; onChange: (r: Repeat) => void }) {
  const r = repeat ?? { kind: "none" as RepeatKind };
  const patch = (p: Partial<Repeat>) => onChange({ ...r, ...p });

  const setKind = (kind: RepeatKind) => {
    if (kind === "none") onChange({ kind: "none" });
    else if (kind === "daily") onChange({ kind: "daily", until: r.until ?? null });
    else if (kind === "weekly") onChange({ kind: "weekly", n: r.n ?? 1, until: r.until ?? null });
    else onChange({ kind: "weekdays", n: r.n ?? 1, days: withAnchor(r.days, anchorDow), until: r.until ?? null });
  };
  const toggleDay = (i: number) => {
    if (i === anchorDow) return; // the event's own day can't be unselected
    const set = new Set(r.days ?? [anchorDow]);
    if (set.has(i)) set.delete(i); else set.add(i);
    set.add(anchorDow);
    patch({ days: [...set].sort((a, b) => a - b) });
  };

  const hasN = r.kind === "weekly" || r.kind === "weekdays";
  return (
    <div className="cc-rep">
      <div className="cc-rep-tabs">
        {TABS.map((t) => (
          <button key={t.kind} className={`cc-rep-tab${r.kind === t.kind ? " sel" : ""}`} onClick={() => setKind(t.kind)}>{t.label}</button>
        ))}
      </div>

      {r.kind !== "none" && (
        <div className="cc-rep-fields">
          {hasN && (
            <label className="cc-rep-field">
              every
              <select value={r.n ?? 1} onChange={(e) => patch({ n: Number(e.target.value) })}>
                {[1, 2, 3, 4].map((n) => <option key={n} value={n}>{n}</option>)}
              </select>
              week{(r.n ?? 1) > 1 ? "s" : ""}
            </label>
          )}
          {r.kind === "weekdays" && (
            <div className="cc-rep-days">
              {DOW.map((d, i) => {
                const sel = (r.days ?? [anchorDow]).includes(i);
                const locked = i === anchorDow;
                return (
                  <button
                    key={i}
                    className={`cc-rep-day${sel ? " sel" : ""}${locked ? " locked" : ""}`}
                    onClick={() => toggleDay(i)}
                    title={locked ? "the event's own day" : ""}
                  >
                    {d}
                  </button>
                );
              })}
            </div>
          )}
          <label className="cc-rep-field">
            until
            <input type="date" value={r.until ?? ""} onChange={(e) => patch({ until: e.target.value || null })} />
            {focusOcc && <button type="button" className="cc-rep-until-here" onClick={() => patch({ until: focusOcc })}>this event</button>}
          </label>
        </div>
      )}
    </div>
  );
}
