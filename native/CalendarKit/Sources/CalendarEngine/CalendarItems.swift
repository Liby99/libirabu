// The user's calendar data, composed: the single mutable source of truth the engine edits,
// undo snapshots, and the sync layer persists. First step of the engine's field-composition
// hierarchy (items / caches / cursor / … instead of one flat sea of properties).

import CalendarGeometry

public struct CalendarItems: Sendable {
    public internal(set) var events: [TimedEvent] = []
    public internal(set) var bands: [BandEvent] = []
    public internal(set) var deadlines: [Deadline] = []
    public init() {}
}

/// Derived-display caches + their invalidation generations — rebuilt on demand, keyed by
/// `editGen`, never persisted. Composed so the engine's cache state is one visible unit.
struct DisplayCaches {
    /// Bumped on every edit → invalidates all the per-(year, gen) caches below.
    var editGen = 0
    /// Bumped when the deadline-label sides must re-solve.
    var deadlineGen = 0
    var band: (year: Int, gen: Int, bands: [BandEvent], badges: [String: EventBadges], byMonth: [Int: [BandEvent]])?
    var event: (year: Int, gen: Int, events: [TimedEvent], badges: [String: EventBadges], byDay: [Int: [TimedEvent]])?
    var ddl: (year: Int, gen: Int, deadlines: [Deadline])?
    var ddlSides: [String: Bool] = [:]
    var ddlSidesKey: (focus: Int, incoming: Int, year: Int, gen: Int, detail: Bool, dayView: Bool)?
    var search: (gen: Int, docs: [CalendarEngine.SearchDoc])?
}
