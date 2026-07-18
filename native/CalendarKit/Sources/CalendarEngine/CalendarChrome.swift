// Observable snapshot of the calendar's navigation state for the toolbar breadcrumb.
// The engine pushes to this on navigation (not per frame), so the toolbar updates
// without observing the engine's high-frequency animation state.

import Observation

@MainActor
@Observable
public final class CalendarChrome {
    public internal(set) var level = 0      // 0 year · 1 month · 2 week · 3 day
    public internal(set) var year = 2026
    public internal(set) var focus = 0      // month 0–11 — the RENDER anchor (also sizes the week/day pagers)
    public internal(set) var week = 0.0
    public internal(set) var dailyDom = 1
    // Breadcrumb-only "most visible" month/day: flips to the neighbor at the HALFWAY point of a
    // scroll/page/flip (like `week`, which the crumb already rounds), so the crumb tracks the animation
    // instead of snapping only once it fully lands. Kept separate from `focus`/`dailyDom` so the pagers'
    // sizing/anchoring is unaffected. Still discrete (changes on the midpoint crossing, not per frame).
    public internal(set) var displayFocus = 0
    public internal(set) var displayDom = 1
    public internal(set) var monthResync = 0   // bumped when the month pager must re-sync to `focus`
    public internal(set) var weekResync = 0    // bumped when the week pager must re-sync to `week`/`focus`
    public internal(set) var dailyResync = 0   // bumped when the day pager must re-sync to `daily.dom`/width
    public init() {}
}
