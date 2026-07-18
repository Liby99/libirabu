import XCTest
@testable import CalendarEngine

@MainActor
final class UndoTests: XCTestCase {
    /// Does an engine-level title edit land on the undo stack and revert on undo()?
    func testTitleEditIsUndoable() {
        let e = CalendarEngine()
        guard let first = e.seedEvents.first else { return XCTFail("no seed events") }
        let id = first.id
        let old = first.title

        e.update(id) { $0.title = "ZZZ Renamed" }
        XCTAssertEqual(e.event(id)?.title, "ZZZ Renamed", "edit applied")

        e.undo()
        XCTAssertEqual(e.event(id)?.title, old, "undo should restore the pre-edit title")

        e.redo()
        XCTAssertEqual(e.event(id)?.title, "ZZZ Renamed", "redo should re-apply the edit")
    }

    /// Live-typed edits (one engine.update per keystroke, coalesced) should undo as ONE step.
    func testTypingBurstCoalescesToOneUndo() {
        let e = CalendarEngine()
        guard let first = e.seedEvents.first else { return XCTFail("no seed events") }
        let id = first.id
        let old = first.title

        for s in ["N", "Ne", "New", "New ", "New T"] { e.update(id) { $0.title = s } }
        XCTAssertEqual(e.event(id)?.title, "New T")

        e.undo()
        XCTAssertEqual(e.event(id)?.title, old, "one undo should revert the whole typing burst")
    }
}
