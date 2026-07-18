// Keyboard navigation over EVENTS + the day-view dashboard stops: arrow-key movement between
// visible event boxes (with one-step reverse memory), nudge/resize of the selection, and the
// TODO/NOTE dashboard cursor dispatched to the WebView bridge. Split from CalendarEngine.swift.

import Foundation
import CoreGraphics
import CalendarGeometry

extension CalendarEngine {
    // ── Day-view dashboard keyboard stops (TODO / NOTE) — dispatched to the WebView bridge ─────────
    /// Move the TODO row cursor (↑/↓). No-op unless the TODO stop is focused.
    public func dashMove(_ d: Int) { guard dashStop == .todo else { return }; enterKeyboardMode(); onDashCommand?(.move(d)) }
    /// Space/Enter on a dashboard stop: TODO → toggle the focused row; NOTE → focus the editor (edit mode).
    public func dashActivate() {
        enterKeyboardMode()
        switch dashStop {
        case .todo: onDashCommand?(.activate)
        case .note: dashNoteEditing = true; onDashCommand?(.activate)
        case nil:   break
        }
    }
    /// Enter on the TODO stop → open the focused row's event (or fly to its daily note).
    public func dashOpen() { guard dashStop == .todo else { return }; enterKeyboardMode(); onDashCommand?(.open) }
    /// The note editor handed focus back (Esc or ⌘S in the WebView) → return to the NOTE ring.
    public func dashNoteExit() { guard dashStop == .note else { return }; dashNoteEditing = false; onDashCommand?(.focus(.note)) }
    /// Drop any dashboard focus (leaving day view via Esc / ⌘−). Idempotent.
    func clearDashStop() {
        guard dashStop != nil else { return }
        dashStop = nil; dashNoteEditing = false; dashReturnEvent = nil; onDashCommand?(.focus(nil))
    }

    /// Land the block cursor on an event's earliest anchor (band → startDay; timed/deadline → day+hour).
    func setBlockToEventAnchor(_ id: String) {
        if let b = displayBands(for: year).first(where: { $0.id == id }) {
            blockMonth = b.month; blockDay = min(daysInMonth(b.year, b.month), max(1, b.startDay))
        } else if let e = displayEvents(for: year).first(where: { $0.id == id }) {
            blockMonth = e.month; blockDay = e.day; blockHour = e.startHour
        } else if let d = displayDeadlines(for: year).first(where: { $0.id == id }) {
            blockMonth = d.month; blockDay = d.day; blockHour = d.hour
        }
    }

    /// Carry-over: the nearest event to the block cursor, per view.
    func nearestEventToBlock() -> String? {
        switch level(z) {
        case 0:   // year: a band in/near the cursor month, topmost lane
            return viewBands().min(by: {
                (abs($0.month - blockMonth), $0.track, $0.startDay) < (abs($1.month - blockMonth), $1.track, $1.startDay)
            })?.id
        case 1:   // month: a band covering/near the cursor day, topmost lane
            return viewBands().filter { $0.month == focus }
                .min(by: { (bandDayDist($0, blockDay), $0.track) < (bandDayDist($1, blockDay), $1.track) })?.id
        case 2, 3:   // week/day: nearest timed/deadline on the day by hour, else a band covering it
            let d = level(z) == 2 ? blockDay : daily.dom
            let timeline = viewEvents().filter { $0.month == focus && $0.day == d }.map { ($0.id, $0.startHour) }
                + viewDeadlines().filter { $0.month == focus && $0.day == d }.map { ($0.id, $0.hour) }
            if let best = timeline.min(by: { abs($0.1 - blockHour) < abs($1.1 - blockHour) }) { return best.0 }
            return viewBands().first { $0.month == focus && $0.startDay <= d && $0.endDay >= d }?.id
        default:
            return nil
        }
    }
    func bandDayDist(_ b: BandEvent, _ d: Int) -> Int {
        d < b.startDay ? b.startDay - d : (d > b.endDay ? d - b.endDay : 0)
    }
    func syncBlockVisible() {
        switch level(z) {
        case 0: ensureMonthVisible(blockMonth, animated: true)
        case 2, 3: ensureHourVisible()
        default: break
        }
    }

    /// Plain-arrow navigation between events (event cursor). Day view: ↑/↓ step through the day's events
    /// top-to-bottom (bands first, then timed/deadlines by time). Year/month/week use the 2-D focus
    /// engine — a later increment.

    public func navigateEvent(_ dx: Int, _ dy: Int) {
        enterKeyboardMode()
        guard let sel = selectedId else { return }
        if level(z) == 3 {
            // Day view: ↑/↓ step by TIME row; ←/→ switch between side-by-side overlaps.
            if dy != 0 {
                let ids = dayEventOrder()
                guard !ids.isEmpty else { return }
                guard let i = ids.firstIndex(of: sel) else {
                    selectedId = ids[dy > 0 ? 0 : ids.count - 1]; ensureSelectedEventVisible(); return
                }
                var j = i + dy
                // Skip side-by-side colliders of the current TIMED event — same-time overlaps are reached
                // with ←/→, so ↑/↓ moves to the next DISTINCT time row (A/B at 10–11 → C at 11–12). General
                // over any number of colliders and partial overlaps; a no-move is left as-is (no clamp onto
                // a collider). Bands / deadlines aren't timed boxes, so they end the skip.
                let evs = viewEvents()
                if let cur = evs.first(where: { $0.id == sel }) {
                    while ids.indices.contains(j), let n = evs.first(where: { $0.id == ids[j] }),
                          n.startHour < cur.endHour, cur.startHour < n.endHour { j += dy }
                }
                if ids.indices.contains(j), j != i { selectedId = ids[j]; ensureSelectedEventVisible() }
            } else if let n = focusFind(sel, dx, 0, rects: visibleEventRects()) {   // overlaps → the adjacent column
                selectedId = n; ensureSelectedEventVisible()
            }
            return
        }
        // Week view: ←/→ first hops between side-by-side overlapping events (their real time-columns). Only
        // when there's no such neighbor in that direction does it fall through to day-to-day navigation —
        // so the timeline's columns are reachable without losing cross-day movement.
        if level(z) == 2, dx != 0, let n = sideBySideNeighbor(sel, dx) {
            selectedId = n; lastEventMove = nil; scrollToSelected(); return
        }
        // Year / month / week: the 2-D focus engine over LOGICAL rects (so off-screen events are reachable).
        // Event navigation may cross quarter boundaries in year view (only the band CURSOR is quarter-bound).
        let allRects = logicalRects()
        var rects = allRects
        // Week view: PREFER the visible week — neither a vertical nor a horizontal move should teleport to an
        // off-screen event in another week's column (focusFind's beam preference would otherwise pick a far,
        // same-time event over a near, in-view one). ↑/↓ additionally drops the current event's same-time
        // colliders (those are reached with ←/→). ←/→ falls back to the full set below when the visible week
        // offers nothing in that direction (e.g. you're on the last visible day) — so you can still cross weeks.
        if level(z) == 2 {
            if let win = visibleWeekDOMRange() {
                // Keep `sel` regardless (focusFind needs its anchor); drop other-week events.
                rects.removeAll { $0.id != sel && ($0.rect.maxX <= CGFloat(win.lowerBound) || $0.rect.minX >= CGFloat(win.upperBound + 1)) }
            }
            if dy != 0 {
                let colliders = timedColliderIds(of: sel)
                if !colliders.isEmpty { rects.removeAll { colliders.contains($0.id) } }
            }
        }
        let next: String?
        if let m = lastEventMove, m.to == sel, m.dx == -dx, m.dy == -dy {
            next = m.from                                   // exact inverse → return to origin
        } else if let n = focusFind(sel, dx, dy, rects: rects) {
            next = n; lastEventMove = (sel, dx, dy, n)      // best within the (visible-week) candidate set
        } else if level(z) == 2, dx != 0, let n = focusFind(sel, dx, dy, rects: allRects) {
            next = n; lastEventMove = (sel, dx, dy, n)      // nothing left/right in the visible week → cross weeks
        } else { next = nil }
        if let n = next, n != sel { selectedId = n; scrollToSelected() }
    }

    /// On-screen rects (geometry space) of every visible event box — bands + timed + deadlines.
    private func visibleEventRects() -> [(id: String, rect: CGRect)] {
        let g = snapshot()
        // Month/week/day: only the FOCUS month's events are navigable — otherwise ↑ from the top lane in
        // month view would jump to an off-screen adjacent-month band. Year view keeps all months (its
        // ↑/↓ crosses months by design).
        let sameMonthOnly = level(z) != 0
        let dayOnly = level(z) == 3 ? daily.dom : nil   // day view: only the shown day's boxes are on screen
        var out: [(String, CGRect)] = []
        for b in viewBands() where !b.id.isEmpty {
            if sameMonthOnly && b.month != focus { continue }
            if let d = dayOnly, !(b.startDay <= d && b.endDay >= d) { continue }
            if let r = bandEventRect(b, g, anim: g.monthAnim) {
                out.append((b.id, CGRect(x: r.x, y: r.y, width: r.w, height: r.h)))
            }
        }
        if z >= 1.5 {
            let tl = timelineInfo(g)
            let evs = viewEvents().filter { $0.month == focus && (dayOnly == nil || $0.day == dayOnly) }
            var byDay: [Int: [TimedEvent]] = [:]
            for e in evs { byDay[e.day, default: []].append(e) }
            for e in evs {
                let layout = layoutDay(byDay[e.day] ?? [])[e.id]
                if let r = eventRect(e, year, focus, tl, g.vp, layout) {
                    out.append((e.id, CGRect(x: r.minX, y: tl.tlTop - tl.scroll + r.minY, width: r.width, height: r.height)))
                }
            }
            for d in viewDeadlines() where d.month == focus && (dayOnly == nil || d.day == dayOnly) {
                if let pos = deadlinePos(d, g) { out.append((d.id, CGRect(x: pos.x, y: pos.y - 9, width: pos.w, height: 18))) }
            }
        }
        return out
    }

    /// FocusFinder: the best event in direction (dx,dy) from `currentId`, scored over the given rect list.
    /// Edge distances, beam-preference, K≈13 major-axis weight — off-axis allowed but heavily penalized
    /// (see docs/prompts/keyboard_control.md). Callers pass LOGICAL rects (year/month/week — scroll-stable,
    /// so off-screen events are reachable) or geometric rects (day-view overlaps).
    private func focusFind(_ currentId: String, _ dx: Int, _ dy: Int, rects: [(id: String, rect: CGRect)]) -> String? {
        guard let cur = rects.first(where: { $0.id == currentId })?.rect else { return nil }
        let K: CGFloat = 13, beamPenalty: CGFloat = 1_000_000
        var best: String?; var bestScore = CGFloat.greatestFiniteMagnitude
        for (id, r) in rects where id != currentId {
            let major: CGFloat, minor: CGFloat, beam: Bool
            if dy != 0 {   // vertical move
                let centerAhead = dy > 0 ? r.midY - cur.midY : cur.midY - r.midY
                guard centerAhead > 0.5 else { continue }
                major = max(0, dy > 0 ? r.minY - cur.maxY : cur.minY - r.maxY)
                minor = gap(cur.minX, cur.maxX, r.minX, r.maxX)
                beam = r.maxX > cur.minX && r.minX < cur.maxX
            } else {       // horizontal move
                let centerAhead = dx > 0 ? r.midX - cur.midX : cur.midX - r.midX
                guard centerAhead > 0.5 else { continue }
                major = max(0, dx > 0 ? r.minX - cur.maxX : cur.minX - r.maxX)
                minor = gap(cur.minY, cur.maxY, r.minY, r.maxY)
                beam = r.maxY > cur.minY && r.minY < cur.maxY
            }
            let score = K * major * major + minor * minor + (beam ? 0 : beamPenalty)
            if score < bestScore { bestScore = score; best = id }
        }
        return best
    }
    /// Edge distance between two 1-D spans [a0,a1] and [b0,b1] (0 if they overlap).
    private func gap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> CGFloat {
        b1 < a0 ? a0 - b1 : (b0 > a1 ? b0 - a1 : 0)
    }

    /// The nearest TIMED event on the SAME day whose time overlaps the selection — i.e. a genuinely
    /// side-by-side box in its own layout column — in the horizontal direction `dx`. Uses the real
    /// per-column geometry (`eventRect` places overlaps at `col * subW`), so partial overlaps (10–11 vs
    /// 10–12) and 3+ columns all resolve correctly. nil when the selection isn't a timed box or has no such
    /// neighbor in that direction — the week-view caller then falls back to day-to-day navigation.
    private func sideBySideNeighbor(_ sel: String, _ dx: Int) -> String? {
        guard dx != 0, let day = selectedEventDay(sel) else { return nil }
        let g = snapshot()
        let tl = timelineInfo(g)
        guard tl.hourH > 0 else { return nil }
        let dayEvents = viewEvents().filter { $0.month == focus && $0.day == day }
        let layout = layoutDay(dayEvents)
        var rects: [String: CGRect] = [:]
        for e in dayEvents {
            if let r = eventRect(e, year, focus, tl, g.vp, layout[e.id]) { rects[e.id] = r }
        }
        guard let cur = rects[sel] else { return nil }   // selection must be a timed box on this day
        var best: String?; var bestAhead = CGFloat.greatestFiniteMagnitude
        for (id, r) in rects where id != sel {
            guard r.maxY > cur.minY, r.minY < cur.maxY else { continue }   // must overlap in TIME (side-by-side)
            let ahead = dx > 0 ? r.midX - cur.midX : cur.midX - r.midX
            guard ahead > 0.5, ahead < bestAhead else { continue }
            bestAhead = ahead; best = id
        }
        return best
    }

    /// The day-of-month window (7 days) currently visible in WEEK view, matching `ensureDayVisibleWeek`'s
    /// geometry. `↑/↓` restricts to this window so a vertical move can't jump to an off-screen event in
    /// another week (a different day column); `←/→` still crosses weeks (it shifts the window). nil unless
    /// in week view.
    private func visibleWeekDOMRange() -> ClosedRange<Int>? {
        guard level(z) == 2 else { return nil }
        let wk = (weekTween?.to ?? week).rounded()
        let startDOM = 1 - CGFloat(firstDOW(year, focus)) + wk * 7
        let lo = Int(startDOM.rounded())
        return lo...(lo + 6)
    }

    /// The ids of the timed events that COLLIDE (overlap in time) with `sel` on the same day — the boxes
    /// laid out side-by-side with it. `↑/↓` excludes these so a vertical move steps to the next time row
    /// rather than to a same-time neighbour (which `←/→` reaches). Empty if `sel` isn't a timed box.
    private func timedColliderIds(of sel: String) -> Set<String> {
        guard let cur = viewEvents().first(where: { $0.id == sel }) else { return [] }
        var out = Set<String>()
        for e in viewEvents() where e.id != sel && e.month == cur.month && e.day == cur.day
            && e.startHour < cur.endHour && cur.startHour < e.endHour {
            out.insert(e.id)
        }
        return out
    }

    /// LOGICAL rects for the focus engine — scroll-INDEPENDENT, so off-screen events are still reachable
    /// (year: bands stacked month×lane, x = day-span; week: bands at y=lane, timeline events below at
    /// y = 4 + hour; month: bands at y=lane). x is day-of-month, y is lanes/hours.
    private func logicalRects() -> [(id: String, rect: CGRect)] {
        func bandRect(_ b: BandEvent, yBase: CGFloat) -> (String, CGRect) {
            (b.id, CGRect(x: CGFloat(b.startDay), y: yBase + CGFloat(b.track),
                          width: CGFloat(b.endDay - b.startDay + 1), height: 1))
        }
        var out: [(String, CGRect)] = []
        switch level(z) {
        case 0:   // year: every month's bands, lanes stacked across months
            for b in viewBands() { out.append(bandRect(b, yBase: CGFloat(b.month * 4))) }
        case 1:   // month: the focus month's bands
            for b in viewBands() where b.month == focus { out.append(bandRect(b, yBase: 0)) }
        case 2:   // week: focus-month bands (lanes 0–3) + timeline events below (y = 4 + hour)
            for b in viewBands() where b.month == focus { out.append(bandRect(b, yBase: 0)) }
            for e in viewEvents() where e.month == focus {
                out.append((e.id, CGRect(x: CGFloat(e.day), y: 4 + e.startHour, width: 1, height: max(0.25, e.endHour - e.startHour))))
            }
            for d in viewDeadlines() where d.month == focus {
                out.append((d.id, CGRect(x: CGFloat(d.day), y: 4 + d.hour, width: 1, height: 0.25)))
            }
        default: break
        }
        return out
    }

    /// Scroll the view so the SELECTED event stays visible: year → the band's month; week → shift the
    /// 7-day focus window to the event's day (horizontal) AND scroll the timeline to its hours; day →
    /// the timeline hours. (Month view shows the whole month — no scroll needed.)
    func scrollToSelected() {   // internal: +Search's revealAndSelect uses it
        guard let sel = selectedId else { return }
        let isBand = displayBands(for: year).contains { $0.id == sel }
        switch level(z) {
        case 0:
            if let b = displayBands(for: year).first(where: { $0.id == sel }) { ensureMonthVisible(b.month, animated: true) }
        case 2:
            if let day = selectedEventDay(sel) { ensureDayVisibleWeek(day) }   // week window follows horizontally
            if !isBand { ensureSelectedEventVisible() }
        default:
            if !isBand { ensureSelectedEventVisible() }
        }
    }
    private func selectedEventDay(_ id: String) -> Int? {
        if let b = displayBands(for: year).first(where: { $0.id == id }) { return b.startDay }
        if let e = displayEvents(for: year).first(where: { $0.id == id }) { return e.day }
        if let d = displayDeadlines(for: year).first(where: { $0.id == id }) { return d.day }
        return nil
    }

    /// The current day's DISPLAY boxes in top-to-bottom order: bands (by lane) — including recurrence
    /// ghosts and promoted bars — then timed + deadline boxes by time. Every box is a distinct item;
    /// duplicate ids (a promoted-recurring box that is both) are collapsed once (band wins, listed first).
    private func dayEventOrder() -> [String] {
        let d = daily.dom
        var ids = viewBands()
            .filter { $0.month == focus && $0.startDay <= d && $0.endDay >= d }
            .sorted { $0.track < $1.track }.map { $0.id }
        let timed = viewEvents().filter { $0.month == focus && $0.day == d }.map { ($0.id, $0.startHour) }
        let ddls = viewDeadlines().filter { $0.month == focus && $0.day == d }.map { ($0.id, $0.hour) }
        ids += (timed + ddls).sorted { $0.1 < $1.1 }.map { $0.0 }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// Keyboard resize — grow/shrink the SELECTED event with ⇧+arrows, keeping its START fixed.
    /// Band: ⇧←/⇧→ change the END day (`dx`), clamped to [startDay, month end]. Timed: ⇧↑/⇧↓ change the
    /// END hour (`dy`: -1 shrink, +1 extend) by 15 min, clamped to [start + 15 min, 24h]. Deadlines have
    /// no duration → no resize.
    public func resizeSelected(_ dx: Int, _ dy: Int) {
        guard let sid = selectedId else { return }
        let id = sourceId(of: sid)
        if let b = band(id), dx != 0 {
            let ne = max(b.startDay, min(daysInMonth(b.year, b.month), b.endDay + dx))
            guard ne != b.endDay else { return }
            updateBand(id) { $0.endDay = ne }
        } else if let e = event(id), dy != 0 {
            let ne = max(e.startHour + 0.25, min(24, e.endHour + CGFloat(dy) * 0.25))
            guard ne != e.endHour else { return }
            update(id) { $0.endHour = ne }
        }
    }

    /// Keyboard nudge — move the SELECTED event vertically (cmd+up / cmd+down). `dir` = -1 (up) or +1
    /// (down). Bands move across the 4 lanes; timed/deadline move by 15 minutes. Moves are clamped: a
    /// nudge that would leave the valid range (lane 0…3, or the 0…24h day) does nothing.
    public func nudgeVertical(_ dir: Int) {
        guard let sid = selectedId else { return }
        let id = sourceId(of: sid)
        if let b = band(id) {
            let t = b.track + dir                       // -1 = up a lane, +1 = down a lane
            guard t >= 0, t <= 3 else { return }
            updateBand(id) { $0.track = t }
        } else if let e = event(id) {
            let step = CGFloat(dir) * 0.25              // 15 min; -1 = earlier (up), +1 = later (down)
            let ns = e.startHour + step, ne = e.endHour + step
            guard ns >= 0, ne <= 24 else { return }     // keep the whole event inside the day
            update(id) { $0.startHour = ns; $0.endHour = ne }
        } else if let d = deadline(id) {
            let nh = d.hour + CGFloat(dir) * 0.25
            guard nh >= 0, nh <= 24 else { return }
            updateDeadline(id) { $0.hour = nh }
        }
    }

    /// Keyboard nudge — move the SELECTED event horizontally by a day (cmd+left / cmd+right). Bands shift
    /// the whole span (start fixed relative to end); they CANNOT cross the month boundary. Timed/deadlines
    /// move their date by a day (across month/year). Follows with a scroll so it stays visible.
    public func nudgeHorizontal(_ dir: Int) {
        enterKeyboardMode()
        guard let sid = selectedId else { return }
        let id = sourceId(of: sid)
        if let b = band(id) {
            let ns = b.startDay + dir, ne = b.endDay + dir
            guard ns >= 1, ne <= daysInMonth(b.year, b.month) else { return }   // stay within the month
            updateBand(id) { $0.startDay = ns; $0.endDay = ne }
        } else if let e = event(id) {
            let (y, m, dd) = addDays(e.year, e.month, e.day, dir)
            update(id) { $0.year = y; $0.month = m; $0.day = dd }
        } else if let d = deadline(id) {
            let (y, m, dd) = addDays(d.year, d.month, d.day, dir)
            updateDeadline(id) { $0.year = y; $0.month = m; $0.day = dd }
        }
        scrollToSelected()
    }

    /// Add `delta` days to a (year, 0-based month, day), rolling months/years correctly.
    func addDays(_ y: Int, _ m0: Int, _ d: Int, _ delta: Int) -> (Int, Int, Int) {   // internal: used across the engine's extension files
        var c = DateComponents(); c.year = y; c.month = m0 + 1; c.day = d
        let cal = Calendar(identifier: .gregorian)
        guard let base = cal.date(from: c), let nd = cal.date(byAdding: .day, value: delta, to: base) else { return (y, m0, d) }
        let x = cal.dateComponents([.year, .month, .day], from: nd)
        return (x.year ?? y, (x.month ?? 1) - 1, x.day ?? d)
    }
    /// Whole-day difference (b − a) between two calendar dates (0-based months), DST-agnostic. Used to make
    /// mouse resize/create day-column aware so a drag into an adjacent day spans midnight rather than
    /// collapsing (the pointer's hour is relative to whichever day column it's over).
    func dayDiff(_ ay: Int, _ am: Int, _ ad: Int, _ by: Int, _ bm: Int, _ bd: Int) -> Int {   // internal: used across extension files
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        guard let a = cal.date(from: DateComponents(year: ay, month: am + 1, day: ad)),
              let b = cal.date(from: DateComponents(year: by, month: bm + 1, day: bd)) else { return 0 }
        return cal.dateComponents([.day], from: a, to: b).day ?? 0
    }

    /// Open the inline title editor for a band, positioned over its rect (geometry space). The click-a-
    /// selected-band gesture and the keyboard "Enter → edit title" (via `editSelectedBand`) both route here.
    public func editBand(_ id: String) {
        let g = snapshot()
        guard let b = items.bands.first(where: { $0.id == id }), let r = bandEventRect(b, g, anim: g.monthAnim) else { return }
        // Let the field extend right to the content edge (like the title's overflow), not
        // just the box width.
        onEditBand?(id, CGRect(x: r.x, y: r.y, width: max(r.w, g.vp.w - r.x), height: r.h))
    }
    /// Tooltip when the cursor is over a fully-overlapping-events warning sign (top-left of
    /// the kept band). Fully overlapping = same month/track/startDay/endDay.
    public func bandWarningTooltip(at p: CGPoint) -> String? {
        var groups: [String: [BandEvent]] = [:]
        for b in items.bands { groups["\(b.month)-\(b.track)-\(b.startDay)-\(b.endDay)", default: []].append(b) }
        let g = snapshot()
        for (_, arr) in groups where arr.count > 1 {
            guard let keep = arr.max(by: { $0.id < $1.id }), let r = bandEventRect(keep, g, anim: g.monthAnim) else { continue }
            if CGRect(x: r.x, y: r.y, width: 18, height: 18).contains(p) { return "Fully overlapping events" }
        }
        return nil
    }

    public func setBandTitle(_ id: String, _ title: String) {
        guard let i = items.bands.firstIndex(where: { $0.id == id }), items.bands[i].title != title else { return }
        beginTxn(); items.bands[i].title = title; scheduleCommit()
    }

    public func event(_ id: String) -> TimedEvent? { items.events.first { $0.id == id } ?? importedEvents.first { $0.id == id } }
    public func band(_ id: String) -> BandEvent? { items.bands.first { $0.id == id } ?? importedBands.first { $0.id == id } }
    public func deadline(_ id: String) -> Deadline? { items.deadlines.first { $0.id == id } }
    /// Whether a source id still backs a real item — used by the UI to close a drawer whose event just
    /// vanished (e.g. deleted in Apple Calendar, then re-imported; or removed by an iCloud remote change).
    public func itemExists(_ id: String) -> Bool { event(id) != nil || band(id) != nil || deadline(id) != nil }
}
