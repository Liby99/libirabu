# Keyboard Controlling the Full Calendar App

We would like the full calendar application to be fully interactable. At any point, we may hold Ctrl+H to show a overlaid pane on shortcut guide (when we release ctrl+h, the guide disappears/fades out). The guide will be a grid of keys that we can press each with what they are used for. All the states (at a high level) and their possible action should be recorded into a table and we use this table to display what are the keys that we can press.

In general there are those states
- year view
    - band event selection mode
        - drawer opened mode
            - configuration opened mode
            - markdown editing mode
            - previewing mode
        - title editing mode
    - month cursor mode
    - track name focused mode
        - traack name editing mode
- monthly view
    - band event selection mode // ...
    - day cursor mode
- weekly view
    - band event selection mode // ...
    - hour cursor mode
    - deadline event selection mode
        - drawer opened mode // ...
    - timed event selection mode
        - drawer opened mode // ...
        - title editing mode
- daily view
    - band event selection mode // ...
    - hour cursor mode
    - deadline event selection mode // ...
    - timed event selection mode
    - todo viewing mode
    - daily note mode
        - editing mode // ...
        - previewing mode // ...

Below we will detail the keyboard interactions

## Event interaction

When an event is selected and we would like to modify its title
- Enter: focus on the title of the event in-place, then user may directly edit the title of the event in-place, equivalent to clicking on the event once, and then click on it twice to edit the title (different from double click)
    - Enter again: done editing
- Space: open the drawer
    - Space again: close the drawer
    - Escape: close the drawer
    - Enter: focus on the title of the event in the drawer, may start edit the title of the event
        - Enter again: done editing
        - Tab: cycle through the directly editable elements (date/time fields, color, etc.)
            - date/time fields: directly follow apple's native edit
            - color picker: using left/right key may select/preview the color, space/enter to select
            - configuration: when focused on this, highlight the border
                - space/enter: open/close configuration
                - tab: cycle through the interactables in configuration (tag, repeat, etc.); when it gets back, we will re-focus on the entire configuration box allowing us to use space/enter to close it
                - escape: collapse configuration tab
            - the markdown editor/preview
                - if we are in markdown editor
                    - shortcut: if there is no any content in markdown editor, and we hit "tab", we cycle to next element
                    - we can type normally
                    - cmd+s: save & go to preview
                - if we are in preview
                    - enter: go into markdown mode
            - the delete button:
                - enter: prompt deletion of the event
- Escape: deselect the event

When an event is selected and we want to move it
- State: daily-view/band-event-selection-mode
    - cmd+up, cmd+down: move the event across 4 tracks; when it is at bottom track, moving down will do nothing; vice versa
- State: daily-view/deadline-event-selection-mode
    - cmd+up, cmd+down: move the event up or down by 15 min. When it is at the boundary and cannot be moved, we do nothing. Say a deadline
- State: daily-view/timed-event-selection-mode
    - cmd+up, cmd+down: move the event up or down by 15 min. Do not move the event out of the daily boundary
- State: weekly-view/band-event-selection-mode
    - cmd+up, cmd+down, cmd+left, cmd+right: move the event across 4 tracks and days, each by one; on left/right: cannot move over month boundary, but can move over weekly boundary, and the weekly view focus area will shift along with the move (+1 day, -1 day)
- State: weekly-view/deadline-event-selection-mode
    - cmd+up, cmd+down: same as daily view
    - cmd+left, cmd+right: move the event by a day; can move across week boundary, again, weekly view focus area will shift
- State: weekly-view/timed-event-selection-mode
    - cmd+up, cmd+down: same
    - cmd+left, cmd+right: same as deadline event
- State: monthly-view/band-event-selection-mode
    - same as weekly-view/band-event-selection-mode
- State: yearly-view/band-event-selection-mode
    - same as weekly-view/band-event-selection-mode (do not allow moving over monthly boundaries, nor up/down moving across monthly-tracks)

Resizing event
- for band event: shift+right/left will extend/shrink the event's length by 1 day. Upper capped at monthly boundary, lower capped at 1. We assume the start date of the band event does not change during this resize
- for timed events: shift+up/down will extend/shrink the event's duration by 15min. Upper capped at daily boundary, ower capped at 1-15min. We assume the start time of the timed event to not change

## Navigation

At a high level, there are a few navigation domains
- block cursor
- band cursor
- timed + deadline + band events cursor

These navigation domains exist across 4 views (yearly, monthly, weekly, and daily)
- yearly
    - block curosr is focusing on each month, up/down arrow navigates through months
    - band cursor is a cursor on each grid cell, up/right/down/left can move the cursor (up/down can move across monthly and even quarterly boundary)
    - event cursor: always has a selection on a band event. Up/right/down/left will use some algorithm to go to nearby events in that direction
- monthly
    - block cursor is focusing on each day, left/right navigates between days
    - band cursor is a cursor on each grid cell, up/right/down/left can move the cursor
    - event cursor: always has a selection on a band event. Similar to
- weekly
    - block cursor is focusing on each hour, up/down/left/right navigates through hours across days. Left/right can go across weekly boundary and move the weekly focal area
    - band cursor is a cursor on each grid cell, up/right/down/left can move the cursor. Left/right can move cursor across weekly boundary and shift the focus area
    - events cursor inherits everything from yearly/monthly views, but we may use down arrow to go to timed events and deadline events. Up arrow can go from timed events / deadline to band events
- daily
    - block cursor is focusing on each hour, up/down goes over hours in each each, and left/right will swipe the daily view into previou or next day.
    - band cursor inherits from before
    - event cursor will allow only up/down to go between events within the current day. Left and right keys will only be applicable when there are overlapping events in a single day and we are shifting focus between the left hand side event and right hand side events.

In general, these three cursors cycle between each other through tab key.
- Though for some views there are more things that we may edit
    - monthly view, we allow further cycling through the monthly track names (4 extra tab steps)
    - daily view, we allow cycling through daily dashboard todo view and note view (2 extra tab steps)
- Exactly how to cycle between them (a focus with band curosr -> a focus with event cursor) is case dependent. There are all the connections (3 starting domain x 3 ending domain x 4 views = 36), because both tab and shift+tab can cycle. The principle is that each cycle forward/backward should be invertible. So we need to carefully design the algorithm and criteria (or at least keep a history system)
    - this needs careful design

For block cursor navigation domain, typically hitting space key will go into the lower level view
- when we focus on month in yearly view, hitting space will lead us into monthly view, and the block cursor placed on current day (if the month is current month) or 1st day of the month if not the current month
- when we are in monthly view, we focus on a single day, hitting space will lead us into the weekly view with that day's hour being selected as the block cursor position. The hour is selected based on current time, if that week contains "today", if not, the cursor is on 12pm.
- when we are in weekly view, and the block cursor is on an hour, hitting space will go to that daily view, with the same hour as the cursor position
Conversely, hitting ESC will go from the lower level view to a higher level view.
Another key should do the same job: cmd+=, cmd+- for "zoom in or out"

---

# Navigation — Resolved Design (v1)

This section turns the sketch above into a concrete, implementable model. Where it conflicts
with the sketch, **this section wins.**

## Cursors & default

Exactly one **navigation cursor** is active per view:

- **Block cursor** *(default / home)* — a time cell: a **month** (year view), a **day** (month view),
  a **day + hour** (week/day view).
- **Band cursor** — a 2-D cell over the band-lane grid: `(month, track 0–3, day)`.
- **Event cursor** — a selected event (band / timed / deadline). This *is* `selectedId` and the
  existing `.timedSelected / .bandSelected / .deadlineSelected` states.

When a view has no selection, the active cursor is the **block cursor**.

## Modifier layers on the arrow keys (event cursor)

While the **event cursor** is active, the arrows split by modifier:

| Keys | Meaning |
|---|---|
| plain arrows | **navigate** between events (move the cursor to a nearby event) |
| ⌘ + arrows | **move** the event (lane / ±15 min / ±1 day — see "when an event is selected and we want to move it") |
| ⇧ + arrows | **resize** the event (see "Resizing event") |

- **Band resize** — ⇧←/⇧→ shrink/extend length by **1 day**; upper cap = month boundary
  (`endDay ≤ daysInMonth`), lower cap = **1 day** (`endDay ≥ startDay`); **startDay is fixed**.
- **Timed resize** — ⇧↓/⇧↑ extend/shrink duration by **15 min**; upper cap = day boundary
  (`endHour ≤ 24`), lower cap = **15 min** (`endHour ≥ startHour + 0.25`); **startHour is fixed**.

## Per-view arrow semantics (navigate)

- **Block cursor**
  - *year* — ↑/↓ = month ∓1; ←/→ = no-op.
  - *month* — ←/→ = day ∓1 (wraps across weeks); **↑/↓ = no-op**.
  - *week* — ↑/↓ = hour ∓1; ←/→ = day ∓1 (may cross the week boundary → the focus window shifts a day).
  - *day* — ↑/↓ = hour ∓1; ←/→ = swipe to prev/next day.
- **Band cursor** *(all views)* — ↑/↓/←/→ move the `(month, track, day)` cell. ↑/↓ walk the 4 tracks
  and then across month (and quarter) boundaries; ←/→ walk days and (week/month/year) may cross the
  week boundary, shifting the focus window.
- **Event cursor** — nearest-event-in-direction (see algorithm). In week/day, **↓ descends** from a
  band into timed/deadline events and **↑ climbs** back; in day view, ←/→ only switch between
  side-by-side overlapping events.

## Zoom / cursor-mode: Space, Esc, ⌘=, ⌘−, Enter

- **Space / ⌘=** = zoom **in** one level; **Esc / ⌘−** = zoom **out** one level.
- Zooming **stays in the current cursor mode** — Esc never changes the cursor. **Tab is the only way
  to change cursor mode.**
- Block-cursor **Space placement** (as sketched): year→month lands the block on today (if the month is
  the current month) else the 1st; month→week lands on that day at the current hour (if the week
  contains today) else 12pm; week→day keeps the same hour.
- **(Future) Enter = "select"** — from the **band cursor** (any view) or the **block cursor** (week/day),
  Enter enters **event-cursor** mode on the relevant event.

## Creation — ⌘N

- **Band cursor** → new **1-day band** at `(month, track, day)`; extend afterward with ⇧→.
- **Block cursor, week/day** (hour cell) → new **1-hour timed event** at `(day, hour)`.
- **Block cursor, month/year** → **no-op**.

## Tab cycling

Forward order: **Block → Band → Event → [extra stops] → Block** (⇧Tab reverses).
**Extra stops**, inserted after Event and before wrapping to Block:
- *month view* → the **4 track-name edits**.
- *day view* → the **dashboard TODO** and **daily NOTE** (2 stops).

### Carry-over rules

On each Tab/⇧Tab we *carry over* the current position into the next domain, always anchoring on the
**earliest / leftmost / topmost** representative so it is deterministic and round-trips:

| Transition | Rule |
|---|---|
| **Block → Band** | same day, **track 0** (top lane) |
| **Band → Event** | the band covering the cell → select it; else the **nearest** band to the cell |
| **Event → Block** | the event's earliest anchor — band → `(month, startDay)`; timed/deadline → `(day, startHour)`; year → the event's month |
| **Event → Band** *(⇧Tab)* | band → its **start cell** `(month, track, startDay)` *(leftmost)*; timed/deadline → `(month, track 0, day)` |
| **Band → Block** *(⇧Tab)* | drop the track → `(month, day)`; week/day hour = 12pm |
| **Block → Event** *(⇧Tab)* | the **nearest** event to the block location |

### One-step transition memory

The carry-over above is *contextual* (it follows where you are) but can be lossy (a 5-day band → its
start cell). To keep Tab a perfect round-trip, remember only the **immediately-previous transition**
`(fromDomain, fromPosition, toDomain)`. If the next keystroke is that transition's exact inverse
(`toDomain → fromDomain`), **restore `fromPosition`** instead of re-deriving via carry-over. Any other
keystroke clears the memory and uses carry-over. (One step is enough; no full history stack.)

## Directional navigation (event cursor) — the "focus engine"

Moving the event cursor with the 4 arrows among events scattered at arbitrary positions/sizes is the
classic **directional / spatial focus** problem (Android `FocusFinder`, tvOS `UIFocusEngine`, W3C CSS
Spatial Navigation). We adopt a FocusFinder-style engine with these **resolved** choices:

- **Logical coordinates, not pixels.** Score in each view's natural grid, so nav is stable across
  scroll and can scroll an off-screen target into view:
  - *timed / deadline* → `(day column, start-hour row)`
  - *band* → `(month, startDay, track)` (with day-span → an x-extent, so a wide band is reachable)
- **Which views use the engine.** Year, month, week are **2-D → use the engine**. **Day view does NOT**
  — its motion is 1-D (↑/↓ = previous/next event by time) with ←/→ reserved for switching between
  *side-by-side overlapping* events; handle it directly, not via the scorer.
- **Scoring (per pressed direction `d`).** Using *edge* distances between the source and candidate
  rects (centers misbehave across sizes): `majorAxis` = distance along `d`, `minorAxis` =
  perpendicular. A candidate is a **"beam" hit** if its perpendicular span overlaps the source's.
  Discard anything not on the `d` side. Score `= K·majorAxis² + minorAxis²` with **K ≈ 13** (on-axis
  wins hard); **beam hits are preferred** over off-axis, nearest `majorAxis` first. → *This is exactly
  the "off-axis allowed but penalized ~13×" answer: never dead-ends on a slightly-offset neighbor, yet
  a directly-in-line event always beats a diagonal one.* `K` and the beam rule are tunable once on
  screen.
- **Invertibility = one-step directional memory** (mirrors the Tab memory): record the last move's
  origin so the exact reverse arrow returns to it; any other key clears it. (No full neighbor graph
  unless this proves insufficient.)
- **Layer crossing (week view).** ↓ from a band descends into the timed/deadline layer and ↑ climbs
  back — bands sit "above" the hour grid; treat the two layers as stacked bands in the logical space so
  the same scorer handles the hand-off.

## Cursor styling

Every keyboard-focus indicator shares **one look**: a **thin, dashed, red** (`#ff3b6b`) rounded-rect
**outline** — no fill. It applies to all three cursors *and* the drawer's field focus ring, so the whole
keyboard layer reads as a single system:

- **Block / band / event cursor** → the dashed outline around the cell (block/band) or the event.
- **Drawer field focus ring** → the same dashed outline (replaces the current solid ring).

The outline is a **single shared element that springs / slides** to its new position when focus moves
(rather than fading one ring out and another in), so the eye can track it. Implementation: one animated
overlay positioned at the focused target's frame (`matchedGeometryEffect` / anchor-driven) with a spring
animation. Mouse hover keeps its existing **neutral** treatment — different color, different job.

## Mouse / keyboard interop

Two input **modes**; last-input-wins for *visuals* only — the internal cursor position always persists:

- **Mouse mode** — entered on any mouse **move or click**. The keyboard cursor's *visual* disappears (its
  position is remembered); normal hover applies.
- **Keyboard mode** — entered only when a navigation/action key (arrows, Tab, Space, Enter, Esc,
  ⌘/⇧+arrows, …) is **consumed as a hot-key action by our keyboard system** — i.e. the key monitor
  *dispatched* it. Keys that are **passed through to a focused text input** (typing Space in a textarea,
  Enter/Tab/Esc in the title field, date field, notes editor, tag input, …) do **not** count and stay in
  mouse mode. On entering keyboard mode the current state's cursor visual appears at its remembered
  position and **mouse-hover visuals are suppressed**; only one system's highlight is ever on screen.
  *(Implementation: flip to keyboard mode on the monitor's dispatch path only — never on the
  `isTextInputFocused()` pass-through path.)*

Committing across the boundary:

- **Click commits / reseats** the cursor: clicking an event → event cursor on it; clicking a cell → block
  cursor there. **Hover never moves** the keyboard cursor (visual only).
- The **event cursor is one shared selection** (`selectedId`) for both mouse and keyboard.

**Initialization** — the first time a cursor is needed with no remembered position: the **hovered cell**
if any → else **today** (if in view) → else the view's **center cell**.

**Reveal vs. move** *(proposed; tunable)*: when the keyboard cursor is currently hidden (just left mouse
mode), the first navigation key **only reveals** it at its remembered position (no movement); the next key
moves it — so returning from the mouse never yanks your place. If already visible, keys act immediately.

## Implementation order

1. **Block cursor** + Space/Esc/⌘±/⌘N (year→month→week→day), with the placement rules.
2. **Event-cursor arrow navigation** (nearest-in-direction) + ⇧-resize (⌘-move already done).
3. **Band cursor** (grid navigation + ⌘N).
4. **Tab cycling** (carry-over + one-step memory).
5. **Extra Tab stops** (month track names, day dashboard).
