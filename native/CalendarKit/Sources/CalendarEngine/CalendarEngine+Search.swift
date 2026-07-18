// Toolbar search (⌘F): fuzzy + date-aware matching over all item kinds, ranked by string
// score × today-relevance, plus revealAndSelect (jump the view to a hit like a click).
// Split from CalendarEngine.swift (the god-file diet).

import Foundation
import CoreGraphics
import CalendarGeometry

extension CalendarEngine {
    // ── Search (toolbar ⌘F) ─────────────────────────────────────────────────────────
    /// One match in the toolbar search dropdown. `id` is the display/box id (a recurrence occurrence or
    /// import carries its own id) — pass it straight to `revealAndSelect(id:)`, which mirrors a click.
    public struct SearchHit: Identifiable, Equatable, Sendable {
        public enum Kind: String, Sendable { case timed, band, deadline }
        public let id: String
        public let title: String
        public let color: String
        public let year: Int
        public let month: Int      // 0-based
        public let day: Int
        public let hour: CGFloat?  // start hour for timed/deadline; nil for all-day bands
        public let kind: Kind
        public let context: String // why it matched, when a tag or notes hit (a "#tag" or notes snippet); "" for title/date
    }

    /// Fuzzy, multi-field search over every selectable year's merged event set (seed + recurrence
    /// occurrences + Apple imports; hidden imports already excluded). The query splits into space-separated
    /// TERMS — every term must match (AND). A term matches an event if EITHER its DATE reading
    /// (`2026-09-01`, `8/1`, `jul`/`july`, `wed`/`weds`/`wednesday`, a 4-digit year) OR a fuzzy TEXT match
    /// (title & tags: subsequence; notes: substring) hits — the stronger score wins. Recurrences collapse to
    /// one row; results rank by text relevance blended with nearness to today (a match years away sinks
    /// beneath a nearby one). Capped at `limit`.
    public func searchEvents(_ query: String, limit: Int = 8) -> [SearchHit] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map { Self.searchFold(String($0)) }.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        func signedDist(_ y: Int, _ m: Int, _ d: Int) -> Int {
            guard let date = cal.date(from: DateComponents(year: y, month: m + 1, day: d)) else { return .max }
            return cal.dateComponents([.day], from: today, to: cal.startOfDay(for: date)).day ?? .max
        }
        struct Cand { let hit: SearchHit; let rank: Double; let dist: Int }
        var byBase: [String: Cand] = [:]   // sourceId → best occurrence (collapses recurrences)

        func consider(_ id: String, _ title: String, _ color: String, _ y: Int, _ m: Int, _ d: Int, _ hour: CGFloat?, _ kind: SearchHit.Kind) {
            let foldedTitle = Self.searchFold(title)
            let origTags = richTags(id)
            let foldedTags = origTags.map { Self.searchFold($0) }
            let origNotes = notes(id)
            let wd = cal.date(from: DateComponents(year: y, month: m + 1, day: d)).map { cal.component(.weekday, from: $0) }

            var total = 0.0
            var ctxNote: String?, ctxTag: String?
            for term in terms {
                let dateS = Self.dateMatchScore(term, year: y, month0: m, day: d, weekday: wd)
                let titleS = Self.fuzzyScore(term, foldedTitle)
                var tagS = 0.0, tagHit: String?
                for (i, ft) in foldedTags.enumerated() {
                    let s = Self.fuzzyScore(term, ft)
                    if s > tagS { tagS = s; tagHit = origTags[i] }
                }
                let noteHit = origNotes.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                let noteS = noteHit ? 0.55 : 0.0

                let best = max(dateS, max(titleS, max(tagS * 0.9, noteS)))
                if best <= 0 { return }        // this term matched nothing → event excluded
                total += best
                if noteHit, ctxNote == nil { ctxNote = Self.searchSnippet(origNotes, term) }
                if tagS > 0, ctxTag == nil, let th = tagHit { ctxTag = "#" + th }
            }

            let signed = signedDist(y, m, d)
            let dist = abs(signed)
            let rank = 0.7 * (total / Double(terms.count)) + 0.3 * Self.recencyScore(signed)
            let hit = SearchHit(id: id, title: title, color: color, year: y, month: m, day: d, hour: hour, kind: kind,
                                context: ctxNote ?? ctxTag ?? "")
            let base = sourceId(of: id)
            if let ex = byBase[base] {
                if rank > ex.rank || (rank == ex.rank && dist < ex.dist) { byBase[base] = Cand(hit: hit, rank: rank, dist: dist) }
            } else {
                byBase[base] = Cand(hit: hit, rank: rank, dist: dist)
            }
        }
        for y in yearOptions {
            for e in displayEvents(for: y)    { consider(e.id, e.title, e.color, y, e.month, e.day, e.startHour, .timed) }
            for b in displayBands(for: y)     { consider(b.id, b.title, b.color, y, b.month, b.startDay, nil, .band) }
            for d in displayDeadlines(for: y) { consider(d.id, d.title, d.color, y, d.month, d.day, d.hour, .deadline) }
        }
        return byBase.values
            .sorted { $0.rank > $1.rank || ($0.rank == $1.rank && $0.dist < $1.dist) }
            .prefix(limit)
            .map(\.hit)
    }

    // ── Search helpers ────────────────────────────────────────────────────────────
    /// Case- and diacritic-insensitive normalization for all matching.
    private static func searchFold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// fzf-lite subsequence score in (0,1]; 0 unless `term` is a subsequence of `target`. Consecutive
    /// matches and word-boundary starts score higher, so a contiguous substring beats a scattered match and
    /// a prefix beats a mid-word hit. Inputs must already be folded.
    static func fuzzyScore(_ term: String, _ target: String) -> Double {
        if term.isEmpty || target.isEmpty { return 0 }
        let t = Array(term), s = Array(target)
        if t.count > s.count { return 0 }
        var ti = 0, prev = -2, first = -1, raw = 0.0
        for si in 0..<s.count {
            guard ti < t.count, s[si] == t[ti] else { continue }
            if first < 0 { first = si }
            var pt = 1.0
            if si == prev + 1 { pt += 1.2 }                                // consecutive run
            if si == 0 || Self.isWordBoundary(s[si - 1]) { pt += 1.5 }     // start of a word
            raw += pt
            prev = si; ti += 1
        }
        guard ti == t.count else { return 0 }                             // all term chars consumed?
        var score = raw / (Double(t.count) * 3.7)                         // 3.7 ≈ max per-char credit
        if first == 0 { score += 0.12 }                                   // whole-string prefix nudge
        return min(1.0, score)
    }
    private static func isWordBoundary(_ c: Character) -> Bool {
        " -_/,.:\n#".contains(c)
    }

    /// A term's DATE reading scored against an event's date (`month0` 0-based). 0 if the term isn't a date
    /// concept, or is one that doesn't match this date.
    static func dateMatchScore(_ term: String, year y: Int, month0 m: Int, day d: Int, weekday wd: Int?) -> Double {
        let mm = m + 1
        // ISO yyyy-mm-dd
        let iso = term.split(separator: "-", omittingEmptySubsequences: false)
        if iso.count == 3, iso[0].count == 4, let py = Int(iso[0]), let pm = Int(iso[1]), let pd = Int(iso[2]) {
            return (py == y && pm == mm && pd == d) ? 0.95 : 0
        }
        // m/d or m-d (1–2 digits each)
        for sep: Character in ["/", "-"] {
            let p = term.split(separator: sep, omittingEmptySubsequences: false)
            if p.count == 2, p[0].count <= 2, p[1].count <= 2, let pm = Int(p[0]), let pd = Int(p[1]),
               (1...12).contains(pm), (1...31).contains(pd) {
                return (pm == mm && pd == d) ? 0.9 : 0
            }
        }
        // 4-digit year
        if term.count == 4, let yr = Int(term), (1900...2200).contains(yr) { return yr == y ? 0.7 : 0 }
        // month name / ≥3-char prefix
        if let mo = monthIndex(term) { return mo == mm ? 0.8 : 0 }
        // weekday name / abbreviation
        if let w = weekdayIndex(term), let wd { return w == wd ? 0.8 : 0 }
        return 0
    }
    private static func monthIndex(_ term: String) -> Int? {   // 1…12
        guard term.count >= 3 else { return nil }
        let months = ["january","february","march","april","may","june","july","august","september","october","november","december"]
        for (i, name) in months.enumerated() where name.hasPrefix(term) { return i + 1 }
        return nil
    }
    private static func weekdayIndex(_ term: String) -> Int? {  // Calendar weekday: 1=Sun … 7=Sat
        if let w = ["tues": 3, "thur": 5, "thurs": 5, "weds": 4][term] { return w }   // non-prefix abbrevs
        guard term.count >= 3 else { return nil }
        let days = ["sunday","monday","tuesday","wednesday","thursday","friday","saturday"]
        for (i, name) in days.enumerated() where name.hasPrefix(term) { return i + 1 }
        return nil
    }
    /// Today-relevance in (0,1]: 1 at today, decaying with distance; past dates are mildly penalized so
    /// upcoming/recent events float up and years-old ones sink.
    private static func recencyScore(_ signedDays: Int) -> Double {
        if signedDays == .max { return 0 }
        let r = 1.0 / (1.0 + Double(abs(signedDays)) / 45.0)
        return signedDays < 0 ? r * 0.7 : r
    }
    /// A short one-line snippet of `notes` around the first occurrence of `term`, with ellipses.
    private static func searchSnippet(_ notes: String, _ term: String) -> String {
        guard let r = notes.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) else { return "" }
        let pad = 24
        let start = notes.index(r.lowerBound, offsetBy: -pad, limitedBy: notes.startIndex) ?? notes.startIndex
        let end = notes.index(r.upperBound, offsetBy: pad, limitedBy: notes.endIndex) ?? notes.endIndex
        var s = String(notes[start..<end]).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if start != notes.startIndex { s = "…" + s }
        if end != notes.endIndex { s += "…" }
        return s
    }

    /// Locate a display item by its box id across all years → the concrete date to fly to.
    private func searchLocate(_ id: String) -> (year: Int, month: Int, day: Int)? {
        for y in yearOptions {
            if let e = displayEvents(for: y).first(where: { $0.id == id })    { return (y, e.month, e.day) }
            if let b = displayBands(for: y).first(where: { $0.id == id })     { return (y, b.month, b.startDay) }
            if let d = displayDeadlines(for: y).first(where: { $0.id == id }) { return (y, d.month, d.day) }
        }
        return nil
    }

    /// Search-bar commit: fly to the event's day and select/highlight it (as a click would). Bands render
    /// as all-day items in day view, so every kind lands on its day; `scrollToSelected` reveals the hour
    /// for timed/deadline once we settle.
    public func revealAndSelect(id: String) {
        guard let loc = searchLocate(id) else { return }
        wake(); enterKeyboardMode()
        selectedId = id
        bandCursorActive = false
        jumpToDay(loc.year, loc.month, loc.day) { [weak self] in self?.scrollToSelected() }
    }

    public enum CursorHint { case normal, grab, resizeLR, resizeV, text }
}
