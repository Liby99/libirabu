// The daily dashboard's data feed (TODO index + deadline list for the WebView bridge), the
// per-day markdown daily note, scoped deletes for recurring events (this / this+future / all,
// matching the web), and band occurrence dates for the recurring-band drawer.
// Split from CalendarEngine.swift (the god-file diet).

import CalendarGeometry
import CoreGraphics
import Foundation

extension CalendarEngine {
    /// ── Daily dashboard data (feeds the WebView TODO index + deadline list) ────────────────────
    /// Mirrors the web's TodoEventContext[] so the bundled `todos.ts` tokenizer + sectioning render
    /// identically. Wall-clock strings ("YYYY-MM-DD[THH:MM:SS]"); a timed event carries its year here.
    private struct TodoContext: Codable { var id, kind, title, color: String; var tags: [String]; var start,
                                                                                                      end: String; var originTz: String?; var notes: String?; var occurrenceNotes: [
                                                                                                          String: String
                                                                                                      ]?
    }

    private struct DashDeadline: Codable { var id: String; var year, month, day: Int; var hour: Double; var title,
                                                                                                            color: String
    }

    private struct DashPayload: Codable { var events: [TodoContext]; var deadlines: [DashDeadline]; var viewIso,
                                                                                                        today: String; var dailyNotes: [
                                                                                                            String: String
                                                                                                        ]
    }

    private func wall(_ y: Int, _ m0: Int, _ d: Int, _ hour: CGFloat? = nil) -> String {
        let base = String(format: "%04d-%02d-%02d", y, m0 + 1, d)
        guard let hour else { return base }
        let t = Int((hour * 60).rounded())
        return base + String(format: "T%02d:%02d:00", (t / 60) % 24, t % 60)
    }

    private func todoContexts() -> [TodoContext] {
        func ctx(
            _ id: String,
            _ kind: String,
            _ title: String,
            _ color: String,
            _ start: String,
            _ end: String,
            _ tz: String? = nil
        ) -> TodoContext {
            let rf = items.richById[id]
            return TodoContext(id: id, kind: kind, title: title, color: color, tags: rf?.tags ?? [],
                               start: start, end: end, originTz: tz, notes: rf?.notes,
                               occurrenceNotes: rf?.occurrenceNotes)
        }
        var out: [TodoContext] = []
        // Timed events + deadlines are converted anchor→view tz (like the timeline) so the dashboard's
        // schedule matches what's drawn. Bands are all-day → no conversion.
        for e0 in items.events {
            let e = displayEvent(e0); out.append(ctx(
                e0.id,
                "timed",
                e.title,
                e.color,
                wall(e.year, e.month, e.day, e.startHour),
                wall(e.year, e.month, e.day, min(e.endHour, 24))
            ))
        }
        for b in items.bands {
            out.append(ctx(
                b.id,
                "band",
                b.title,
                b.color,
                wall(b.year, b.month, b.startDay),
                wall(b.year, b.month, b.endDay)
            ))
        }
        for d0 in items
            .deadlines {
            let d = displayDeadline(d0); let w = wall(d.year, d.month, d.day, d.hour); out.append(ctx(
                d0.id,
                "deadline",
                d.title,
                d.color,
                w,
                w
            ))
        }
        return out
    }

    /// The JSON the dashboard WebView consumes: contexts + deadlines + the viewed day + real today.
    public func dashboardDataJSON() -> String {
        let dls = items.deadlines.map { d0 -> DashDeadline in let d = displayDeadline(d0)
            return DashDeadline(
                id: d0.id,
                year: d.year,
                month: d.month,
                day: d.day,
                hour: Double(d.hour),
                title: d.title,
                color: d.color
            )
        }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let today = String(format: "%04d-%02d-%02d", c.year ?? year, c.month ?? 1, c.day ?? 1)
        let r = resolveDate(year, focus, daily.dom)
        let viewIso = r.map { wall($0.year, $0.month, $0.day) } ?? wall(year, focus, daily.dom)
        let payload = DashPayload(
            events: todoContexts(),
            deadlines: dls,
            viewIso: viewIso,
            today: today,
            dailyNotes: items.dailyNotes
        )
        return (try? JSONEncoder().encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// Wall-clock date ("YYYY-MM-DD") for a focus-relative day-of-month, resolving month rollover.
    public func dayIso(_ dom: Int) -> String? {
        guard let r = resolveDate(year, focus, dom) else { return nil }
        return wall(r.year, r.month, r.day)
    }

    /// The day-carousel state the dashboard WebView animates: the centered day, the neighbour it's
    /// paging toward (empty when at rest), the direction + progress (mirroring `daily.anim`), and the
    /// zoom `reveal` (0 at week level → 1 at day level, matching the chrome's `clamp(z-2,0,1)`) that
    /// drives the panel's slide-in-from-right + fade as the day view opens/closes. (The panel stays put
    /// when the drawer opens — the scrim dims it in place — so no drawer state is needed here.)
    public func dashboardCarousel() -> (from: String, to: String, dir: Int, p: Double, reveal: Double) {
        let reveal = Double(dashRevealTotal(snapshot())) // day-forced OR pinned (⌘B) reveal
        let from = dayIso(daily.dom) ?? ""
        guard let a = daily.anim else { return (from, "", 0, 0, reveal) }
        return (from, dayIso(daily.dom + a.dir) ?? "", a.dir, Double(a.p), reveal)
    }

    /// Apply a dashboard checkbox toggle (or any note rewrite): the WebView sends back the new note.
    public func applyTodoNote(eventId: String, occKey: String?, value: String) {
        if let occKey, !occKey.isEmpty {
            setOccNote(eventId, occKey, value)
        } else {
            setNotes(eventId, value)
        }
    }

    /// All items carrying notes (with their identity + date) — the assistant's TODO scan walks
    /// these plus the daily notes to reconstruct what the TODO panel shows.
    public func notedItems() -> [(id: String, title: String, kind: ItemKind,
                                  year: Int, month: Int, day: Int, notes: String)] {
        var out: [(String, String, ItemKind, Int, Int, Int, String)] = []
        for (id, rf) in items.richById {
            guard let notes = rf.notes, !notes.isEmpty else { continue }
            if let e = items.events.first(where: { $0.id == id }) {
                out.append((id, e.title, .timed, e.year, e.month, e.day, notes))
            } else if let b = items.bands.first(where: { $0.id == id }) {
                out.append((id, b.title, .band, b.year, b.month, b.startDay, notes))
            } else if let d = items.deadlines.first(where: { $0.id == id }) {
                out.append((id, d.title, .deadline, d.year, d.month, d.day, notes))
            }
        }
        return out
    }

    /// Every stored daily note, keyed by ISO date "YYYY-MM-DD".
    public func allDailyNotes() -> [String: String] {
        items.dailyNotes
    }

    /// ── Daily note (the dashboard NOTE tab) — one markdown note per ISO date ────────────────────
    public func dailyNote(_ iso: String) -> String {
        items.dailyNotes[iso] ?? ""
    }

    public func setDailyNote(_ iso: String, _ v: String) {
        guard items.dailyNotes[iso] != v else { return }
        if v.isEmpty {
            items.dailyNotes[iso] = nil
        } else {
            items.dailyNotes[iso] = v
        }
        schedulePersist()
    }

    /// Merge imported daily notes (e.g. migrated from the web server); non-empty values win.
    public func importDailyNotes(_ notes: [String: String]) {
        for (iso, v) in notes where !v.isEmpty {
            items.dailyNotes[iso] = v
        }
        schedulePersist()
    }

    /// ── Scoped delete for recurring events (matches the web: this / this+future / all) ─────────
    /// Remove just the focused occurrence — punch a hole by adding its date to the repeat exdates.
    public func deleteOccurrence(_ id: String, _ occKey: String) {
        guard var rep = repeatConfig(id), let ymd = occurrenceYMD(id, occKey) else { return }
        var ex = rep.exdates ?? []
        let iso = occDate(ymd)
        if !ex.contains(iso) {
            ex.append(iso)
        }
        rep.exdates = ex
        setRepeat(id, rep)
        if selectedId == occKey || selectedId == id {
            selectedId = nil
        }
    }

    /// Remove this occurrence and everything after — cap the series `until` the day before it.
    public func deleteFuture(_ id: String, _ occKey: String) {
        guard var rep = repeatConfig(id), let ymd = occurrenceYMD(id, occKey) else { return }
        rep.until = occDate(dayBefore(ymd))
        setRepeat(id, rep)
        if selectedId == occKey || selectedId == id {
            selectedId = nil
        }
    }

    /// The occurrence's date: a ghost box carries "id@Y-M-D" (0-based month); the base box uses the
    /// series' own base date.
    private func occurrenceYMD(_ id: String, _ occKey: String) -> YMD? {
        let occKey = occurrenceKey(of: occKey) // drop the promoted-band marker if present
        if let at = occKey.firstIndex(of: "@") {
            let p = occKey[occKey.index(after: at)...].split(separator: "-").compactMap { Int($0) }
            if p.count == 3 {
                return YMD(p[0], p[1], p[2])
            }
        }
        if let b = items.bands.first(where: { $0.id == id }) {
            return YMD(b.year, b.month, b.startDay)
        }
        if let d = items.deadlines.first(where: { $0.id == id }) {
            return YMD(d.year, d.month, d.day)
        }
        if let e = items.events.first(where: { $0.id == id }) {
            return YMD(year, e.month, e.day)
        }
        return nil
    }

    private func dayBefore(_ p: YMD) -> YMD {
        let c = utcCalendar
        let d = c.date(from: DateComponents(year: p.year, month: p.month + 1, day: p.day)) ?? Date()
        let prev = c.date(byAdding: .day, value: -1, to: d) ?? d
        let x = c.dateComponents([.year, .month, .day], from: prev)
        return YMD(x.year ?? p.year, (x.month ?? 1) - 1, x.day ?? p.day)
    }

    /// `p` shifted by `n` days (0-based month, crossing month/year boundaries). UTC to avoid DST drift.
    static func addDaysYMD(_ p: YMD, _ n: Int) -> YMD {
        let c = utcCalendar
        let d = c.date(from: DateComponents(year: p.year, month: p.month + 1, day: p.day)) ?? Date()
        let nd = c.date(byAdding: .day, value: n, to: d) ?? d
        let x = c.dateComponents([.year, .month, .day], from: nd)
        return YMD(x.year ?? p.year, (x.month ?? 1) - 1, x.day ?? p.day)
    }

    /// ── Band occurrence dates (for the recurring-band drawer) ──────────────────────────────────
    /// The date range of the occurrence a band BOX currently represents — the shifted occurrence for a
    /// ghost, or the base band's own range. `occKey` is the selected box's occurrence key. Cross-month
    /// spans are honoured (start and end may be in different months). nil if not a band.
    public func bandOccurrenceRange(_ occKey: String) -> (start: YMD, end: YMD)? {
        let src = sourceId(of: occKey)
        guard let base = items.bands.first(where: { $0.id == src }) else { return nil }
        let start = occurrenceYMD(src, occKey) ?? YMD(base.year, base.month, base.startDay)
        return (start, Self.addDaysYMD(start, base.endDay - base.startDay))
    }

    /// A band's base (FIRST) occurrence start date — what the drawer's "Started …" button jumps to.
    public func bandBaseStart(_ id: String) -> YMD? {
        guard let base = items.bands.first(where: { $0.id == sourceId(of: id) }) else { return nil }
        return YMD(base.year, base.month, base.startDay)
    }

    /// The date a specific BOX represents: a ghost's own occurrence date, else the base date.
    public func occurrenceStart(of boxId: String) -> YMD? {
        occurrenceYMD(sourceId(of: boxId), occurrenceKey(of: boxId))
    }

    /// The neighboring occurrence's BOX id (dir −1/＋1), or nil at the series edge / not recurring.
    public func neighborOccurrence(of boxId: String, dir: Int) -> String? {
        let src = sourceId(of: boxId)
        guard let rep = repeatConfig(src), let base = baseYMD(src),
              let cur = occurrenceYMD(src, occurrenceKey(of: boxId)) else { return nil }
        var dates: Set<YMD> = []
        for y in (cur.year - 1) ... (cur.year + 1) {
            dates.formUnion(occurrenceDates(base, rep, y))
        }
        dates.insert(base)
        let sorted = dates.sorted { ($0.year, $0.month, $0.day) < ($1.year, $1.month, $1.day) }
        guard let i = sorted.firstIndex(of: cur), (0 ..< sorted.count).contains(i + dir) else { return nil }
        let t = sorted[i + dir]
        return t == base ? src : "\(src)@\(t.year)-\(t.month)-\(t.day)"
    }

    private func baseYMD(_ src: String) -> YMD? {
        dateOf(src).map { YMD($0.0, $0.1, $0.2) }
    }

    /// Navigate to a box (base or ghost): fly to its day and select it.
    public func goToBox(_ boxId: String) {
        let target = occurrenceStart(of: boxId) ?? baseYMD(sourceId(of: boxId)).map { $0 }
        guard let t = target else { return }
        select(boxId)
        jumpToDay(t.year, t.month, t.day)
    }

    public func repeatConfig(_ id: String) -> Repeat? {
        Repeat.parse(items.richById[id]?.repeatJSON)
    }

    public func promoteTrack(_ id: String) -> Int? {
        items.richById[overlayKey(id)]?.promoteTrack
    }

    /// ⌘U / context-menu toggle: promote the timed event OR deadline to `defaultPromoteLane` (topmost
    /// free lane on its day), or clear an existing promotion. No-op for band ids (already on a lane).
    public func togglePromote(_ boxId: String) {
        let sid = sourceId(of: boxId)
        guard event(sid) != nil || deadline(sid) != nil else { return }
        setPromoteTrack(sid, promoteTrack(sid) == nil ? defaultPromoteLane(for: sid) : nil)
    }

    /// The topmost band lane with nothing on the item's day; every lane taken → lane 0.
    public func defaultPromoteLane(for boxId: String) -> Int {
        let sid = sourceId(of: boxId)
        let ymd: (y: Int, m: Int, d: Int)? = event(sid).map { ($0.year, $0.month, $0.day) }
            ?? deadline(sid).map { ($0.year, $0.month, $0.day) }
        guard let (y, m, d) = ymd else { return 0 }
        var used = Set<Int>()
        for b in bandsInMonth(y, m) where b.startDay <= d && b.endDay >= d {
            used.insert(b.track)
        }
        return (0 ..< TRACKS.count).first { !used.contains($0) } ?? 0
    }

    func mutateRich(_ id: String, _ mutate: (inout RichFields) -> Void) {
        beginTxn() // tags / repeat / promote are structural edits → one undo step each
        var rf = items.richById[id] ?? RichFields()
        mutate(&rf)
        items.richById[id] = rf
        caches.editGen &+= 1 // repeat / promote change the expanded display set → invalidate the cache
        scheduleCommit()
        schedulePersist()
    }

    public func setTags(_ id: String, _ tags: [String]) {
        mutateRich(overlayKey(id)) { $0.tags = tags }
    }

    public func setPromoteTrack(_ id: String, _ t: Int?) {
        mutateRich(overlayKey(id)) { $0.promoteTrack = t }
    }

    public func setRepeat(_ id: String, _ r: Repeat?) {
        var json: String? = nil
        if let r, r.kind != "none",
           let data = try? JSONEncoder().encode(r) {
            json = String(data: data, encoding: .utf8)
        }
        mutateRich(id) { $0.repeatJSON = json }
    }

    public func remove(_ id: String) {
        beginTxn()
        items.events.removeAll { $0.id == id }
        items.bands.removeAll { $0.id == id }
        items.deadlines.removeAll { $0.id == id }
        if selectedId == id {
            selectedId = nil
        }
        commitTxn()
    }

    /// Everything the delete-confirmation dialog needs about the current selection: the source id, the
    /// focused occurrence-box id (so a recurring occurrence can be dropped precisely), whether it recurs
    /// (→ scope choices, or the "make a local copy" note for imported series), and whether it's imported
    /// (→ the Hide flow instead of Delete). Nil only when nothing is selected.
    public struct DeleteTarget: Equatable {
        public let id: String; public let occKey: String; public let recurring: Bool
        public let imported: Bool
        public let alreadyHidden: Bool // imported + already user-hidden → the "can't delete / already hidden" dialog
    }

    public func deleteTargetForSelection() -> DeleteTarget? {
        guard let sel = selectedId else { return nil }
        let src = sourceId(of: sel)
        if isImported(src) {
            return DeleteTarget(id: src, occKey: occurrenceKey(of: sel), recurring: isImportedSeries(src),
                                imported: true, alreadyHidden: isUserHidden(src))
        }
        return DeleteTarget(id: src, occKey: occurrenceKey(of: sel), recurring: repeatConfig(src) != nil,
                            imported: false, alreadyHidden: false)
    }

    /// An imported event is "recurring" when the fetch window holds more than one occurrence sharing its
    /// series key (EventKit pre-expands recurrences into separate boxes with the same underlying uid).
    public func isImportedSeries(_ id: String) -> Bool {
        let key = Self.appleSeriesKey(sourceId(of: id))
        return imported.events.filter { Self.appleSeriesKey($0.id) == key }.count > 1
    }

    /// "Hide" an imported event (or series): a persistent user overlay on the series key that keeps every
    /// occurrence out of the view, surviving re-imports (unlike the dedup `hidden`). Undoable + synced.
    public func hideImportedSeries(_ id: String) {
        mutateRich(Self.appleSeriesKey(sourceId(of: id))) { $0.userHidden = true }
        if let sel = selectedId, isImported(sel) {
            selectedId = nil
        }
        caches.deadlineGen &+= 1; wake()
    }

    /// Reverse a hide — clear the series' `userHidden` overlay so it draws normally again. Also
    /// clears a per-OCCURRENCE exclusion (the make-local-copy "exdate") when this box carries one,
    /// so Unhide on a revealed excluded occurrence brings that occurrence back.
    public func unhideImportedSeries(_ id: String) {
        let sid = sourceId(of: id)
        if items.richById[sid]?.userHidden == true {
            mutateRich(sid) { $0.userHidden = false }
        }
        mutateRich(Self.appleSeriesKey(sid)) { $0.userHidden = false }
        caches.deadlineGen &+= 1; wake()
    }

    /// Whether an imported box is user-hidden — its series OR the occurrence itself (the
    /// make-local-copy exclusion). Drives the drawer's Unhide button.
    public func isUserHidden(_ id: String) -> Bool {
        items.richById[Self.appleSeriesKey(sourceId(of: id))]?.userHidden == true
            || items.richById[sourceId(of: id)]?.userHidden == true
    }
}
