# Help GIFs — inventory & suggestions

The in-app Help browser (`Help ▸ MagiCal Help`, `Sources/CalendarUI/Help/`) can show a short GIF at the top
of a topic. A topic opts in by setting `HelpTopic.gif` to an asset name; the GIF is loaded from
`Sources/CalendarUI/Resources/tutorial/<name>.gif` (same folder the onboarding carousel uses). A missing
GIF is simply not shown, so topics stay usable before the asset exists.

All GIFs are produced by `scripts/record-tutorial.sh <scene>` (see `DemoController.swift`). Recording is
privacy-isolated (throwaway store, Apple import off) and re-runnable.

## Already recorded (reused from the onboarding tutorial)

These exist today and are wired into the matching Help topics:

| asset | used by Help topic | scene |
|-------|--------------------|-------|
| `pinch-zoom.gif` | Getting Around ▸ *Zoom between year, month, week, and day*; Getting Started ▸ *The four zoom levels* | `pinch-zoom` |
| `band-year.gif` | Events ▸ *Create a multi-day event (band)* | `band-year` |
| `timed-week.gif` | Events ▸ *Create a timed event*; Getting Started ▸ *Create your first event* | `timed-week` |
| `ai-assistant.gif` | The AI Assistant ▸ *Meet MagiCal AI* | `ai-assistant` |
| `markdown-notes.gif` | Organizing ▸ *Notes & to-do lists* | `markdown-notes` |

## Suggested NEW GIFs (not yet recorded — let's discuss before building)

Ordered by how much a motion demo would help. Each would need a new scene in `DemoController.swift`
(scene name in parentheses) and, where useful, a tuned crop.

1. **Move / resize an event** (`move-resize`) — Events ▸ *Move or resize an event*.
   Drag an event to a new time, then drag its bottom edge to lengthen it. Week view, cropped to a couple of
   day columns. High value: the drag affordances aren't obvious from a still.

2. **Edit in the drawer** (`edit-drawer`) — Events ▸ *Edit an event*.
   Double-click an event → drawer opens → change color + time. Right-half crop (like markdown-notes).
   Overlaps a little with the notes GIF; could be merged into one "the event drawer" demo.

3. **Add a deadline** (`deadline-add`) — Deadlines ▸ *Add a deadline*.
   Hover a day column, click the "+" that appears, set an AOE time in the drawer. Week view. Medium value —
   the hover "+" is genuinely hard to discover.

4. **Recurring event** (`recurring`) — Events ▸ *Repeat an event*.
   Open the drawer, pick a weekly repeat, watch the ghosts populate the following weeks. Month or week view.
   Medium value.

5. **Search** (`search-demo`) — Keyboard & Tips ▸ *Search your calendar*.
   ⌘F, type a fuzzy/date query (e.g. `coffee wed`), arrow to a result, Return to fly to it. Full window or a
   top strip crop. Medium value — shows off the new fuzzy/date search.

6. **Promote to a track** (`promote`) — Organizing ▸ *Tracks & promoting events*.
   Rename a lane, then promote a deadline onto it so a ghost bar appears in the month. Year/month view.
   Lower value / more niche.

7. **Daily dashboard to-dos** (`daily-dashboard`) — Getting Around ▸ *The daily dashboard*.
   Day view; check off a to-do in the To-Do tab and see it reflect in the note. Right-panel crop.
   Lower value — the notes GIF already hints at this.

### Notes for recording
- Reuse the two-way ready/go handshake + `done.txt` trim already in `record-tutorial.sh` so each GIF is
  tight (no setup animation, no dead tail).
- Full-window scenes: `FPS=12 SCALE≈760–900 COLORS=128 DITHER=none`; cropped scenes use the defaults. All
  get the `gifsicle --lossy=24` pass.
- Keep each ≤ ~10 s so the Help window stays snappy.
