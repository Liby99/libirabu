import XCTest
@testable import CalendarEngine
import CalendarGeometry

@MainActor
final class TimezoneTests: XCTestCase {

    /// Alt-tz off by default → the scene carries no second column.
    func testAltTzOffByDefault() {
        let e = CalendarEngine()
        XCTAssertNil(e.snapshotInput().altDeltaHours)
        XCTAssertNil(e.snapshotInput().altLabel)
    }

    /// Setting an alt tz populates the scene's altDeltaHours/altLabel (which drive the drawn column).
    func testAltTzPopulatesScene() {
        let e = CalendarEngine()
        e.mainTz = "America/New_York"
        e.altTz = "Asia/Tokyo"
        let s = e.snapshotInput()
        XCTAssertNotNil(s.altDeltaHours)
        // NY→Tokyo is +13 (EDT) or +14 (EST) depending on the date.
        XCTAssertTrue([13.0, 14.0].contains(Double(s.altDeltaHours ?? 0)), "shift was \(String(describing: s.altDeltaHours))")
        XCTAssertEqual(s.altLabel, DeadlineTZ.shortLabel("Asia/Tokyo", at: e.now))
    }

    /// "none", empty, or same-as-main → no column.
    func testAltTzGuards() {
        let e = CalendarEngine()
        e.mainTz = "America/New_York"
        e.altTz = "none";               XCTAssertNil(e.snapshotInput().altDeltaHours)
        e.altTz = "America/New_York";   XCTAssertNil(e.snapshotInput().altDeltaHours)   // == main
    }

    /// Half-hour zones produce a fractional shift (India is +5:30 vs UTC).
    func testFractionalShift() {
        let e = CalendarEngine()
        e.mainTz = "UTC"
        e.altTz = "Asia/Kolkata"
        let d = e.snapshotInput().altDeltaHours ?? 0
        XCTAssertEqual(Double(d), 5.5, accuracy: 0.001)
    }
}

@MainActor
final class AnchorTZTests: XCTestCase {
    private func setMain(_ tz: String, _ e: CalendarEngine) {
        UserDefaults.standard.set(tz, forKey: CalendarEngine.mainTzKey)
        e.viewPrefsChanged()   // re-reads mainTz AND bumps editGen so the display cache re-converts
    }
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: CalendarEngine.mainTzKey)
        super.tearDown()
    }

    /// A timed event anchored in ET renders 3h earlier when the view switches to PT (same instant), and
    /// its duration is preserved. This is the core "change current timezone → events move" behavior.
    func testTimedEventShiftsWithMainTz() {
        let e = CalendarEngine()
        setMain("America/New_York", e)
        let id = e.createTimedEvent(year: 2026, month: 6, day: 20, startHour: 12, endHour: 14, title: "Mtg", color: "blue")
        XCTAssertTrue(e.displayEvents(for: 2026).contains { $0.id == id && abs($0.startHour - 12) < 0.001 })
        setMain("America/Los_Angeles", e)
        let disp = e.displayEvents(for: 2026).first { $0.id == id }
        XCTAssertNotNil(disp)
        XCTAssertEqual(Double(disp!.startHour), 9, accuracy: 0.001)   // 12:00 ET → 09:00 PT
        XCTAssertEqual(Double(disp!.endHour), 11, accuracy: 0.001)    // duration preserved
    }

    /// A deadline anchored at 23:00 ET shows at 20:00 PT the same day.
    func testDeadlineShiftsWithMainTz() {
        let e = CalendarEngine()
        setMain("America/New_York", e)
        let id = e.createDeadline(year: 2026, month: 6, day: 20, hour: 23, title: "CFP", color: "red")
        setMain("America/Los_Angeles", e)
        let d = e.displayDeadlines(for: 2026).first { $0.id == id }
        XCTAssertNotNil(d)
        XCTAssertEqual(Double(d!.hour), 20, accuracy: 0.001)
        XCTAssertEqual(d!.day, 20)
    }

    /// Day-crossing: 01:00 ET on Jul 20 is 22:00 PT on Jul 19 — the converted item moves to the previous day.
    func testConversionCrossesMidnight() {
        let e = CalendarEngine()
        setMain("America/New_York", e)
        let id = e.createDeadline(year: 2026, month: 6, day: 20, hour: 1, title: "Early", color: "red")
        setMain("America/Los_Angeles", e)
        let d = e.displayDeadlines(for: 2026).first { $0.id == id }
        XCTAssertNotNil(d)
        XCTAssertEqual(Double(d!.hour), 22, accuracy: 0.001)
        XCTAssertEqual(d!.day, 19)
    }

    /// Viewing in the anchor zone is the identity (no drift), and a round-trip back restores the time.
    func testRoundTripIdentity() {
        let e = CalendarEngine()
        setMain("America/New_York", e)
        let id = e.createTimedEvent(year: 2026, month: 6, day: 20, startHour: 8.5, endHour: 9.75, title: "X", color: "blue")
        setMain("Asia/Tokyo", e)
        XCTAssertNotNil(e.displayEvents(for: 2026).first { $0.id == id })   // exists somewhere (maybe next day)
        setMain("America/New_York", e)
        let back = e.displayEvents(for: 2026).first { $0.id == id }
        XCTAssertNotNil(back)
        XCTAssertEqual(Double(back!.startHour), 8.5, accuracy: 0.001)
        XCTAssertEqual(Double(back!.endHour), 9.75, accuracy: 0.001)
        XCTAssertEqual(back!.day, 20)
    }
}

@MainActor
final class DeadlineCreateTests: XCTestCase {
    /// The "+" click path: createDeadline mints an id, selects it, and it shows on the timeline.
    func testCreateDeadline() {
        let e = CalendarEngine()
        let before = e.displayDeadlines(for: 2026).count
        let id = e.createDeadline(year: 2026, month: 6, day: 20, hour: 9, title: "New Deadline", color: "default")
        XCTAssertFalse(id.isEmpty)
        XCTAssertEqual(e.selectedId, id)
        let ddls = e.displayDeadlines(for: 2026)
        XCTAssertEqual(ddls.count, before + 1)
        XCTAssertTrue(ddls.contains { $0.id == id && $0.hour == 9 && $0.day == 20 && $0.title == "New Deadline" })
    }
}
