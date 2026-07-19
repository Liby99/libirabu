import XCTest
@testable import CalendarEngine
import CalendarGeometry

@MainActor
final class ICSFeedTests: XCTestCase {
    private let feed = """
    BEGIN:VCALENDAR
    VERSION:2.0
    BEGIN:VEVENT
    UID:standup@google.com
    DTSTART:20260706T090000
    DTEND:20260706T093000
    RRULE:FREQ=WEEKLY;COUNT=4
    EXDATE:20260720T090000
    SUMMARY:Standup
    END:VEVENT
    BEGIN:VEVENT
    UID:offsite@google.com
    DTSTART;VALUE=DATE:20260710
    DTEND;VALUE=DATE:20260712
    SUMMARY:Offsite
    END:VEVENT
    END:VCALENDAR
    """

    /// Weekly COUNT=4 minus one EXDATE → 3 occurrences with stable, per-occurrence ids sharing
    /// one series key; the all-day VEVENT becomes a 2-day band (exclusive DTEND).
    func testFeedExpansionAndStableIds() {
        let a = ICSImport.feedItems(from: feed, feedKey: "abc123", years: 2025 ... 2027)
        XCTAssertEqual(a.events.count, 3, "Jul 6, 13, 27 (20th EXDATEd)")
        let days = a.events.map(\.day).sorted()
        XCTAssertEqual(days, [6, 13, 27])
        XCTAssertTrue(a.events.allSatisfy { $0.month == 6 }, "July, 0-based")
        let series = Set(a.events.map { CalendarEngine.appleSeriesKey($0.id) })
        XCTAssertEqual(series, ["gcal-abc123-standup@google.com"], "occurrence suffix strips to one series")
        XCTAssertEqual(a.bands.count, 1)
        XCTAssertEqual(a.bands[0].startDay, 10)
        XCTAssertEqual(a.bands[0].endDay, 11, "DTEND is exclusive")

        // Refetch → identical ids (stability is what makes hide/color overlays survive refreshes).
        let b = ICSImport.feedItems(from: feed, feedKey: "abc123", years: 2025 ... 2027)
        XCTAssertEqual(Set(a.events.map(\.id)), Set(b.events.map(\.id)))
    }

    /// Feed ids count as imported (read-only) and the series key carries the user overlays.
    func testFeedIdsAreImported() {
        let e = CalendarEngine()
        XCTAssertTrue(e.isImported("gcal-abc123-standup@google.com-20260706-0900"))
        XCTAssertFalse(e.isImported("new-123"))
    }
}
