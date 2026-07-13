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
    public private(set) var trackNames = Array(repeating: TRACKS.map { $0.name }, count: 12)  // per month
    public var trackEditing = false        // an inline track-name field is open (freezes scroll)
    public let chrome = CalendarChrome()   // breadcrumb state for the toolbar

    public private(set) var selectedId: String?
    public private(set) var hoveredEventId: String?   // band/timed/deadline under the cursor

    private var tween: Tween?
    private var weekTween: Tween?
    private var snapWork: DispatchWorkItem?
    private var wheelAccumX: CGFloat = 0
    // Year-view scroll is driven by a real NSScrollView (native elastic bounce + momentum).
    // The input bridge forwards wheel events to it and mirrors its offset back here via
    // setYearScroll(_:); onSetYearScroll moves it programmatically (flip / year switch).
    public var onSetYearScroll: ((CGFloat) -> Void)?
    public var onEditBand: ((_ id: String, _ rect: CGRect) -> Void)?   // open inline title editor
    public var bandEditing = false        // an inline band-title field is open (freezes scroll)
    private var didInitialScroll = false     // center the current month once, at first layout
    private var liveScrolling = false        // fingers-down phase of a trackpad gesture
    private var startedAtTop = false         // the drag began already resting at an edge —
    private var startedAtBottom = false      // only then does an overscroll pull arm a flip
    private var lastOverscroll: (over: CGFloat, atTop: Bool) = (0, false)
    private var yearPull: YearPull?          // pull-to-change-year hint (nil when not pulling)
    public var yearFlipEnabled = true        // gate the prev/next-year flip
    // Year-flip transition: outgoing year scrolls out + fades, then the incoming year
    // slides in from the opposite edge + fades in. Driven by the per-frame clock.
    private struct FlipAnim { var dir: Int; var fromYear: Int; var toYear: Int; var startScroll: CGFloat; var start: Date }
    private var flipAnim: FlipAnim?
    public private(set) var flipFade: CGFloat = 1
    public var isFlipping: Bool { flipAnim != nil }
    private let FLIP_DUR: TimeInterval = 1.0
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
        seedEvents = Self.makeSeeds(year: year, month: focus, day: c.day ?? 15)
        seedBands = Self.makeSeedBands(year: year, month: focus)
        seedDeadlines = Self.makeSeedDeadlines(year: year, month: focus, day: c.day ?? 15)
        // self is now fully initialized — restore persisted edits over the seeds.
        if let s = store.load() {
            seedEvents = s.events; seedBands = s.bands; seedDeadlines = s.deadlines
            if let names = s.monthTrackNames, names.count == 12, names.allSatisfy({ $0.count == 4 }) { trackNames = names }
        } else {
            persistNow()   // seed the store on first launch
        }
        nowTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        pushChrome()
    }

    // ── Persistence ─────────────────────────────────────────────────────────────
    private func persistNow() { store.save(PersistedState(events: seedEvents, bands: seedBands, deadlines: seedDeadlines, monthTrackNames: trackNames)) }

    // ── Track names (editable lane labels, per month) ─────────────────────────────
    public func setTrackName(_ month: Int, _ track: Int, _ name: String) {
        guard month >= 0, month < trackNames.count, track >= 0, track < trackNames[month].count,
              trackNames[month][track] != name else { return }
        trackNames[month][track] = name
        schedulePersist()
    }

    /// Which track-name gutter slot is under the cursor (year view only): its month,
    /// track index, and geometry-space rect — used to place the inline editor.
    public func trackNameHit(at p: CGPoint) -> (month: Int, track: Int, rect: CGRect)? {
        guard isYearLevel, p.x >= Layout.mnameW, p.x <= Layout.labelW - Layout.rightPad else { return nil }
        let g = snapshot()
        for m in 0..<12 {
            let f = frameFor(m, g)
            if f.opacity < 0.05 { continue }
            for i in 0..<4 {
                let y = f.bandY + CGFloat(i) * f.trackH
                if p.y >= y, p.y < y + f.trackH {
                    return (m, i, CGRect(x: Layout.mnameW, y: y, width: Layout.labelW - Layout.mnameW - Layout.rightPad, height: f.trackH))
                }
            }
        }
        return nil
    }
    private func schedulePersist() {
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistNow() }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // ── Frame snapshot ──────────────────────────────────────────────────────────
    private func snapshot() -> SceneInput {
        SceneInput(z: z, focus: focus, week: week, vp: viewport, scrollY: scrollY, tlScroll: tlScroll,
                   now: now, year: year, hover: hover, weekHourH: weekHourH, daily: daily,
                   yearPull: yearPull, flipFade: flipFade)
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
        if let fa = flipAnim { advanceFlip(fa, at: date) }
        return snapshot()
    }

    public func setViewport(_ size: CGSize) {
        viewport = Viewport(w: size.width - Layout.padLeft - Layout.padRight, h: size.height)
        if !didInitialScroll, viewport.h > 1 {
            didInitialScroll = true          // once: center today's month (clamped to top/bottom).
            scrollY = clamp(centerScroll(for: focus), 0, yearMaxScroll(viewport))
            // The driver is synced by CatcherView.layout after it sizes the document view.
        } else {
            scrollY = clamp(scrollY, 0, yearMaxScroll(viewport))
        }
    }

    /// Scroll offset that vertically centers month `m`'s band; caller clamps to range.
    private func centerScroll(for m: Int) -> CGFloat {
        yearFrame(m, viewport, 0).bandY + 2 * Layout.trackH - viewport.h / 2
    }

    // ── Year selection (breadcrumb picker) ────────────────────────────────────────
    /// Selectable years: 2024 … systemYear+3, matching the web (CalendarCanvas.tsx).
    public var yearOptions: [Int] { Array(2024...(systemYear + 3)) }

    /// Zoom back out to the yearly view (breadcrumb "Year" crumb from a deeper level).
    public func zoomToYear() { tweenZ(to: 0) }

    /// Jump to another calendar year. Resets vertical scroll to the top, like the web's selectYear.
    public func selectYear(_ y: Int) {
        guard y != year else { return }
        year = y
        scrollY = 0
        onSetYearScroll?(0)   // keep the scroll-view driver in sync
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
        let b = level(z)
        if b == 0 {                                // fallback; the NSScrollView normally drives year scroll
            setYearScroll(clamp(scrollY - dy, 0, yearMaxScroll(viewport)))
            return
        }
        cancelTween()
        if abs(dy) >= abs(dx) {
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
                daily.dom = min(daysInMonth(year, focus), max(1, daily.dom + (wheelAccumX < 0 ? 1 : -1)))  // swipe-left → next day
                wheelAccumX = 0
            }
        }
        pushChrome()
    }

    // ── Year-view scroll: mirror of the native NSScrollView driver ───────────────────
    public var isYearLevel: Bool { level(z) == 0 }

    /// Fingers-down phase begins. Record whether we were already resting at an edge —
    /// a flip is only allowed for a pull that STARTS from the edge (not a fast scroll
    /// from the middle that happens to overshoot into it).
    public func beginYearScrollGesture() {
        liveScrolling = true
        let maxY = yearMaxScroll(viewport)
        startedAtTop = scrollY <= 2
        startedAtBottom = scrollY >= maxY - 2
    }

    /// Mirror the scroll view's live offset (may be < 0 or > maxScroll during elastic
    /// overscroll, which is exactly what gives the native bounce). Computes the pull
    /// hint only while a finger-driven gesture is live.
    public func setYearScroll(_ y: CGFloat) {
        scrollY = y
        let maxY = yearMaxScroll(viewport)
        let over: CGFloat = y < 0 ? -y : (y > maxY ? y - maxY : 0)
        let atTop = y < 0
        lastOverscroll = (over, atTop)
        if liveScrolling, over > 2 {
            let eligible = (atTop && startedAtTop) || (!atTop && startedAtBottom)
            let target = atTop ? year - 1 : year + 1
            yearPull = eligible
                ? YearPull(targetYear: target, atTop: atTop, over: over, armed: over >= Layout.yearFlipOver) : nil
        } else {
            yearPull = nil
        }
    }

    /// Fingers lifted — if the pull passed the threshold, flip the year (landing on the
    /// continuous edge: prev→bottom, next→top). Otherwise the scroll view bounces back
    /// natively and we do nothing.
    public func endYearScrollGesture() {
        liveScrolling = false
        yearPull = nil
        guard yearFlipEnabled, !isFlipping else { return }
        let (over, atTop) = lastOverscroll
        guard over >= Layout.yearFlipOver else { return }
        guard (atTop && startedAtTop) || (!atTop && startedAtBottom) else { return }  // must start from the edge
        let dir = atTop ? -1 : 1
        let target = year + dir            // unbounded — flip any number of years
        flipAnim = FlipAnim(dir: dir, fromYear: year, toYear: target, startScroll: scrollY, start: Date())
    }

    /// Two-phase year-flip transition, evaluated per frame. Phase 1: the outgoing year
    /// keeps scrolling in the pull direction (off-screen) and fades out. Phase 2: the
    /// incoming year slides in from the opposite edge and fades in to its resting edge
    /// (next → Jan at top; prev → Dec at bottom).
    private func advanceFlip(_ fa: FlipAnim, at date: Date) {
        let vpH = viewport.h
        let maxY = yearMaxScroll(viewport)
        let dir = CGFloat(fa.dir)
        let rest: CGFloat = fa.dir > 0 ? 0 : maxY        // where the new year settles
        let t = clamp(CGFloat(date.timeIntervalSince(fa.start) / FLIP_DUR), 0, 1)
        if t >= 1 {
            year = fa.toYear; scrollY = rest; flipFade = 1; flipAnim = nil
            pushChrome(); onSetYearScroll?(rest)         // resync the scroll-view driver
            return
        }
        if t < 0.5 {                                     // outgoing year exits + fades
            let p = t / 0.5
            if year != fa.fromYear { year = fa.fromYear; pushChrome() }
            scrollY = fa.startScroll + dir * easeInOut(p) * vpH
            flipFade = 1 - p
        } else {                                         // incoming year enters + fades
            let p = (t - 0.5) / 0.5
            if year != fa.toYear { year = fa.toYear; pushChrome() }
            let enter = rest - dir * vpH                 // from the opposite edge (off-screen)
            scrollY = enter + (rest - enter) * easeOut(p)
            flipFade = p
        }
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
            // Whole band row (incl. the gutter: track names + month name), so a pinch
            // starting over the labels still focuses that month.
            if let m = monthRowAtPoint(p.x, p.y, g) { focus = m }
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
        // 1. all-day bands (on the lanes) — selectable at every zoom incl. year view
        if let hit = bandAt(p, g) {
            selectedId = hit.id
            drag = Drag(kind: hit.zone, startPoint: p, eventId: hit.id,
                        origBand: seedBands.first { $0.id == hit.id }, priorSelection: prior)
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
        if let slot = bandSlotAtPoint(p.x, p.y, g) {   // empty lane, any zoom incl. year view
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
            case .bandMove:
                // click the body of an ALREADY-selected band → edit its title inline
                if d.priorSelection == d.eventId, let id = d.eventId { editBand(id) }
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
        // a freshly drag-created band → open its title editor so the name is focused for typing
        if d.kind == .bandCreate, let id = d.eventId, seedBands.contains(where: { $0.id == id }) {
            editBand(id)
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
        if let h = bandAt(p, g) { return h.id }
        if z >= 1.5, let h = eventAt(p, g) { return h.id }
        if z >= 1.5, let id = deadlineAt(p, g) { return id }
        return nil
    }
    /// Open the inline title editor for a band, positioned over its rect (geometry space).
    private func editBand(_ id: String) {
        let g = snapshot()
        guard let b = seedBands.first(where: { $0.id == id }), let r = bandEventRect(b, g, anim: g.monthAnim) else { return }
        // Let the field extend right to the content edge (like the title's overflow), not
        // just the box width.
        onEditBand?(id, CGRect(x: r.x, y: r.y, width: max(r.w, g.vp.w - r.x), height: r.h))
    }
    /// Tooltip when the cursor is over a fully-overlapping-events warning sign (top-left of
    /// the kept band). Fully overlapping = same month/track/startDay/endDay.
    public func bandWarningTooltip(at p: CGPoint) -> String? {
        var groups: [String: [BandEvent]] = [:]
        for b in seedBands { groups["\(b.month)-\(b.track)-\(b.startDay)-\(b.endDay)", default: []].append(b) }
        let g = snapshot()
        for (_, arr) in groups where arr.count > 1 {
            guard let keep = arr.max(by: { $0.id < $1.id }), let r = bandEventRect(keep, g, anim: g.monthAnim) else { continue }
            if CGRect(x: r.x, y: r.y, width: 18, height: 18).contains(p) { return "Fully overlapping events" }
        }
        return nil
    }

    public func setBandTitle(_ id: String, _ title: String) {
        guard let i = seedBands.firstIndex(where: { $0.id == id }), seedBands[i].title != title else { return }
        beginTxn(); seedBands[i].title = title; scheduleCommit()
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
            if dailyFade(relDomOf(year, focus, e.month, e.day) ?? -999, g) <= 0.02 { continue }
            let sameDay = seedEvents.filter { $0.month == e.month && $0.day == e.day }
            guard let r = eventRect(e, year, focus, tl, g.vp, layoutDay(sameDay)[e.id]) else { continue }
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
        guard let dom = domOpt, let r = resolveDate(year, focus, dom) else { return nil }
        return (r.month, r.day, snap(hf, 30))
    }

    private func applyMove(_ d: Drag, _ p: CGPoint, _ tl: TimelineInfo) {
        guard let orig = d.orig, let idx = seedEvents.firstIndex(where: { $0.id == d.eventId }) else { return }
        beginTxn()
        let dur = orig.endHour - orig.startHour
        let ns = max(0, min(24 - dur, snap(orig.startHour + (p.y - d.startPoint.y) / tl.hourH, 15)))
        var ev = seedEvents[idx]
        ev.startHour = ns; ev.endHour = ns + dur
        if let dom = pointToSlot(p.x, p.y, tl).dom, let r = resolveDate(year, focus, dom) { ev.month = r.month; ev.day = r.day }
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
        // Return the TOP-most band under the cursor, matching the draw order: selected and
        // hovered are raised to the front; otherwise later start > shorter length > higher id.
        func tier(_ b: BandEvent) -> Int { b.id == selectedId ? 2 : (b.id == hoveredEventId ? 1 : 0) }
        var best: (b: BandEvent, r: BandRect, rect: CGRect)?
        for b in seedBands {
            guard let r = bandEventRect(b, g, anim: g.monthAnim) else { continue }
            let rect = CGRect(x: r.x, y: r.y, width: r.w, height: r.h)
            guard rect.contains(p) else { continue }
            guard let cur = best else { best = (b, r, rect); continue }
            let tb = tier(b), tc = tier(cur.b)
            let onTop: Bool
            if tb != tc { onTop = tb > tc }
            else {
                let bl = b.endDay - b.startDay, cl = cur.b.endDay - cur.b.startDay
                onTop = b.startDay > cur.b.startDay
                    || (b.startDay == cur.b.startDay && bl < cl)
                    || (b.startDay == cur.b.startDay && bl == cl && b.id > cur.b.id)
            }
            if onTop { best = (b, r, rect) }
        }
        guard let bb = best else { return nil }
        // Edges only resize when the band is already selected; otherwise it's a move/select.
        let zone: PointerKind = bb.b.id == selectedId
            ? ((p.x - bb.rect.minX < 6 && !bb.r.clipStart) ? .bandResizeL
               : (bb.rect.maxX - p.x < 6 && !bb.r.clipEnd ? .bandResizeR : .bandMove))
            : .bandMove
        return (bb.b.id, zone)
    }

    private func applyBandMove(_ d: Drag, _ p: CGPoint, _ g: SceneInput) {
        guard let orig = d.origBand, let idx = seedBands.firstIndex(where: { $0.id == d.eventId }),
              let slot = bandSlotAtPoint(p.x, p.y, g) else { return }   // follow the lane under the cursor
        beginTxn()
        let len = orig.endDay - orig.startDay
        // Keep the grab offset (day within the band where the drag started), so a band can be
        // dragged across months/tracks in year view — not just within its own month.
        let grab = (bandSlotAtPoint(d.startPoint.x, d.startPoint.y, g)?.day ?? orig.startDay) - orig.startDay
        let start = max(1, min(daysInMonth(year, slot.month) - len, slot.day - grab))
        var b = seedBands[idx]
        b.month = slot.month; b.track = slot.track; b.startDay = start; b.endDay = start + len
        seedBands[idx] = b
    }

    private func applyBandResize(_ d: Drag, _ p: CGPoint, _ g: SceneInput, left: Bool) {
        guard let orig = d.origBand, let idx = seedBands.firstIndex(where: { $0.id == d.eventId }) else { return }
        beginTxn()
        let day = max(1, min(daysInMonth(year, orig.month), bandDay(p.x, orig.month, g)))
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
        let cur = max(1, min(daysInMonth(year, mo), bandDay(p.x, mo, g)))
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
        if let dom = domOpt, let r = resolveDate(year, focus, dom) { dd.month = r.month; dd.day = r.day }
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
        // Hover stickiness: if the cursor is still inside the currently-hovered event,
        // keep it — so moving into an overlap doesn't hand the highlight to the event
        // underneath. Only when the cursor leaves it do we re-pick the topmost.
        if let cur = hoveredEventId, bandContains(cur, p, g) || timedContains(cur, p, g) {
            // keep hoveredEventId
        } else if let b = bandAt(p, g) { hoveredEventId = b.id }
        else if z >= 1.5, let e = eventAt(p, g) { hoveredEventId = e.id }
        else if z >= 1.5, let d = deadlineAt(p, g) { hoveredEventId = d }
        else { hoveredEventId = nil }
        hover = hv
    }

    private func bandContains(_ id: String, _ p: CGPoint, _ g: SceneInput) -> Bool {
        guard let b = seedBands.first(where: { $0.id == id }), let r = bandEventRect(b, g, anim: g.monthAnim) else { return false }
        return CGRect(x: r.x, y: r.y, width: r.w, height: r.h).contains(p)
    }
    private func timedContains(_ id: String, _ p: CGPoint, _ g: SceneInput) -> Bool {
        guard z >= 1.5, let e = seedEvents.first(where: { $0.id == id }) else { return false }
        let tl = timelineInfo(g)
        guard tl.reveal > 0.05, tl.hourH > 0 else { return false }
        let sameDay = seedEvents.filter { $0.month == e.month && $0.day == e.day }
        guard let r = eventRect(e, year, focus, tl, g.vp, layoutDay(sameDay)[e.id]) else { return false }
        return CGRect(x: r.minX, y: tl.tlTop - tl.scroll + r.minY, width: r.width, height: r.height).contains(p)
    }

    public func onHoverExit() { hover = .none; hoveredEventId = nil }

    public enum CursorHint { case normal, grab, create, resizeLR }
    public func cursorHint(at p: CGPoint) -> CursorHint {
        let g = snapshot()
        if let hit = bandAt(p, g) {
            return (hit.zone == .bandResizeL || hit.zone == .bandResizeR) ? .resizeLR : .grab
        }
        if z >= 1.5 {
            if eventAt(p, g) != nil { return .grab }
            if deadlineAt(p, g) != nil { return .grab }
            if createSpot(at: p, g) != nil { return .create }
        }
        if bandSlotAtPoint(p.x, p.y, g) != nil { return .create }
        return .normal
    }

    // ── Seed data (display only, until the sync layer lands) ─────────────────────
    private static func makeSeeds(year: Int, month: Int, day: Int) -> [TimedEvent] {
        let d0 = max(1, min(daysInMonth(year, month) - 2, day))
        return [
            TimedEvent(id: "s1", month: month, day: d0, startHour: 9, endHour: 10, title: "Standup", color: "blue"),
            TimedEvent(id: "s2", month: month, day: d0, startHour: 11, endHour: 12.5, title: "Design review", color: "green"),
            TimedEvent(id: "s3", month: month, day: d0, startHour: 11.5, endHour: 13, title: "1:1 with Alex", color: "yellow"),
            TimedEvent(id: "s4", month: month, day: d0, startHour: 14, endHour: 15, title: "Lecture", color: "red"),
            TimedEvent(id: "s5", month: month, day: min(daysInMonth(year, month), d0 + 1), startHour: 10, endHour: 11.5, title: "Research sync", color: "blue"),
            TimedEvent(id: "s6", month: month, day: min(daysInMonth(year, month), d0 + 1), startHour: 16, endHour: 18, title: "Seminar", color: "purple"),
        ]
    }

    private static func makeSeedBands(year: Int, month: Int) -> [BandEvent] {
        let dim = daysInMonth(year, month)
        func clampD(_ d: Int) -> Int { max(1, min(dim, d)) }
        return [
            BandEvent(id: "b1", year: year, month: month, track: 0, startDay: clampD(3), endDay: clampD(7), title: "Intro to AI", color: "red"),
            BandEvent(id: "b2", year: year, month: month, track: 1, startDay: clampD(10), endDay: clampD(14), title: "NSF grant", color: "blue"),
            BandEvent(id: "b3", year: year, month: month, track: 3, startDay: clampD(18), endDay: clampD(21), title: "Conf travel", color: "green"),
        ]
    }

    private static func makeSeedDeadlines(year: Int, month: Int, day: Int) -> [Deadline] {
        let d0 = max(1, min(daysInMonth(year, month), day))
        return [
            Deadline(id: "d1", year: year, month: month, day: d0, hour: 17, title: "Paper due", color: "red"),
            Deadline(id: "d2", year: year, month: month, day: min(daysInMonth(year, month), d0 + 2), hour: 12.5, title: "Reviews", color: "purple"),
        ]
    }
}
