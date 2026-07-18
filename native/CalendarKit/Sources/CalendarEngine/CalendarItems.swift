// The user's calendar data, composed: the single mutable source of truth the engine edits,
// undo snapshots, and the sync layer persists. First step of the engine's field-composition
// hierarchy (items / caches / cursor / … instead of one flat sea of properties).

import CoreGraphics
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

/// Read-only items imported from Apple Calendar (EventKit). Kept SEPARATE from `items` so they
/// never persist to disk / push to iCloud (they're re-fetched) and can't be edited.
public struct ImportedItems: Sendable {
    public internal(set) var events: [TimedEvent] = []
    public internal(set) var bands: [BandEvent] = []
    /// EventKit identifier → our item id, for opening the original in Calendar.app.
    var appleEventIds: [String: String] = [:]
    public init() {}
}

/// The keyboard-navigation cursor family: the block cursor (month/day/hour), the band-lane and
/// track-name cursors, and the day-view dashboard stops. One unit of "where keyboard focus is".
public struct CursorState {
    /// Keyboard mode is ON (arrow keys drive a cursor; mouse motion turns it off).
    public internal(set) var keyboardActive = false
    public internal(set) var blockMonth = 0
    public internal(set) var blockDay = 1
    public internal(set) var blockHour: CGFloat = 12
    public internal(set) var bandCursorActive = false
    public internal(set) var bandCurTrack = 0
    public internal(set) var trackNameCursor: Int?
    public internal(set) var dashStop: CalendarEngine.DashStop?
    public internal(set) var dashNoteEditing = false
    /// The event to re-select when ⇧Tab leaves the TODO stop.
    var dashReturnEvent: String?
    /// One-step directional memory: the last event move, so the exact reverse arrow returns.
    var lastEventMove: (from: String, dx: Int, dy: Int, to: String)?
    public init() {}
}
