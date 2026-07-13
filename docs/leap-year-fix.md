# Fix: February should have 29 days in leap years (web app)

## Problem

When the user switches the calendar to a leap year (e.g. **2024**, 2020, 2028),
February still renders **28** day columns. Only the weekday alignment changes
between years, not February's length.

## Root cause

`daysInMonth` is a fixed 12-entry table with February hardcoded to 28 and no
leap-year handling.

- File: `src/app/calendar/model/api/mock.ts`
  ```ts
  export function daysInMonth(month: number): number {
    return [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month];
  }
  ```

Every grid/geometry consumer imports this (`geometry/hittest.ts`,
`geometry/bandGeom.ts`, `geometry/eventGeom.ts`, `util/dates.ts` →
`weeksInMonth`/`resolveDate`, etc.), so the wrong February length propagates
everywhere: day columns, week counts, hit-testing, event/deadline placement,
and the breadcrumb.

## The fix (small — only `mock.ts` changes)

The module already exports a **mutable live binding** `YEAR` (updated by
`setCalendarYear`), and `daysInMonth` lives in the *same module*. So
`daysInMonth` can just consult `YEAR` for February — **no signature changes and
no caller edits are required**, because every importer reads `daysInMonth`
through the ES live binding and `YEAR` is already current at render time.

In `src/app/calendar/model/api/mock.ts`:

```ts
export function isLeapYear(y: number): boolean {
  return (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;
}

export function daysInMonth(month: number): number {
  if (month === 1 && isLeapYear(YEAR)) return 29;
  return [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month];
}
```

Also update the stale comment on `YEAR` (lines ~4–7) that claims "daysInMonth is
a fixed table (no leap-year handling), so only weekday alignment changes between
years" — that is no longer true.

### Why reading module `YEAR` is safe here

`daysInMonth` is only ever called for the focused month and its immediate
neighbors (`focus`, `focus ± 1`). February is month index 1; its neighbors
(Jan/Mar) are in the same `YEAR`, and no adjacent-month spillover crosses a year
boundary into a *different* year's February. So the single module-level `YEAR`
is the correct year for every call — same assumption the native port makes by
threading one `year` value.

## Verification

1. Load the calendar, open the year selector, choose **2024**.
2. Year view: February's band should show **29** day columns; its last week/row
   should extend one day further than a non-leap year.
3. Zoom into February 2024 (month/week/day) and confirm day **29** exists and is
   selectable, and that weekday labels line up (Feb 29 2024 = Thursday).
4. Switch back to **2026** (non-leap) and confirm February is **28** again.

## Native parity (already done)

The native SwiftUI port implemented the same behavior in
`native/CalendarKit` (commit "Leap-year-aware day counts (Feb 29 on leap
years)"). Note the native version had **no module-level year** (geometry is a
pure function of an explicit `SceneInput` value), so it had to thread `year`
through `daysInMonth`/`resolveDate`/`relDomOf`/`eventRect` and all ~30 callers.
The web does **not** need that because of the live `YEAR` binding — keep the web
change minimal (just `mock.ts`).
