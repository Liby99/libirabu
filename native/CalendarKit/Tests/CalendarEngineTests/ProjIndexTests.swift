// ProjIndex — the projects/gantt model port. Semantics under test: row membership (top-level
// @project todos only), the bar origin chain (start: shadows created: shadows the source day),
// explicit-due-only hatching input, band event bars (series + per-occurrence), deadline
// milestones, and the active-in-range filter.

@testable import CalendarEngine
import CalendarGeometry
import XCTest

final class ProjIndexTests: XCTestCase {
    private let today = "2026-07-30"

    func testBuildRowsBarsAndMilestones() {
        let sources = [
            TodoSource(id: "ev1", kind: "timed", title: "Sync", color: "blue", tags: [],
                       start: "2026-07-10T10:00:00", end: "2026-07-10T11:00:00",
                       notes: """
                       - [ ] row from source day @project:alpha
                       - [ ] shadowed start:2026-07-20 created:2026-07-12 @project:alpha
                       - [x] finished due:2026-07-14 done:2026-07-18T12:00 @project:alpha
                         - [ ] sub-item never a row @project:alpha
                       - [ ] no explicit due @project:alpha
                       """),
            TodoSource(id: "band1", kind: "band", title: "Retreat", color: "green", tags: [],
                       start: "2026-08-01", end: "2026-08-03",
                       notes: "@project:alpha",
                       occurrenceNotes: ["band1@2026-8-10": "@project:alpha"]),
            TodoSource(id: "dl1", kind: "deadline", title: "CFP", color: "red", tags: [],
                       start: "2026-08-20T23:59:00", end: "2026-08-20T23:59:00",
                       notes: "@project:alpha\n- [ ] prep the abstract @project:alpha"),
        ]
        let deadlines = [Deadline(id: "dl1", year: 2026, month: 7, day: 20, hour: 23.98,
                                  title: "CFP", color: "red")]
        let todos = TodoIndex.indexTodos(sources, today: today)
        let projects = ProjIndex.build(todos: todos, sources: sources, deadlines: deadlines,
                                       today: today)
        XCTAssertEqual(projects.count, 1)
        let p = projects[0]
        XCTAssertEqual(p.key, "alpha")
        // Rows: 4 top-level event-note todos + 1 from the deadline's note; the sub-item is not a row.
        XCTAssertEqual(p.tasks.count, 5)
        let byText = Dictionary(uniqueKeysWithValues: p.tasks.map { ($0.todo.text, $0) })
        XCTAssertEqual(byText["row from source day"]?.start, "2026-07-10")
        XCTAssertEqual(byText["shadowed"]?.start, "2026-07-20") // start: beats created: and the day
        XCTAssertEqual(byText["finished"]?.end, "2026-07-18")
        XCTAssertEqual(byText["finished"]?.due, "2026-07-14") // explicit due survives
        XCTAssertNil(byText["no explicit due"]?.due) // inherited due must NOT hatch
        // Event bars: the series note + the tagged occurrence (0-based month key → Sep 10, +2d span).
        XCTAssertEqual(p.events.count, 2)
        XCTAssertEqual(p.events.map(\.start).sorted(), ["2026-08-01", "2026-09-10"])
        XCTAssertEqual(p.events.map(\.end).sorted(), ["2026-08-03", "2026-09-12"])
        XCTAssertEqual(p.deadlines.map(\.id), ["dl1"])
    }

    func testShownFiltersByRangeActivity() {
        let src = [TodoSource(id: "e", kind: "timed", title: "T", color: "red", tags: [],
                              start: "2026-07-01T09:00:00", end: "2026-07-01T10:00:00",
                              notes: "- [x] old done:2026-06-10T09:00 created:2026-06-01 @project:stale")]
        let todos = TodoIndex.indexTodos(src, today: today)
        let projects = ProjIndex.build(todos: todos, sources: src, deadlines: [], today: today)
        // Active in June, not in late July.
        XCTAssertEqual(ProjIndex.shown(projects, rs: "2026-06-01", re: "2026-06-30").count, 1)
        XCTAssertEqual(ProjIndex.shown(projects, rs: "2026-07-20", re: "2026-07-27").count, 0)
    }
}
