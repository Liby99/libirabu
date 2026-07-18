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

    /// A pre-folded search-index entry — one per display item across all years. Built once per data change
    /// (see `ensureSearchCorpus`), so a keystroke only scans this array with cheap string ops.
    struct SearchDoc {
        let id, title, color: String
        let year, month, day: Int        // month 0-based
        let hour: CGFloat?
        let kind: SearchHit.Kind
        let base: String                 // sourceId → collapses recurrence occurrences
        let foldedTitle: String
        let origTags: [String]
        let foldedTags: [String]
        let origNotes: String
        let foldedNotes: String
        let weekday: Int?                // Calendar weekday 1…7
        let signedDist: Int              // days from today at build time (− = past)
    }

    /// Build the search corpus if stale, else reuse it. Iterating every year here IS the expensive part
    /// (recurrence expansion + import merge + folding) — but it runs once per edit, not once per keystroke.
    func ensureSearchCorpus() -> [SearchDoc] {
        if let c = caches.search, c.gen == caches.editGen { return c.docs }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        func meta(_ y: Int, _ m: Int, _ d: Int) -> (wd: Int?, dist: Int) {
            guard let date = cal.date(from: DateComponents(year: y, month: m + 1, day: d)) else { return (nil, .max) }
            return (cal.component(.weekday, from: date),
                    cal.dateComponents([.day], from: today, to: cal.startOfDay(for: date)).day ?? .max)
        }
        func doc(_ id: String, _ title: String, _ color: String, _ y: Int, _ m: Int, _ d: Int, _ hour: CGFloat?, _ kind: SearchHit.Kind) -> SearchDoc {
            let tags = richTags(id), note = notes(id)
            let (wd, dist) = meta(y, m, d)
            return SearchDoc(id: id, title: title, color: color, year: y, month: m, day: d, hour: hour, kind: kind,
                             base: sourceId(of: id),
                             foldedTitle: Self.searchFold(title),
                             origTags: tags, foldedTags: tags.map { Self.searchFold($0) },
                             origNotes: note, foldedNotes: Self.searchFold(note),
                             weekday: wd, signedDist: dist)
        }
        var docs: [SearchDoc] = []
        for y in yearOptions {
            for e in displayEvents(for: y)    { docs.append(doc(e.id, e.title, e.color, y, e.month, e.day, e.startHour, .timed)) }
            for b in displayBands(for: y)     { docs.append(doc(b.id, b.title, b.color, y, b.month, b.startDay, nil, .band)) }
            for d in displayDeadlines(for: y) { docs.append(doc(d.id, d.title, d.color, y, d.month, d.day, d.hour, .deadline)) }
        }
        caches.search = (caches.editGen, docs)
        return docs
    }

    /// Warm the corpus — call when the search bar opens (⌘F), so the first keystroke is already fast.
    public func primeSearch() { _ = ensureSearchCorpus() }

    /// Word-anchored, multi-field, date-aware search over the cached corpus. Space-separated TERMS all must
    /// match (AND); a term matches by DATE reading (`2026-09-01`, `8/1`, `jul`, `wed`, a 4-digit year) OR a
    /// TEXT match — title & tags require a whole-word / word-prefix hit (NOT a fuzzy subsequence: "aaai" won't
    /// match "amazon ai"); notes allow a contiguous substring. Recurrences collapse to one row; ranked by text
    /// relevance blended with nearness to today. Returns the top `limit` rows plus the TOTAL match count.
    public func searchEvents(_ query: String, limit: Int = 30) -> (hits: [SearchHit], total: Int) {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map { Self.searchFold(String($0)) }.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return ([], 0) }

        struct Cand { let doc: SearchDoc; let rank: Double; let dist: Int; let tag: String?; let noteTerm: String? }
        var byBase: [String: Cand] = [:]   // sourceId → best occurrence

        for doc in ensureSearchCorpus() {
            var total = 0.0
            var tagHit: String?, noteTerm: String?
            var matched = true
            for term in terms {
                let dateS = Self.dateMatchScore(term, year: doc.year, month0: doc.month, day: doc.day, weekday: doc.weekday)
                let titleS = Self.wordScore(term, doc.foldedTitle)
                var tagS = 0.0, thisTag: String?
                for (i, ft) in doc.foldedTags.enumerated() {
                    let s = Self.wordScore(term, ft)
                    if s > tagS { tagS = s; thisTag = doc.origTags[i] }
                }
                let noteHit = !doc.foldedNotes.isEmpty && doc.foldedNotes.contains(term)   // fast folded substring
                let best = max(dateS, max(titleS, max(tagS * 0.9, noteHit ? 0.55 : 0)))
                if best <= 0 { matched = false; break }        // this term matched nothing → event excluded
                total += best
                if tagS > 0, tagHit == nil { tagHit = thisTag }
                if noteHit, noteTerm == nil { noteTerm = term }
            }
            guard matched else { continue }
            let rank = 0.7 * (total / Double(terms.count)) + 0.3 * Self.recencyScore(doc.signedDist)
            let dist = abs(doc.signedDist)
            if let ex = byBase[doc.base] {
                if rank > ex.rank || (rank == ex.rank && dist < ex.dist) {
                    byBase[doc.base] = Cand(doc: doc, rank: rank, dist: dist, tag: tagHit, noteTerm: noteTerm)
                }
            } else {
                byBase[doc.base] = Cand(doc: doc, rank: rank, dist: dist, tag: tagHit, noteTerm: noteTerm)
            }
        }

        let ranked = byBase.values.sorted { $0.rank > $1.rank || ($0.rank == $1.rank && $0.dist < $1.dist) }
        // Context ("why it matched") — computed only for the SHOWN rows: a notes snippet, else a #tag.
        let hits = ranked.prefix(limit).map { c -> SearchHit in
            let snippet = c.noteTerm.map { Self.searchSnippet(c.doc.origNotes, $0) } ?? ""
            let context = !snippet.isEmpty ? snippet : (c.tag.map { "#" + $0 } ?? "")
            return SearchHit(id: c.doc.id, title: c.doc.title, color: c.doc.color, year: c.doc.year,
                             month: c.doc.month, day: c.doc.day, hour: c.doc.hour, kind: c.doc.kind, context: context)
        }
        return (Array(hits), ranked.count)
    }

    // ── Search helpers ────────────────────────────────────────────────────────────
    /// Case- and diacritic-insensitive normalization for all matching.
    private static func searchFold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Word-anchored match in (0,1]: `term` must be a WHOLE WORD or the PREFIX of a word in `target` (both
    /// folded). Deliberately NOT a fuzzy subsequence — so "aaai" does NOT match "amazon ai", and "az" does
    /// NOT match "amazon". A whole-word hit scores highest, then a word-prefix; 0 if `term` never starts a
    /// word. (Mid-word substrings don't count — a searched word matches words.)
    static func wordScore(_ term: String, _ target: String) -> Double {
        if term.isEmpty || target.isEmpty || term.count > target.count { return 0 }
        let s = Array(target), t = Array(term)
        var best = 0.0
        for i in 0...(s.count - t.count) where i == 0 || Self.isWordBoundary(s[i - 1]) {   // only at word starts
            var k = 0
            while k < t.count && s[i + k] == t[k] { k += 1 }
            guard k == t.count else { continue }
            let end = i + t.count
            if end == s.count || Self.isWordBoundary(s[end]) { return 1.0 }   // exact word — can't do better
            best = 0.85                                                       // word prefix
        }
        return best
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
        cursor.bandCursorActive = false
        jumpToDay(loc.year, loc.month, loc.day) { [weak self] in self?.scrollToSelected() }
    }

    public enum CursorHint { case normal, grab, resizeLR, resizeV, text }
}
