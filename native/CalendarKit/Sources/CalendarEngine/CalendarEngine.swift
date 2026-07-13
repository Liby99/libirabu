// The mutable view-state + tween clock. Geometry is stateless; this is where z,
// focus, week, scroll, hover, and the animation live. SwiftUI observes it directly.

import Foundation
import CoreGraphics
import CalendarGeometry

// Plain reference type (not @Observable): the view redraws every frame via
// TimelineView(.animation), which reads a fresh SceneInput and advances the tween
// from the display clock — so observation isn't needed and can't cause update loops.
@MainActor
public final class CalendarEngine {
    // View state
    public private(set) var z: CGFloat = 0
    public private(set) var focus: Int
    public private(set) var week: CGFloat = 0
    public private(set) var scrollY: CGFloat = 0
    public private(set) var tlScroll: CGFloat = 0
    public private(set) var daily: DailyState
    public private(set) var hover: Hover = .none
    public private(set) var year: Int
    public let systemYear: Int          // the real "today" year at launch — anchors the picker range
    public private(set) var now: Date = Date()
    public var weekHourH: CGFloat = 60
    public private(set) var viewport: Viewport = Viewport(w: 1, h: 1)
    public private(set) var seedEvents: [TimedEvent] = []
    public private(set) var seedBands: [BandEvent] = []
    public private(set) var seedDeadlines: [Deadline] = []
    public let trackNames = TRACKS.map { $0.name }
    public let chrome = CalendarChrome()   // breadcrumb state for the toolbar

    public private(set) var selectedId: String?

    private var tween: Tween?
    private var weekTween: Tween?
    private var snapWork: DispatchWorkItem?
    private var wheelAccumX: CGFloat = 0
    // pinch state
    private var magStartZ: CGFloat = 0
    private var magAccum: CGFloat = 0
    private var nowTimer: Timer?
    // pointer / editing state
    private var drag: Drag?
    private var createCounter = 0
    // undo / redo (whole-state snapshots, coalesced per gesture / typing burst)
    private struct EditState: Equatable { var events: [TimedEvent]; var bands: [BandEvent]; var deadlines: [Deadline] }
    private var editState: EditState { EditState(events: seedEvents, bands: seedBands, deadlines: seedDeadlines) }
    private var undoStack: [EditState] = []
    private var redoStack: [EditState] = []
    private var pendingUndo: EditState?
    private var undoWork: DispatchWorkItem?
    private let store = ItemStore()
    private var persistWork: DispatchWorkItem?

    private enum PointerKind {
        case navigate, move, resizeTop, resizeBottom, create           // timed
        case bandMove, bandResizeL, bandResizeR, bandCreate            // all-day bands
        case ddlMove                                                   // deadlines
    }
    private struct Drag {
        var kind: PointerKind
        var startPoint: CGPoint
        var eventId: String? = nil
        var orig: TimedEvent? = nil
        var anchorHour: CGFloat? = nil
        var createMonth: Int? = nil
        var createDay: Int? = nil
        var origBand: BandEvent? = nil
        var bandMonth: Int? = nil
        var bandTrack: Int? = nil
        var bandAnchorDay: Int? = nil
        var origDdl: Deadline? = nil
        var priorSelection: String? = nil   // selection at down → deselect-vs-navigate on a plain click
        var activated = false
    }

    private let ZOOM_DUR: TimeInterval = 0.52
    private let PINCH_SENS: CGFloat = 1.6

    public init() {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        year = c.year ?? 2026
        systemYear = c.year ?? 2026
        focus = (c.month ?? 1) - 1
        daily = DailyState(dom: c.day ?? 1, frac: 0.45)
        seedEvents = Self.makeSeeds(month: focus, day: c.day ?? 15)
        seedBands = Self.makeSeedBands(year: year, month: focus)
        seedDeadlines = Self.makeSeedDeadlines(year: year, month: focus, day: c.day ?? 15)
        // self is now fully initialized — restore persisted edits over the seeds.
        if let s = store.load() {
            seedEvents = s.events; seedBands = s.bands; seedDeadlines = s.deadlines
        } else {
            persistNow()   // seed the store on first launch
        }
        nowTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        pushChrome()
    }

    // ── Persistence ─────────────────────────────────────────────────────────────
    private func persistNow() { store.save(PersistedState(events: seedEvents, bands: seedBands, deadlines: seedDeadlines)) }
    private func schedulePersist() {
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistNow() }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // ── Frame snapshot ──────────────────────────────────────────────────────────
    private func snapshot() -> SceneInput {
        SceneInput(z: z, focus: focus, week: week, vp: viewport, scrollY: scrollY, tlScroll: tlScroll,
                   now: now, year: year, hover: hover, weekHourH: weekHourH, daily: daily)
    }

    /// Advance the tween to `date` and return the immutable input for this frame.
    public func sceneInput(at date: Date, viewport vp: Viewport) -> SceneInput {
        viewport = vp
        if let t = tween {
            z = t.value(at: date)
            if t.isComplete(at: date) { z = t.to; tween = nil }
        }
        if let wt = weekTween {
            week = wt.value(at: date)
            if wt.isComplete(at: date) { week = wt.to; weekTween = nil }
        }
        return snapshot()
    }

    public func setViewport(_ size: CGSize) {
        viewport = Viewport(w: size.width - Layout.padLeft - Layout.padRight, h: size.height)
        scrollY = clamp(scrollY, 0, yearMaxScroll(viewport))
    }

    // ── Year selection (breadcrumb picker) ────────────────────────────────────────
    /// Selectable years: 2024 … systemYear+3, matching the web (CalendarCanvas.tsx).
    public var yearOptions: [Int] { Array(2024...(systemYear + 3)) }

    /// Jump to another calendar year. Resets vertical scroll to the top, like the web's selectYear.
    public func selectYear(_ y: Int) {
        guard y != year else { return }
        year = y
        scrollY = 0
        pushChrome()
    }

    // ── Levels + tween helpers ────────────────────────────────────────────────────
    private func level(_ z: CGFloat) -> Int { z < 0.5 ? 0 : (z < 1.5 ? 1 : (z < 2.5 ? 2 : 3)) }

    private func pushChrome(level lvl: Int? = nil) {
        chrome.level = lvl ?? level(z)
        chrome.year = year
        chrome.focus = focus
        chrome.week = Double(week)
        chrome.dailyDom = daily.dom
    }

    private func cancelTween() {
        if let t = tween { z = t.value(at: Date()); tween = nil }
        if let wt = weekTween { week = wt.value(at: Date()); weekTween = nil }
        snapWork?.cancel()
    }

    private func scheduleWeekSnap(_ maxWeek: CGFloat) {
        snapWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let target = clamp((self.week * 7).rounded() / 7, 0, maxWeek)
            self.weekTween = Tween(from: self.week, to: target, start: Date(), duration: 0.2, ease: easeInOut)
        }
        snapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    public func tweenZ(to target: CGFloat, dur: TimeInterval? = nil) {
        tween = Tween(from: z, to: clamp(target, 0, 3), start: Date(), duration: dur ?? ZOOM_DUR, ease: easeInOut)
        pushChrome(level: level(clamp(target, 0, 3)))
    }

    // ── Gestures ──────────────────────────────────────────────────────────────────
    public func onWheel(dx: CGFloat, dy: CGFloat) {
        cancelTween()
        let b = level(z)
        if b == 0 {
            scrollY = clamp(scrollY - dy, 0, yearMaxScroll(viewport))
        } else if abs(dy) >= abs(dx) {
            let tl = timelineInfo(snapshot())
            tlScroll = min(max(0, tlScroll - dy), tl.maxScroll)
        } else if b == 2 {
            weekTween = nil
            let maxWeek = CGFloat(max(0, weeksInMonth(year, focus) - 1))
            week = clamp(week - dx / (viewport.w - Layout.labelW), 0, maxWeek)  // swipe-left → later days
            scheduleWeekSnap(maxWeek)
        } else if b == 3 {
            wheelAccumX += dx
            if abs(wheelAccumX) > 55 {
                daily.dom = min(daysInMonth(focus), max(1, daily.dom + (wheelAccumX < 0 ? 1 : -1)))  // swipe-left → next day
                wheelAccumX = 0
            }
        }
        pushChrome()
    }

    public func onMagnify(delta: CGFloat, at p: CGPoint, began: Bool, ended: Bool) {
        if began {
            cancelTween()
            magStartZ = z
            magAccum = 0
            captureFocus(at: p)
        } else if ended {
            tweenZ(to: z.rounded())
        } else {
            magAccum += delta
            z = clamp(magStartZ + magAccum * PINCH_SENS, 0, 3)
            pushChrome()
        }
    }

    private func captureFocus(at p: CGPoint) {
        let g = snapshot()
        switch level(z) {
        case 0:
            if let m = monthAtPoint(p.x, p.y, g) { focus = m }
        case 1:
            if let w = weekAtPointInMonth(p.x, g) { week = CGFloat(w) }
        case 2:
            if let d = dayAtPointInWeek(p.x, g) { focus = d.month; week = CGFloat(d.week); daily.dom = d.day }
        default: break
        }
        pushChrome()
    }

    // ── Pointer: unified down / drag / up ────────────────────────────────────────
    // A plain click (down+up, no movement) navigates (drills in). A drag creates,
    // moves, or resizes an event depending on what's under the cursor at down.
    public func onPointerDown(at p: CGPoint) {
        commitTxn()   // flush any pending (e.g. drawer typing) before a new gesture
        cancelTween()
        let g = snapshot()
        let prior = selectedId   // decide deselect-vs-navigate on a plain click (see onPointerUp)
        // 1. all-day bands (on the lanes) — month view onward
        if z >= 1, let hit = bandAt(p, g) {
            selectedId = hit.id
            drag = Drag(kind: hit.zone, startPoint: p, eventId: hit.id, origBand: seedBands.first { $0.id == hit.id })
            return
        }
        // 2. timed events (on the timeline)
        if z >= 1.5, let hit = eventAt(p, g) {
            selectedId = hit.id
            drag = Drag(kind: hit.zone, startPoint: p, eventId: hit.id, orig: seedEvents.first { $0.id == hit.id })
            return
        }
        // 3. deadlines (on the timeline)
        if z >= 1.5, let id = deadlineAt(p, g) {
            selectedId = id
            drag = Drag(kind: .ddlMove, startPoint: p, eventId: id, origDdl: seedDeadlines.first { $0.id == id })
            return
        }
        // 4. empty timeline → a DRAG creates; a plain click deselects (if something was
        //    selected) or navigates. Selection is cleared on up (not now) so the drag
        //    can still create.
        if z >= 1.5, let spot = createSpot(at: p, g) {
            drag = Drag(kind: .create, startPoint: p, anchorHour: spot.anchor, createMonth: spot.month, createDay: spot.day, priorSelection: prior)
            return
        }
        // 5. empty lane → band create (drag) / deselect / navigate
        if z >= 1, let slot = bandSlotAtPoint(p.x, p.y, g) {
            drag = Drag(kind: .bandCreate, startPoint: p, bandMonth: slot.month, bandTrack: slot.track, bandAnchorDay: slot.day, priorSelection: prior)
            return
        }
        drag = Drag(kind: .navigate, startPoint: p, priorSelection: prior)
    }

    public func onPointerDrag(at p: CGPoint) {
        guard var d = drag else { return }
        if !d.activated {
            if hypot(p.x - d.startPoint.x, p.y - d.startPoint.y) < 3 { return }
            d.activated = true
            drag = d
        }
        let g = snapshot()
        let tl = timelineInfo(g)
        switch d.kind {
        case .navigate: break
        case .move: applyMove(d, p, tl)
        case .resizeTop: applyResize(d, p, tl, top: true)
        case .resizeBottom: applyResize(d, p, tl, top: false)
        case .create: applyCreate(p, tl)
        case .bandMove: applyBandMove(d, p, g)
        case .bandResizeL: applyBandResize(d, p, g, left: true)
        case .bandResizeR: applyBandResize(d, p, g, left: false)
        case .bandCreate: applyBandCreate(p, g)
        case .ddlMove: applyDdlMove(d, p, g)
        }
    }

    public func onPointerUp(at p: CGPoint) {
        defer { commitTxn(); drag = nil }   // one undo entry per drag
        guard let d = drag else { return }
        // Plain click (no drag) in empty space (create/band-create primed, or navigate):
        // deselect if something was selected, otherwise navigate (drill in).
        if !d.activated {
            switch d.kind {
            case .create, .bandCreate, .navigate:
                if d.priorSelection != nil { selectedId = nil } else { navigate(at: p) }
            default:
                break
            }
            return
        }
        // discard a too-small created timed event
        if d.kind == .create, let id = d.eventId, let e = seedEvents.first(where: { $0.id == id }), e.endHour - e.startHour < 0.25 {
            seedEvents.removeAll { $0.id == id }
            if selectedId == id { selectedId = nil }
        }
    }

    public func deleteSelected() {
        guard let id = selectedId else { return }
        beginTxn()
        seedEvents.removeAll { $0.id == id }
        seedBands.removeAll { $0.id == id }
        seedDeadlines.removeAll { $0.id == id }
        selectedId = nil
        commitTxn()
    }

    // ── Undo / redo ───────────────────────────────────────────────────────────────
    private func beginTxn() { if pendingUndo == nil { pendingUndo = editState } }
    private func commitTxn() {
        undoWork?.cancel(); undoWork = nil
        guard let snap = pendingUndo else { return }
        pendingUndo = nil
        guard snap != editState else { return }     // no-op edit → no entry
        undoStack.append(snap)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        schedulePersist()
    }
    private func scheduleCommit() {                    // coalesce a typing burst
        undoWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.commitTxn() }
        undoWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
    private func restore(_ s: EditState) { seedEvents = s.events; seedBands = s.bands; seedDeadlines = s.deadlines; selectedId = nil; schedulePersist() }
    public var canUndo: Bool { !undoStack.isEmpty || pendingUndo != nil }
    public var canRedo: Bool { !redoStack.isEmpty }
    public func undo() {
        commitTxn()
        guard let snap = undoStack.popLast() else { return }
        redoStack.append(editState)
        restore(snap)
    }
    public func redo() {
        guard let snap = redoStack.popLast() else { return }
        undoStack.append(editState)
        restore(snap)
    }

    // ── Drawer support ──────────────────────────────────────────────────────────
    /// Any item (band / timed / deadline) under the point — for double-click to open.
    public func itemId(at p: CGPoint) -> String? {
        let g = snapshot()
        if z >= 1, let h = bandAt(p, g) { return h.id }
        if z >= 1.5, let h = eventAt(p, g) { return h.id }
        if z >= 1.5, let id = deadlineAt(p, g) { return id }
        return nil
    }
    public func event(_ id: String) -> TimedEvent? { seedEvents.first { $0.id == id } }
    public func band(_ id: String) -> BandEvent? { seedBands.first { $0.id == id } }
    public func deadline(_ id: String) -> Deadline? { seedDeadlines.first { $0.id == id } }

    public func update(_ id: String, _ mutate: (inout TimedEvent) -> Void) {
        guard let i = seedEvents.firstIndex(where: { $0.id == id }) else { return }
        beginTxn(); mutate(&seedEvents[i]); scheduleCommit()
    }
    public func updateBand(_ id: String, _ mutate: (inout BandEvent) -> Void) {
        guard let i = seedBands.firstIndex(where: { $0.id == id }) else { return }
        beginTxn(); mutate(&seedBands[i]); scheduleCommit()
    }
    public func updateDeadline(_ id: String, _ mutate: (inout Deadline) -> Void) {
        guard let i = seedDeadlines.firstIndex(where: { $0.id == id }) else { return }
        beginTxn(); mutate(&seedDeadlines[i]); scheduleCommit()
    }
    public func remove(_ id: String) {
        beginTxn()
        seedEvents.removeAll { $0.id == id }
        seedBands.removeAll { $0.id == id }
        seedDeadlines.removeAll { $0.id == id }
        if selectedId == id { selectedId = nil }
        commitTxn()
    }

    private func navigate(at p: CGPoint) {
        let g = snapshot()
        switch level(z) {
        case 0:
            if let m = monthAtPoint(p.x, p.y, g) ?? monthNameAtPoint(p.x, p.y, g) { focus = m; tweenZ(to: 1) }
        case 1:
            if let w = weekAtPointInMonth(p.x, g) { week = CGFloat(w); tweenZ(to: 2) }
        case 2:
            if let d = dayAtPointInWeek(p.x, g) { focus = d.month; week = CGFloat(d.week); daily.dom = d.day; tweenZ(to: 3) }
        default: break
        }
    }

    // ── Editing helpers ───────────────────────────────────────────────────────────
    private func snap(_ h: CGFloat, _ stepMin: CGFloat) -> CGFloat {
        let step = stepMin / 60
        return max(0, min(24, (h / step).rounded() * step))
    }

    /// Topmost event under the cursor + which zone (body vs top/bottom resize edge).
    private func eventAt(_ p: CGPoint, _ g: SceneInput) -> (id: String, zone: PointerKind)? {
        let tl = timelineInfo(g)
        guard tl.reveal > 0.05, tl.hourH > 0 else { return nil }
        if z > 2 && p.x >= tl.x0 + CGFloat(daily.dom) * tl.colW { return nil }  // under dashboard
        var found: (String, PointerKind)?
        for e in seedEvents {
            if dailyFade(relDomOf(focus, e.month, e.day) ?? -999, g) <= 0.02 { continue }
            let sameDay = seedEvents.filter { $0.month == e.month && $0.day == e.day }
            guard let r = eventRect(e, focus, tl, g.vp, layoutDay(sameDay)[e.id]) else { continue }
            let rect = CGRect(x: r.minX, y: tl.tlTop - tl.scroll + r.minY, width: r.width, height: r.height)
            if rect.contains(p) {
                let zone: PointerKind = (p.y - rect.minY < 5) ? .resizeTop : (rect.maxY - p.y < 5 ? .resizeBottom : .move)
                found = (e.id, zone)   // keep last → topmost drawn
            }
        }
        return found
    }

    private func createSpot(at p: CGPoint, _ g: SceneInput) -> (month: Int, day: Int, anchor: CGFloat)? {
        let tl = timelineInfo(g)
        guard tl.reveal > 0.05, tl.hourH > 0, p.y >= tl.tlTop, p.y <= tl.tlBottom else { return nil }
        if z > 2 && p.x >= tl.x0 + CGFloat(daily.dom) * tl.colW { return nil }
        let (domOpt, hf) = pointToSlot(p.x, p.y, tl)
        guard let dom = domOpt, let r = resolveDate(focus, dom) else { return nil }
        return (r.month, r.day, snap(hf, 30))
    }

    private func applyMove(_ d: Drag, _ p: CGPoint, _ tl: TimelineInfo) {
        guard let orig = d.orig, let idx = seedEvents.firstIndex(where: { $0.id == d.eventId }) else { return }
        beginTxn()
        let dur = orig.endHour - orig.startHour
        let ns = max(0, min(24 - dur, snap(orig.startHour + (p.y - d.startPoint.y) / tl.hourH, 15)))
        var ev = seedEvents[idx]
        ev.startHour = ns; ev.endHour = ns + dur
        if let dom = pointToSlot(p.x, p.y, tl).dom, let r = resolveDate(focus, dom) { ev.month = r.month; ev.day = r.day }
        seedEvents[idx] = ev
    }

    private func applyResize(_ d: Drag, _ p: CGPoint, _ tl: TimelineInfo, top: Bool) {
        guard let idx = seedEvents.firstIndex(where: { $0.id == d.eventId }) else { return }
        beginTxn()
        let hf = pointToSlot(p.x, p.y, tl).hourFrac
        var ev = seedEvents[idx]
        if top { ev.startHour = min(ev.endHour - 0.25, snap(hf, 15)) }
        else { ev.endHour = max(ev.startHour + 0.25, snap(hf, 15)) }
        seedEvents[idx] = ev
    }

    private func applyCreate(_ p: CGPoint, _ tl: TimelineInfo) {
        guard var d = drag else { return }
        beginTxn()   // snapshot pre-create so undo removes the new event
        if d.eventId == nil {
            guard let mo = d.createMonth, let dy = d.createDay, let a = d.anchorHour else { return }
            createCounter += 1
            let id = "new-\(createCounter)"
            seedEvents.append(TimedEvent(id: id, month: mo, day: dy, startHour: a, endHour: min(24, a + 0.25), title: "New event", color: "blue"))
            d.eventId = id; drag = d; selectedId = id
        }
        guard let id = d.eventId, let idx = seedEvents.firstIndex(where: { $0.id == id }), let a = d.anchorHour else { return }
        let cur = snap(pointToSlot(p.x, p.y, tl).hourFrac, 15)
        var ev = seedEvents[idx]
        ev.startHour = min(a, cur); ev.endHour = max(a, cur)
        if ev.endHour - ev.startHour < 0.25 { ev.endHour = min(24, ev.startHour + 0.25) }
        seedEvents[idx] = ev
    }

    // ── Band + deadline editing ─────────────────────────────────────────────────
    private func bandDay(_ px: CGFloat, _ month: Int, _ g: SceneInput) -> Int {
        let f = frameFor(month, g)
        return f.dayW > 0 ? Int((px - f.x0) / f.dayW) + 1 : 1
    }

    private func bandAt(_ p: CGPoint, _ g: SceneInput) -> (id: String, zone: PointerKind)? {
        var found: (String, PointerKind)?
        for b in seedBands {
            guard let r = bandEventRect(b, g, anim: g.monthAnim) else { continue }
            let rect = CGRect(x: r.x, y: r.y, width: r.w, height: r.h)
            if rect.contains(p) {
                let zone: PointerKind = (p.x - rect.minX < 6 && !r.clipStart) ? .bandResizeL
                    : (rect.maxX - p.x < 6 && !r.clipEnd ? .bandResizeR : .bandMove)
                found = (b.id, zone)   // keep last → topmost
            }
        }
        return found
    }

    private func applyBandMove(_ d: Drag, _ p: CGPoint, _ g: SceneInput) {
        guard let orig = d.origBand, let idx = seedBands.firstIndex(where: { $0.id == d.eventId }) else { return }
        beginTxn()
        let len = orig.endDay - orig.startDay
        let delta = bandDay(p.x, orig.month, g) - bandDay(d.startPoint.x, orig.month, g)
        let ns = max(1, min(daysInMonth(orig.month) - len, orig.startDay + delta))
        var b = seedBands[idx]
        b.startDay = ns; b.endDay = ns + len
        if let slot = bandSlotAtPoint(p.x, p.y, g), slot.month == orig.month { b.track = slot.track }
        seedBands[idx] = b
    }

    private func applyBandResize(_ d: Drag, _ p: CGPoint, _ g: SceneInput, left: Bool) {
        guard let orig = d.origBand, let idx = seedBands.firstIndex(where: { $0.id == d.eventId }) else { return }
        beginTxn()
        let day = max(1, min(daysInMonth(orig.month), bandDay(p.x, orig.month, g)))
        var b = seedBands[idx]
        if left { b.startDay = min(b.endDay, day) } else { b.endDay = max(b.startDay, day) }
        seedBands[idx] = b
    }

    private func applyBandCreate(_ p: CGPoint, _ g: SceneInput) {
        guard var d = drag else { return }
        beginTxn()
        if d.eventId == nil {
            guard let mo = d.bandMonth, let tr = d.bandTrack, let a = d.bandAnchorDay else { return }
            createCounter += 1
            let id = "newb-\(createCounter)"
            seedBands.append(BandEvent(id: id, year: year, month: mo, track: tr, startDay: a, endDay: a, title: "New event", color: "blue"))
            d.eventId = id; drag = d; selectedId = id
        }
        guard let id = d.eventId, let idx = seedBands.firstIndex(where: { $0.id == id }), let mo = d.bandMonth, let a = d.bandAnchorDay else { return }
        let cur = max(1, min(daysInMonth(mo), bandDay(p.x, mo, g)))
        var b = seedBands[idx]
        b.startDay = min(a, cur); b.endDay = max(a, cur)
        seedBands[idx] = b
    }

    private func deadlineAt(_ p: CGPoint, _ g: SceneInput) -> String? {
        var hit: String?
        for d in seedDeadlines {
            guard let pos = deadlinePos(d, g) else { continue }
            if p.x >= pos.x && p.x <= pos.x + pos.w && abs(p.y - pos.y) < 8 { hit = d.id }
        }
        return hit
    }

    private func applyDdlMove(_ d: Drag, _ p: CGPoint, _ g: SceneInput) {
        guard let idx = seedDeadlines.firstIndex(where: { $0.id == d.eventId }) else { return }
        beginTxn()
        let tl = timelineInfo(g)
        let (domOpt, hf) = pointToSlot(p.x, p.y, tl)
        var dd = seedDeadlines[idx]
        dd.hour = snap(hf, 15)
        if let dom = domOpt, let r = resolveDate(focus, dom) { dd.month = r.month; dd.day = r.day }
        seedDeadlines[idx] = dd
    }

    public func onEscape() {
        cancelTween()
        tweenZ(to: CGFloat(max(0, level(z) - 1)))
    }

    public func onHover(at p: CGPoint) {
        let g = snapshot()
        var hv = Hover()
        switch level(z) {
        case 0:
            let m = monthRowAtPoint(p.x, p.y, g)
            hv.month = m
            hv.nameMonth = monthNameAtPoint(p.x, p.y, g)
            if let m { hv.dom = domInMonthBand(p.x, m, g) }
        case 1:
            hv.dom = domInFocus(p.x, g)
            hv.week = weekAtPointInMonth(p.x, g)
        default:
            // In daily view the right panel is the dashboard — no background time cursor there.
            if z > 2 {
                let f = frameFor(focus, g)
                let dashLeft = f.x0 + CGFloat(daily.dom) * f.dayW
                if p.x >= dashLeft { hover = .none; return }
            }
            let c = cellInWeek(p.x, p.y, g)
            hv.dom = c.dom; hv.hour = c.hour; hv.hourFrac = c.hourFrac; hv.nearLeft = c.nearLeft
        }
        hover = hv
    }

    public func onHoverExit() { hover = .none }

    public enum CursorHint { case normal, grab, create }
    public func cursorHint(at p: CGPoint) -> CursorHint {
        let g = snapshot()
        if z >= 1, bandAt(p, g) != nil { return .grab }
        if z >= 1.5 {
            if eventAt(p, g) != nil { return .grab }
            if deadlineAt(p, g) != nil { return .grab }
            if createSpot(at: p, g) != nil { return .create }
        }
        if z >= 1, bandSlotAtPoint(p.x, p.y, g) != nil { return .create }
        return .normal
    }

    // ── Seed data (display only, until the sync layer lands) ─────────────────────
    private static func makeSeeds(month: Int, day: Int) -> [TimedEvent] {
        let d0 = max(1, min(daysInMonth(month) - 2, day))
        return [
            TimedEvent(id: "s1", month: month, day: d0, startHour: 9, endHour: 10, title: "Standup", color: "blue"),
            TimedEvent(id: "s2", month: month, day: d0, startHour: 11, endHour: 12.5, title: "Design review", color: "green"),
            TimedEvent(id: "s3", month: month, day: d0, startHour: 11.5, endHour: 13, title: "1:1 with Alex", color: "yellow"),
            TimedEvent(id: "s4", month: month, day: d0, startHour: 14, endHour: 15, title: "Lecture", color: "red"),
            TimedEvent(id: "s5", month: month, day: min(daysInMonth(month), d0 + 1), startHour: 10, endHour: 11.5, title: "Research sync", color: "blue"),
            TimedEvent(id: "s6", month: month, day: min(daysInMonth(month), d0 + 1), startHour: 16, endHour: 18, title: "Seminar", color: "purple"),
        ]
    }

    private static func makeSeedBands(year: Int, month: Int) -> [BandEvent] {
        let dim = daysInMonth(month)
        func clampD(_ d: Int) -> Int { max(1, min(dim, d)) }
        return [
            BandEvent(id: "b1", year: year, month: month, track: 0, startDay: clampD(3), endDay: clampD(7), title: "Intro to AI", color: "red"),
            BandEvent(id: "b2", year: year, month: month, track: 1, startDay: clampD(10), endDay: clampD(14), title: "NSF grant", color: "blue"),
            BandEvent(id: "b3", year: year, month: month, track: 3, startDay: clampD(18), endDay: clampD(21), title: "Conf travel", color: "green"),
        ]
    }

    private static func makeSeedDeadlines(year: Int, month: Int, day: Int) -> [Deadline] {
        let d0 = max(1, min(daysInMonth(month), day))
        return [
            Deadline(id: "d1", year: year, month: month, day: d0, hour: 17, title: "Paper due", color: "red"),
            Deadline(id: "d2", year: year, month: month, day: min(daysInMonth(month), d0 + 2), hour: 12.5, title: "Reviews", color: "purple"),
        ]
    }
}
