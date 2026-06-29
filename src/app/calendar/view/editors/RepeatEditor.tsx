"use client";

// Recurrence config form: none / daily / weekly / weekdays / yearly, with an optional until date.

import { Repeat, RepeatKind } from "@/lib/calendar/api";

const TABS: { kind: RepeatKind; label: string }[] = [
  { kind: "none", label: "None" },
  { kind: "daily", label: "Daily" },
  { kind: "weekly", label: "Weekly" },
  { kind: "weekdays", label: "Weekdays" },
  { kind: "yearly", label: "Yearly" },
];
const DOW = ["Su", "M", "Tu", "W", "Th", "F", "Sa"];

const withAnchor = (days: number[] | undefined, anchor: number) => {
  const set = new Set(days ?? []);
  set.add(anchor);
  return [...set].sort((a, b) => a - b);
};

// Recurrence editor: tabs pick the kind; the fields below depend on it. The event's own
// weekday is pre-selected and locked in "Weekdays". Every recurring kind shares one "until"
// control — a None | Date toggle, where Date reveals a date picker + a "this event" shortcut
// (yearly → set Date to a future year to stop the series).
export default function RepeatEditor({ repeat, anchorDow, anchorDate, focusOcc, onChange }: { repeat: Repeat; anchorDow: number; anchorDate: string; focusOcc?: string | null; onChange: (r: Repeat) => void }) {
  const r = repeat ?? { kind: "none" as RepeatKind };
  const patch = (p: Partial<Repeat>) => onChange({ ...r, ...p });

  const setKind = (kind: RepeatKind) => {
    if (kind === "none") onChange({ kind: "none" });
    else if (kind === "daily") onChange({ kind: "daily", until: r.until ?? null });
    else if (kind === "weekly") onChange({ kind: "weekly", n: r.n ?? 1, until: r.until ?? null });
    else if (kind === "yearly") onChange({ kind: "yearly", until: r.until ?? null });
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
  const untilTarget = focusOcc ?? anchorDate; // "this event" date / default when switching to Date
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
            <div className="cc-seg cc-seg-fill cc-rep-days" role="group" aria-label="Weekdays">
              {DOW.map((d, i) => {
                const sel = (r.days ?? [anchorDow]).includes(i);
                const locked = i === anchorDow;
                return (
                  <button
                    key={i}
                    type="button"
                    className={`cc-seg-btn${sel ? " sel" : ""}${locked ? " locked" : ""}`}
                    onClick={() => toggleDay(i)}
                    title={locked ? "the event's own day" : ""}
                  >
                    {d}
                  </button>
                );
              })}
            </div>
          )}
          {/* until: None | Date toggle; Date reveals the picker + a "this event" shortcut */}
          <div className="cc-rep-field cc-rep-until">
            until
            <div className="cc-rep-toggle" role="group">
              <button type="button" className={`cc-rep-toggle-btn${r.until == null ? " sel" : ""}`} onClick={() => patch({ until: null })}>None</button>
              <button type="button" className={`cc-rep-toggle-btn${r.until != null ? " sel" : ""}`} onClick={() => { if (r.until == null) patch({ until: untilTarget }); }}>Date</button>
            </div>
            {r.until != null && (
              <>
                <input type="date" value={r.until} onChange={(e) => patch({ until: e.target.value || null })} />
                <button type="button" className="cc-rep-until-here" onClick={() => patch({ until: untilTarget })}>this event</button>
              </>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
