# Calendar

A zoomable timeline calendar (year → month → week → day) with timed events, all-day
"band" events, and deadlines. Rendering is DOM-based: every frame the geometry layer
turns the current view state into a flat list of positioned items + event rects, which
the view layer renders as absolutely-positioned elements.

## Folder layout

```
calendar/
  page.tsx            Route entry — renders <CalendarCanvas/> + <AssistantFab/>
  calendar.css        Global styles (see styles/ note below)

  view/               React components (presentational + interaction). No business logic.
    CalendarCanvas      Top-level orchestrator: wires hooks → render tree
    layers/             Per-kind render+interaction layers (events, bands, deadlines, promoted)
    events/             Single-item renderers (TimedEventView, BandEventView, Item, badges)
    drawers/            Detail editors (shared shell + per-kind wrappers)
    menus/              Top-bar dropdowns + right-click menu
    editors/            Small inline form widgets (repeat, tags, track, promote)
    daily/              Day-view sidebar (dashboard, resize handle, timeline scrollbar)
    notes/              CodeMirror editor + markdown preview + remark/CM plugins

  geometry/           Pure math. No React. The "model → pixels" layer.
    constants.ts        ★ single source of truth for layout dimensions
    types.ts            view/render primitives (Vp, Frame, Hover, Item, Scene)
    frames.ts           per-month geometry as a function of the zoom scalar z
    eventGeom.ts        timed-event rects, hour-height, collision layout (layoutDay)
    bandGeom.ts         all-day band rects + spillover clipping
    hittest.ts          cursor → calendar element, per zoom level
    scene.ts            builds the flat Item[] for one frame (grid, labels, today/now)

  model/              Data model, business logic, persistence. No React rendering.
    types/              data types (TimedEvent, BandEvent, Deadline)
    occurrences.ts      recurrence expansion (rule → in-year dates)
    history.ts          undo/redo stack + edit coalescing
    api/                REST client (apiClient) + mock/seed data + YEAR state
    hooks/              data stores (useEvents, useBandEvents, useDeadlines, settings)

  interactions/       useCalendarInteractions — the gesture + view-state engine
  util/               leaf helpers (dates, timezones, deadline formatting)
  assistant/          AI assistant FAB + chat panel (self-contained)
  todos/              /calendar/todos route
```

## Data flow

```
useCalendarInteractions  ──(view state: z, focus, week, scroll, hover)──┐
useEvents/Band/Deadlines ──(data)──────────────────────────────────────┤
                                                                        ▼
                                                          CalendarCanvas (view/)
                                                                        │
                                              geometry/ (frames, scene, *Geom, hittest)
                                                                        │
                                                          positioned items + rects
                                                                        ▼
                                                       view/layers + view/events
```

## Conventions

- **Layout numbers** belong in `geometry/constants.ts`. A few are mirrored in CSS and
  bridged at runtime so the value lives in exactly one place. Interaction *tuning*
  (gesture thresholds, animation durations) stays beside the gesture code; pure per-draw
  offsets stay beside their draw call.
- The geometry layer is **pure** — keep React and side effects out of it so it stays
  cheap to call every frame and easy to reason about.
