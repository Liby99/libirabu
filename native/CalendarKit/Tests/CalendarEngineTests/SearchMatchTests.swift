import XCTest
@testable import CalendarEngine

/// Unit tests for the search matchers (fuzzy text + date concepts). These are pure static functions, so
/// they exercise the core scoring without standing up a full engine/view.
@MainActor
final class SearchMatchTests: XCTestCase {

    // ── Fuzzy text ──────────────────────────────────────────────────────────────
    func testExactSubstringBeatsScatteredSubsequence() {
        let exact = CalendarEngine.fuzzyScore("plan", "sprint planning")   // contiguous
        let scattered = CalendarEngine.fuzzyScore("pig", "sprint planning")// p…i…g subsequence
        XCTAssertGreaterThan(exact, 0)
        XCTAssertGreaterThan(scattered, 0)
        XCTAssertGreaterThan(exact, scattered)
    }

    func testPrefixBeatsMidWord() {
        let prefix = CalendarEngine.fuzzyScore("cof", "coffee chat")
        let mid = CalendarEngine.fuzzyScore("hat", "coffee chat")
        XCTAssertGreaterThan(prefix, mid)
    }

    func testOmissionTypoStillMatches() {
        // "wednesdy" is a subsequence of "wednesday" (missing the 'a').
        XCTAssertGreaterThan(CalendarEngine.fuzzyScore("wednesdy", "wednesday"), 0)
    }

    func testNonSubsequenceDoesNotMatch() {
        XCTAssertEqual(CalendarEngine.fuzzyScore("zzz", "coffee chat"), 0)
        // Transposition is NOT a subsequence (we deliberately don't do edit-distance).
        XCTAssertEqual(CalendarEngine.fuzzyScore("wendesday", "wednesday"), 0)
    }

    // ── Date concepts ─────────────────────────────────────────────────────────────
    // Reference date: Wednesday, 2026-07-15 (July, month0 = 6, weekday 4 = Wednesday).
    private let y = 2026, m0 = 6, d = 15, wed = 4

    private func score(_ term: String) -> Double {
        CalendarEngine.dateMatchScore(term, year: y, month0: m0, day: d, weekday: wed)
    }

    func testMonthNameAndPrefix() {
        XCTAssertGreaterThan(score("july"), 0)
        XCTAssertGreaterThan(score("jul"), 0)
        XCTAssertEqual(score("august"), 0)
        XCTAssertEqual(score("ju"), 0)          // <3 chars → not treated as a month
    }

    func testWeekdayNamesAndAbbrevs() {
        XCTAssertGreaterThan(score("wednesday"), 0)
        XCTAssertGreaterThan(score("wed"), 0)
        XCTAssertGreaterThan(score("weds"), 0)  // non-prefix abbrev
        XCTAssertEqual(score("mon"), 0)
    }

    func testISOAndSlashDates() {
        XCTAssertGreaterThan(score("2026-07-15"), 0)
        XCTAssertEqual(score("2026-07-16"), 0)
        XCTAssertGreaterThan(score("7/15"), 0)
        XCTAssertGreaterThan(score("7-15"), 0)  // m-d form
        XCTAssertEqual(score("8/15"), 0)
    }

    func testYear() {
        XCTAssertGreaterThan(score("2026"), 0)
        XCTAssertEqual(score("2025"), 0)
    }

    func testNonDateTermScoresZero() {
        XCTAssertEqual(score("coffee"), 0)
    }
}
