@testable import CalendarEngine
import CalendarGeometry
import XCTest

/// Multiple calendars ("documents"): each is disjoint, only one is open at a time, and the default is
/// "Main". Store is redirected to a throwaway dir per test (redirectStoreToTemp → CC_DEMO_DATADIR).
@MainActor
final class MultiCalendarTests: XCTestCase {
    override func setUp() {
        super.setUp()
        redirectStoreToTemp()
        UserDefaults.standard.removeObject(forKey: PrefKeys.calActiveId)
        UserDefaults.standard.removeObject(forKey: PrefKeys.calRecents)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: PrefKeys.calActiveId)
        UserDefaults.standard.removeObject(forKey: PrefKeys.calRecents)
        unsetenv("CC_DEMO_DATADIR")
        super.tearDown()
    }

    private func addEvent(_ e: CalendarEngine, _ title: String) -> String {
        e.createTimedEvent(year: e.year, month: 5, day: 10, startHour: 9, endHour: 10, title: title, color: "blue")
    }

    func testDefaultCalendarIsMain() {
        let e = CalendarEngine()
        XCTAssertEqual(e.activeCalendarName, "Main")
        XCTAssertEqual(e.allCalendars.count, 1)
        XCTAssertFalse(e.canRemoveCalendar, "the only calendar can't be removed")
    }

    func testCreateSwitchIsolation() throws {
        let e = CalendarEngine()
        let a = addEvent(e, "A")
        XCTAssertTrue(e.items.events.contains { $0.id == a })

        // New calendar → empty, active, and now removable (two exist).
        e.createCalendar(named: "Debug")
        XCTAssertEqual(e.activeCalendarName, "Debug")
        XCTAssertTrue(e.items.events.isEmpty, "a new calendar starts empty")
        XCTAssertTrue(e.canRemoveCalendar)
        let b = addEvent(e, "B")
        XCTAssertEqual(e.items.events.count, 1)

        // Switch back to Main → only A; Debug's event never bleeds in.
        let mainId = try XCTUnwrap(e.allCalendars.first { $0.name == "Main" }?.id)
        e.switchCalendar(to: mainId)
        XCTAssertTrue(e.items.events.contains { $0.id == a })
        XCTAssertFalse(e.items.events.contains { $0.id == b })
    }

    func testActiveCalendarPersistsAcrossReload() {
        let e = CalendarEngine()
        _ = addEvent(e, "A") // in Main
        e.createCalendar(named: "Two") // switches to Two (Main persisted on the way out)
        _ = addEvent(e, "B") // in Two
        e.persistNow()

        // A fresh engine (relaunch) reopens the active calendar from UserDefaults.
        let e2 = CalendarEngine()
        XCTAssertEqual(e2.activeCalendarName, "Two")
        XCTAssertEqual(e2.items.events.count, 1, "reload sees only Two's data")
        XCTAssertEqual(e2.items.events.first?.title, "B")
    }

    func testRemoveFallsBackToAnother() {
        let e = CalendarEngine()
        let mainId = e.registry.activeId
        e.createCalendar(named: "Temp")
        let tempId = e.registry.activeId
        XCTAssertNotEqual(mainId, tempId)

        e.removeCurrentCalendar()
        XCTAssertEqual(e.allCalendars.count, 1)
        XCTAssertEqual(e.registry.activeId, mainId, "removing Temp falls back to Main")
        XCTAssertFalse(e.allCalendars.contains { $0.id == tempId })
    }

    func testRemoveLastIsNoOp() {
        let e = CalendarEngine()
        e.removeCurrentCalendar() // only Main exists → no-op
        XCTAssertEqual(e.allCalendars.count, 1)
        XCTAssertEqual(e.activeCalendarName, "Main")
    }

    func testRename() {
        let e = CalendarEngine()
        e.renameCurrentCalendar("Personal")
        XCTAssertEqual(e.activeCalendarName, "Personal")
        XCTAssertEqual(e.allCalendars.count, 1, "rename doesn't add a calendar")
    }

    func testDataIsDisjointAcrossCalendars() throws {
        // Ids are globally-unique UUIDs and each calendar is a separate file, so there's no cross-calendar
        // collision and no bleed: each calendar sees only its own event.
        let e = CalendarEngine()
        let a = addEvent(e, "A")
        e.createCalendar(named: "Other")
        let b = addEvent(e, "B")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(e.items.events.map(\.id), [b], "Other holds only B")
        let mainId = try XCTUnwrap(e.allCalendars.first { $0.name == "Main" }?.id)
        e.switchCalendar(to: mainId)
        XCTAssertEqual(e.items.events.map(\.id), [a], "Main holds only A")
    }

    func testAppleSelectionIsPerCalendar() throws {
        let e = CalendarEngine()
        e.appleSyncEnabled = true
        e.appleCalendarIds = ["work-cal"]

        e.createCalendar(named: "Other")
        XCTAssertFalse(e.appleSyncEnabled, "a new calendar has its own (empty) Apple subscription")
        XCTAssertTrue(e.appleCalendarIds.isEmpty)

        let mainId = try XCTUnwrap(e.allCalendars.first { $0.name == "Main" }?.id)
        e.switchCalendar(to: mainId)
        XCTAssertTrue(e.appleSyncEnabled, "Main's selection is preserved")
        XCTAssertEqual(e.appleCalendarIds, ["work-cal"])
    }

    func testLegacyStoreMigratesToMain() throws {
        // Pre-multi-calendar layout: a single data.json at the CalendarKit root.
        let base = calendarKitBaseDir()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let legacy = PersistedState(
            events: [TimedEvent(id: "new-1", year: 2026, month: 5, day: 10, startHour: 9, endHour: 10,
                                title: "Legacy", color: "blue", anchorTz: "America/New_York")],
            bands: [], deadlines: []
        )
        try JSONEncoder().encode(legacy).write(to: base.appendingPathComponent("data.json"))

        // Booting the engine migrates it into Main.
        let e = CalendarEngine()
        XCTAssertEqual(e.activeCalendarName, "Main")
        XCTAssertTrue(e.items.events.contains { $0.title == "Legacy" }, "legacy data loads into Main")
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("data.json").path),
                       "the legacy root data.json was moved into Main's dir")
    }
}
