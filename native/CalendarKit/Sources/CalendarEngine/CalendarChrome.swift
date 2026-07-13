// Observable snapshot of the calendar's navigation state for the toolbar breadcrumb.
// The engine pushes to this on navigation (not per frame), so the toolbar updates
// without observing the engine's high-frequency animation state.

import Observation

@MainActor
@Observable
public final class CalendarChrome {
    public internal(set) var level = 0      // 0 year · 1 month · 2 week · 3 day
    public internal(set) var year = 2026
    public internal(set) var focus = 0      // month 0–11
    public internal(set) var week = 0.0
    public internal(set) var dailyDom = 1
    public init() {}
}
