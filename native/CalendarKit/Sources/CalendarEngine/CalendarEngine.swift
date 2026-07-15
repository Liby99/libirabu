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
    private var zoomAnchorHour: CGFloat?   // hour held at `zoomAnchorY` for the duration of a zoom
    private var zoomAnchorY: CGFloat?       // viewport y to hold it at (nil = viewport centre)
    private var zTweenDone: (() -> Void)?      // fires once when the current z-tween settles (phase sequencing)
    private var weekTweenDone: (() -> Void)?   // fires once when the week-scroll tween settles
    private var flipDone: (() -> Void)?        // fires once when a year-flip settles
    private var dayLandDone: (() -> Void)?     // fires once when a jumpToDay finally settles at day view
    private func fireDayLand() { if let cb = dayLandDone { dayLandDone = nil; cb() } }
    public private(set) var daily: DailyState
    public private(set) var monthAnim: PageAnim?   // vertical month↕month page-turn (nil = settled)
    public private(set) var hover: Hover = .none
    public private(set) var year: Int
    public let systemYear: Int          // the real "today" year at launch — anchors the picker range
    public var mainTz: String = "auto"  // deadline main timezone (for origin-tz labels); "auto" = device zone
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
    /// The timed event currently being moved/resized/created (an ACTIVE drag). The overlay floats it
    /// full-width above its day and excludes it from the others' overlap packing so they don't reflow
    /// mid-edit; nil at rest, so the normal side-by-side layout resumes on drop.
    public var activeTimedDragId: String? {
        guard let d = drag, d.activated else { return nil }
        switch d.kind {
        case .move, .resizeTop, .resizeBottom, .create: return d.eventId
        default: return nil
        }
    }

    private var tween: Tween?
    private var scrollTween: Tween?            // year-view vertical scroll glide (before a zoom-in)
    private var scrollTweenDone: (() -> Void)?
    private var weekTween: Tween?
    private var dayTween: Tween?   // fractional-day glide (day view "scroll to today"): drives daily.dom + anim
    // Drawer canvas-shift: while the detail drawer is open the whole calendar slides left so
    // the selected item centers in the free area beside the drawer (ports the web's
    // .cc-drawer-open .app-shell transform). Tweened per-frame like z / week.
    public private(set) var drawerShift: CGFloat = 0
    private var shiftTween: Tween?
    private let DRAWER_SHIFT_DUR: TimeInterval = 0.28
    private var snapWork: DispatchWorkItem?
    private var wheelAccumX: CGFloat = 0
    // Year-view scroll is driven by a real NSScrollView (native elastic bounce + momentum).
    // The input bridge forwards wheel events to it and mirrors its offset back here via
    // setYearScroll(_:); onSetYearScroll moves it programmatically (flip / year switch).
    public var onSetYearScroll: ((CGFloat) -> Void)?
    public var onEditBand: ((_ id: String, _ rect: CGRect) -> Void)?   // open inline title editor
    public var bandEditing = false        // an inline band-title field is open (freezes scroll)
    public var drawerOpen = false         // the detail drawer is open → suppress calendar hover
    private var didInitialScroll = false     // center the current month once, at first layout
    private var liveScrolling = false        // fingers-down phase of a trackpad gesture
    private var startedAtTop = false         // the drag began already resting at an edge —
    private var startedAtBottom = false      // only then does an overscroll pull arm a flip
    private var lastOverscroll: (over: CGFloat, atTop: Bool) = (0, false)
    private var yearPull: YearPull?          // pull-to-change-year hint (nil when not pulling)
    public var yearFlipEnabled = true        // gate the prev/next-year flip
    // Year-flip transition: outgoing year scrolls out + fades, then the incoming year
    // slides in from the opposite edge + fades in. Driven by the per-frame clock.
    private struct FlipAnim { var dir: Int; var fromYear: Int; var toYear: Int; var startScroll: CGFloat; var start: Date; var fadeOnly: Bool = false }
    private var flipAnim: FlipAnim?
    public private(set) var flipFade: CGFloat = 1
    public var isFlipping: Bool { flipAnim != nil }
    private let FLIP_DUR: TimeInterval = 1.0
    private let FADE_SWAP_DUR: TimeInterval = 0.5   // selectYear cross-fade (out → swap → in), no scroll motion
    // Month-view boundary flip: at Jan/Dec, an overscroll pull past the edge flips to the
    // adjacent year's Dec/Jan. Two-phase like the year flip, but at month level: the current
    // month exits + fades (phase 1), then the cross-year month enters from the opposite edge
    // + fades in (phase 2). Reuses `flipFade` for the fade; `monthFlipShift` for the movement.
    private var liveMonthScrolling = false
    private var monthPull: YearPull?
    private struct MonthFlip { var dir: Int; var fromYear: Int; var fromFocus: Int; var toYear: Int; var toFocus: Int; var startShift: CGFloat; var start: Date }
    private var monthFlip: MonthFlip?
    public private(set) var monthFlipShift: CGFloat = 0
    public var isMonthFlipping: Bool { monthFlip != nil }
    private let MONTH_FLIP_DUR: TimeInterval = 0.8
    // week-view boundary flip (overscroll past a month edge in week view). The 7-day window
    // rubber-bands past the edge; on release, if armed, focus/week re-anchor to the neighbor month
    // and the dim/bright split cross-fades (`weekFlipFade`). See setWeekProgress / endWeekGesture.
    private var liveWeekScrolling = false
    private var weekPull: WeekPull?
    private struct WeekFlip { var dir: Int; var startWeek: CGFloat; var toWeek: CGFloat; var start: Date }
    private var weekFlip: WeekFlip?
    public private(set) var weekFlipFade: CGFloat = 0   // 0→1 cross-fade of the dim/bright swap
    public var isWeekFlipping: Bool { weekFlip != nil }
    private let WEEK_FLIP_DUR: TimeInterval = 0.5
    private let weekFlipOver: CGFloat = 34   // on-screen overscroll (px) that arms a week flip
    private let weekOverMul: CGFloat = 1.9   // amplify the rubber-band travel past a month edge
    // day-view boundary flip (overscroll past a month edge in day view). Like the week flip, but a
    // single day: the day page previews the neighbor month's first/last day (via the spillover
    // day-page), and on release, if armed, it completes and focus/day re-anchor to that neighbor day.
    // No dim cross-fade — every day is distinct (there's no "same week" to reveal).
    private var liveDayScrolling = false
    private var daySettleWork: DispatchWorkItem?   // safety-net: snap a residual day-page if the pager stalls
    private var dayPull: DayPull?
    private struct DayFlip { var dir: Int; var toYear: Int; var toFocus: Int; var toDom: Int; var startP: CGFloat; var start: Date }
    private var dayFlip: DayFlip?
    public var isDayFlipping: Bool { dayFlip != nil }
    public var dayFlipArmed: Bool { isDayLevel && (dayPull?.armed ?? false) }
    private let DAY_FLIP_DUR: TimeInterval = 0.42
    private let dayFlipOver: CGFloat = 40    // on-screen overscroll (px) that arms a day flip
    private let dayOverMul: CGFloat = 1.4    // maps rubber-band px → day-page progress (preview)
    // pinch state
    private var magStartZ: CGFloat = 0
    private var magAccum: CGFloat = 0
    private var nowTimer: Timer?
    // pointer / editing state
    private var drag: Drag?
    private var createCounter = 0
    // Bumped on every mutation (edits + remote merges) so the derived-band cache (displayBands)
    // invalidates precisely — navigation frames (scroll/zoom/flip) don't touch it, so recurrence
    // expansion runs only when the data actually changed.
    private var editGen = 0
    // Bumped only when the deadline set / positions change at COMMIT (add / move-after / delete /
    // remote) — so the OFFLINE deadline-label side assignment recomputes then, not during a drag.
    private var deadlineGen = 0
    private var bandCache: (year: Int, gen: Int, bands: [BandEvent], badges: [String: EventBadges])?
    // undo / redo (whole-state snapshots, coalesced per gesture / typing burst). Snapshots the FULL
    // editable set — events/bands/deadlines AND the rich metadata (notes, tags, repeat, promote),
    // per-month track names, and daily notes — so every edit is undoable, matching the web.
    private struct EditState: Equatable {
        var events: [TimedEvent]; var bands: [BandEvent]; var deadlines: [Deadline]
        var rich: [String: RichFields]; var trackNames: [[String]]; var dailyNotes: [String: String]
    }
    private var editState: EditState {
        EditState(events: seedEvents, bands: seedBands, deadlines: seedDeadlines,
                  rich: richById, trackNames: trackNames, dailyNotes: dailyNotes)
    }
    private var undoStack: [EditState] = []
    private var redoStack: [EditState] = []
    private var pendingUndo: EditState?
    private var undoWork: DispatchWorkItem?
    private let store = ItemStore()
    private var persistWork: DispatchWorkItem?
    // Full-fidelity fields (notes/tags/recurrence/…) the lean seed arrays don't carry, keyed by
    // item id. Loaded from / saved to the store and mapped to CloudKit by CloudSync; the renderer
    // doesn't read these yet, so they just ride along untouched.
    private var richById: [String: RichFields] = [:]
    // The daily-dashboard NOTE tab: one markdown note per day, keyed by ISO date "YYYY-MM-DD".
    private var dailyNotes: [String: String] = [:]
    // ── Cloud-sync seam (Phase 1) ─────────────────────────────────────────────────
    // The state the sync layer last saw, for computing per-record deltas at persist.
    private var syncedState: PersistedState?
    /// Fired at the persist choke point with the record ids that changed since the last
    /// persist: (upserted, deleted). Phase 2's cloud layer maps these to CKSyncEngine
    /// pending changes. A change to the lane labels upserts `trackNamesRecordID`.
    public var onLocalChange: (([String], [String]) -> Void)?
    public static let trackNamesRecordID = "trackNames"
    private var cloud: CloudSync?
    /// Start CloudKit sync when this build carries the iCloud entitlement (the signed
    /// CalendarApp). The unsigned CalendarMac dev binary isn't entitled → no-op, local-only.
    private func enableCloudSyncIfEntitled() {
        guard CloudSync.isEntitled else { return }
        let c = CloudSync(engine: self)
        cloud = c
        Task { await c.startIfAccountAvailable() }
    }
    /// Nudge a cloud fetch (e.g. when the app returns to the foreground).
    public func syncNow() { cloud?.syncNow() }

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
        var createYear: Int? = nil
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
    // Deadlines/timed events are hittable once the day-detail timeline is revealed (month-detail and
    // deeper), not just week/day — so a deadline can be interacted with in the monthly view too.
    private let DETAIL_Z: CGFloat = 0.82

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
            richById = s.rich ?? [:]
            dailyNotes = s.dailyNotes ?? [:]
            // Backfill deadline origin tz from the rich side-map for stores written before Deadline
            // carried its own originTz (migrated data keeps it in rich); the field is canonical once set.
            for i in seedDeadlines.indices where seedDeadlines[i].originTz == nil {
                if let tz = richById[seedDeadlines[i].id]?.originTz { seedDeadlines[i].originTz = tz }
            }
            if let names = s.monthTrackNames, names.count == 12, names.allSatisfy({ $0.count == 4 }) { trackNames = names }
        } else {
            persistNow()   // seed the store on first launch
        }
        // Resume the create-counter past any persisted new-/newb- ids so fresh items don't
        // collide with reloaded ones (which produced duplicate SwiftUI ForEach ids).
        for id in seedEvents.map(\.id) + seedBands.map(\.id) {
            for pre in ["newb-", "new-"] where id.hasPrefix(pre) {
                if let n = Int(id.dropFirst(pre.count)) { createCounter = max(createCounter, n) }
            }
        }
        // Repair any duplicate ids already on disk (from the earlier collision bug).
        var seenIds = Set<String>()
        for i in seedBands.indices where !seenIds.insert(seedBands[i].id).inserted {
            createCounter += 1; seedBands[i].id = "newb-\(createCounter)"
        }
        for i in seedEvents.indices where !seenIds.insert(seedEvents[i].id).inserted {
            createCounter += 1; seedEvents[i].id = "new-\(createCounter)"
        }
        nowTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        pushChrome()
        enableCloudSyncIfEntitled()
    }

    // ── Persistence ─────────────────────────────────────────────────────────────
    private func persistNow() {
        let state = PersistedState(events: seedEvents, bands: seedBands, deadlines: seedDeadlines, monthTrackNames: trackNames, rich: richById, dailyNotes: dailyNotes)
        store.save(state)
        emitDelta(to: state)
    }

    /// Diff the freshly-persisted state against what the sync layer last saw and emit the
    /// changed record ids. Before the cloud layer attaches, just track the baseline.
    private func emitDelta(to state: PersistedState) {
        guard let onLocalChange else { syncedState = state; return }
        let (up, del) = Self.recordDelta(from: syncedState, to: state)
        syncedState = state
        if !up.isEmpty || !del.isEmpty { onLocalChange(up, del) }
    }

    static func recordDelta(from old: PersistedState?, to new: PersistedState) -> (upserts: [String], deletes: [String]) {
        var upserts: [String] = [], deletes: [String] = []
        func diff<T: Equatable>(_ o: [T], _ n: [T], _ id: (T) -> String) {
            let oldByID = Dictionary(o.map { (id($0), $0) }, uniquingKeysWith: { a, _ in a })
            let newByID = Dictionary(n.map { (id($0), $0) }, uniquingKeysWith: { a, _ in a })
            for (k, v) in newByID where oldByID[k] != v { upserts.append(k) }
            for k in oldByID.keys where newByID[k] == nil { deletes.append(k) }
        }
        diff(old?.events ?? [], new.events, \.id)
        diff(old?.bands ?? [], new.bands, \.id)
        diff(old?.deadlines ?? [], new.deadlines, \.id)
        if (old?.monthTrackNames ?? []) != (new.monthTrackNames ?? []) { upserts.append(trackNamesRecordID) }
        return (upserts, deletes)
    }

    // ── Cloud-sync seam: inbound + accessors (Phase 1) ────────────────────────────
    /// Snapshot of everything the sync layer needs to materialize records.
    public func syncSnapshot() -> PersistedState {
        PersistedState(events: seedEvents, bands: seedBands, deadlines: seedDeadlines, monthTrackNames: trackNames, rich: richById, dailyNotes: dailyNotes)
    }
    /// Capture the current state as the sync baseline (call when the cloud layer attaches,
    /// so the first local edit emits an incremental delta rather than the whole store).
    public func beginSyncTracking() { syncedState = syncSnapshot() }
    public func loadSyncState() -> Data? { store.loadSyncState() }
    public func saveSyncState(_ data: Data?) { store.saveSyncState(data) }

    /// Apply records fetched from the cloud. Upserts replace/insert by id; deletes remove.
    /// Deliberately bypasses undo history and the local-delta emit — this IS the synced
    /// state, so it must not echo back out or land on the undo stack.
    public func applyRemote(events: [TimedEvent] = [], bands: [BandEvent] = [],
                            deadlines: [Deadline] = [], trackNames newNames: [[String]]? = nil,
                            deletedIDs: [String] = [], rich: [String: RichFields] = [:]) {
        editGen &+= 1
        deadlineGen &+= 1                            // remote change may add/move/remove deadlines
        for e in events { Self.upsert(&seedEvents, e) }
        for b in bands { Self.upsert(&seedBands, b) }
        for d in deadlines { Self.upsert(&seedDeadlines, d) }
        for (id, rf) in rich { richById[id] = rf }
        if let newNames, newNames.count == 12, newNames.allSatisfy({ $0.count == 4 }) { trackNames = newNames }
        for id in deletedIDs {
            seedEvents.removeAll { $0.id == id }
            seedBands.removeAll { $0.id == id }
            seedDeadlines.removeAll { $0.id == id }
            richById[id] = nil
            if selectedId == id { selectedId = nil }
        }
        let state = PersistedState(events: seedEvents, bands: seedBands, deadlines: seedDeadlines, monthTrackNames: trackNames, rich: richById, dailyNotes: dailyNotes)
        store.save(state)
        syncedState = state   // adopt as baseline so the merge doesn't re-emit as a local delta
    }

    private static func upsert<T: Identifiable>(_ arr: inout [T], _ item: T) where T.ID == String {
        if let i = arr.firstIndex(where: { $0.id == item.id }) { arr[i] = item } else { arr.append(item) }
    }

    // ── Track names (editable lane labels, per month) ─────────────────────────────
    public func setTrackName(_ month: Int, _ track: Int, _ name: String) {
        guard month >= 0, month < trackNames.count, track >= 0, track < trackNames[month].count,
              trackNames[month][track] != name else { return }
        beginTxn()
        trackNames[month][track] = name
        scheduleCommit()
        schedulePersist()
    }

    /// Which track-name gutter slot is under the cursor (any zoom that shows a band gutter):
    /// its month, track index, and geometry-space rect — used to place the inline editor.
    public func trackNameHit(at p: CGPoint) -> (month: Int, track: Int, rect: CGRect)? {
        guard p.x >= Layout.mnameW, p.x <= Layout.labelW - Layout.rightPad else { return nil }
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
                   monthAnim: monthAnim, yearPull: yearPull, flipFade: flipFade,
                   animating: tween != nil || scrollTween != nil || weekTween != nil || dayTween != nil || flipAnim != nil || monthAnim != nil || weekFlip != nil || dayFlip != nil,
                   monthPull: monthPull, monthFlipShift: monthFlipShift, weekPull: weekPull,
                   weekFlipDir: weekFlip?.dir ?? 0, weekFlipFade: weekFlipFade, dayPull: dayPull, mainTz: mainTz)
    }

    /// Advance the tween to `date` and return the immutable input for this frame.
    public func sceneInput(at date: Date, viewport vp: Viewport) -> SceneInput {
        viewport = vp
        if let t = tween {
            z = t.value(at: date)
            let done = t.isComplete(at: date)
            if done { z = t.to; tween = nil }
            // hourH (and thus maxScroll) changes with z. Hold the anchor hour centred so the focus area
            // doesn't drift + snap as you zoom between week and month (a fixed-pixel scroll would map to a
            // moving hour). Also resyncs the driver. Release the anchor once the zoom settles.
            applyZoomAnchor(at: z)
            if done {
                zoomAnchorHour = nil; zoomAnchorY = nil
                if let cb = zTweenDone { zTweenDone = nil; cb() }   // sequenced next phase (e.g. go-to-today)
                if level(z) == 3 { fireDayLand() }                  // a jumpToDay landed at day view
            }
        }
        if let st = scrollTween {
            scrollY = st.value(at: date); onSetYearScroll?(scrollY)
            if st.isComplete(at: date) {
                scrollY = st.to; scrollTween = nil; onSetYearScroll?(scrollY)
                if let cb = scrollTweenDone { scrollTweenDone = nil; cb() }   // then zoom in
            }
        }
        if let wt = weekTween {
            week = wt.value(at: date)
            if wt.isComplete(at: date) {
                week = wt.to; weekTween = nil
                if let cb = weekTweenDone { weekTweenDone = nil; cb() }   // sequenced next phase (go-to-today)
            }
        }
        if let dt = dayTween {
            // Fractional-day glide: floor → the anchor day, the fraction → a ±1 day-page so the day column
            // pans + cross-fades toward today (same visual as a manual day scroll), engine-side only.
            let dim = daysInMonth(year, focus)
            if dt.isComplete(at: date) {
                daily.dom = max(1, min(dim, Int(dt.to.rounded()))); daily.anim = nil; dayTween = nil
                week = CGFloat(weekOfDate(year, focus, daily.dom))
                pushChrome(); chrome.dailyResync &+= 1
                fireDayLand()                                       // a same-month jumpToDay glide landed
            } else {
                let f = dt.value(at: date)
                let dom = max(1, min(dim, Int(f.rounded(.down))))
                let frac = f - CGFloat(dom)
                daily.dom = dom
                daily.anim = frac > 0.001 ? PageAnim(dir: 1, p: min(0.999, frac)) : nil
                week = CGFloat(weekOfDate(year, focus, dom))
                pushChrome()
            }
        }
        if let st = shiftTween {
            drawerShift = st.value(at: date)
            if st.isComplete(at: date) { drawerShift = st.to; shiftTween = nil }
        }
        if let fa = flipAnim { advanceFlip(fa, at: date) }
        if let mf = monthFlip { advanceMonthFlip(mf, at: date) }
        if let wf = weekFlip { advanceWeekFlip(wf, at: date) }
        if let df = dayFlip { advanceDayFlip(df, at: date) }
        return snapshot()
    }

    public func setViewport(_ size: CGSize) {
        viewport = Viewport(w: size.width - Layout.padLeft - Layout.padRight, h: size.height)
        if !didInitialScroll, viewport.h > 1 {
            didInitialScroll = true          // once: center today's month (clamped to top/bottom).
            scrollY = clamp(centerScroll(for: focus), 0, yearMaxScroll(viewport))
            // Default the day-view timeline ~180px narrower (a roomier dashboard) — computed here,
            // once, now that the content width is known; the user can still drag the split.
            daily.frac = clamp(daily.frac - 180 / max(1, viewport.w - Layout.labelW), 0.28, 0.82)
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

    /// Breadcrumb "Month" crumb: jump to the focused month's view. `focus` is already the shown month;
    /// tweenZ sets chrome.level=1 immediately, so the MonthPager re-syncs its page to `focus`.
    public func zoomToMonth() {
        tweenZ(to: 1)
        chrome.monthResync &+= 1   // ensure the pager lands on `focus` even if the level didn't change
    }

    /// Breadcrumb "Week" crumb: jump to the focused week's view. Snap the (possibly fractional) window
    /// to the whole week the crumb names; the WeekPager re-syncs to `week` on the level change.
    public func zoomToWeek() {
        week = week.rounded()
        tweenZ(to: 2)
        chrome.weekResync &+= 1    // ensure the strip lands on `week` even if the level didn't change
    }

    /// "Today" button. Picks the lightest path that lands on today's day view, by where we are now:
    ///   • day view   — same month: scroll the strip to today; else fly out to the year and back in.
    ///   • week view  — today in the week: zoom straight in; same month: scroll to its week then zoom;
    ///                  else fly via the year.
    ///   • month view — today's month: zoom in (week→day); else fly via the year.
    ///   • year view  — zoom straight in.
    /// Cross-year always routes through the year with a SINGLE flip to today's year, then zooms in.
    public func goToToday() {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: now)
        jumpToDay(c.year ?? year, (c.month ?? 1) - 1, c.day ?? 1)
    }

    /// The general "fly to a specific day" animation (goToToday is `jumpToDay(today)`). `onLand` fires
    /// once it finally settles at that day's view — used to open the NOTE tab for a daily-note todo.
    /// Target month `tm` is 0-based; `td` is 1-based day-of-month.
    public func jumpToDay(_ ty: Int, _ tm: Int, _ td: Int, onLand: (() -> Void)? = nil) {
        let tWeek = CGFloat((firstDOW(ty, tm) + td - 1) / 7)
        cancelTween(); flipAnim = nil
        zTweenDone = nil; weekTweenDone = nil; flipDone = nil; scrollTweenDone = nil
        dayLandDone = onLand

        // At the year layout: set focus/week/day, GLIDE the vertical scroll to centre the target month
        // (avoids the old instant snap), then zoom in. Used by every path that routes through the year.
        let flyFromYear: () -> Void = { [weak self] in
            guard let self else { return }
            self.placeDayAtYear(ty, tm, td, tWeek)
            let target = clamp(self.centerScroll(for: tm), 0, yearMaxScroll(self.viewport))
            if abs(target - self.scrollY) < 1 {
                self.tweenZ(to: 3, dur: 1.05)                    // already centred → zoom straight in
            } else {
                self.scrollTween = Tween(from: self.scrollY, to: target, start: Date(), duration: 0.5, ease: easeInOut)
                self.scrollTweenDone = { [weak self] in self?.tweenZ(to: 3, dur: 1.05) }
            }
        }
        let flyOutThenIn: () -> Void = { [weak self] in   // zoom OUT to the year, then fly in
            guard let self else { return }
            if self.level(self.z) == 0 { flyFromYear() }
            else { self.zTweenDone = flyFromYear; self.tweenZ(to: 0, dur: 0.58) }
        }

        // ── Cross-year: out to the year, ONE flip to the target year (skips intervening years), then in. ──
        if ty != year {
            let dir = ty > year ? 1 : -1
            let startFlip: () -> Void = { [weak self] in
                guard let self else { return }
                self.flipDone = flyFromYear
                self.flipAnim = FlipAnim(dir: dir, fromYear: self.year, toYear: ty, startScroll: self.scrollY, start: Date())
            }
            if level(z) == 0 { startFlip() }
            else { zTweenDone = startFlip; tweenZ(to: 0, dur: 0.58) }
            return
        }

        // ── Same year. ──
        let sameMonth = focus == tm
        switch level(z) {
        case 3:   // day view
            if sameMonth {                       // glide the day strip to the target (no zoom out)
                if daily.dom == td { fireDayLand(); break }
                let dist = abs(td - daily.dom)
                dayTween = Tween(from: CGFloat(daily.dom), to: CGFloat(td), start: Date(),
                                 duration: min(0.7, 0.2 + 0.035 * Double(dist)), ease: easeInOut)
            } else { flyOutThenIn() }
        case 2:   // week view
            if weekContains(tm, td) {            // target is on screen → zoom straight into it
                daily.dom = td; pushChrome(); chrome.dailyResync &+= 1
                tweenZ(to: 3, dur: 0.7)
            } else if sameMonth {                // scroll to its week, then zoom in
                daily.dom = td
                weekTween = Tween(from: week, to: tWeek, start: Date(), duration: 0.32, ease: easeInOut)
                weekTweenDone = { [weak self] in self?.tweenZ(to: 3, dur: 0.7) }
            } else { flyOutThenIn() }
        case 1:   // month view
            if sameMonth {                       // zoom in through the week into the day
                week = tWeek; daily.dom = td
                pushChrome(); chrome.weekResync &+= 1; chrome.dailyResync &+= 1
                tweenZ(to: 3, dur: 0.9)
            } else { flyOutThenIn() }
        default:  // year view → straight in
            flyFromYear()
        }
    }

    /// Set focus/week/day + year to the target at the year layout. The vertical scroll is glided by the
    /// caller (flyFromYear) rather than snapped, so entering the year view doesn't jump.
    private func placeDayAtYear(_ ty: Int, _ tm: Int, _ td: Int, _ tWeek: CGFloat) {
        year = ty; focus = tm; week = tWeek; daily.dom = td
        daily.anim = nil; monthAnim = nil; weekTween = nil; weekFlip = nil
        pushChrome()
        chrome.monthResync &+= 1; chrome.weekResync &+= 1; chrome.dailyResync &+= 1
    }

    /// Jump to another calendar year. Resets vertical scroll to the top, like the web's selectYear.
    public func selectYear(_ y: Int) {
        guard y != year, !isFlipping else { return }
        // Don't swap instantly: fade the whole year out, swap the data at the midpoint, fade
        // the new year in (a pure cross-fade, no scroll motion — see advanceFlip's fadeOnly path).
        flipAnim = FlipAnim(dir: 0, fromYear: year, toYear: y, startScroll: scrollY, start: Date(), fadeOnly: true)
    }

    // ── Levels + tween helpers ────────────────────────────────────────────────────
    private func level(_ z: CGFloat) -> Int { z < 0.5 ? 0 : (z < 1.5 ? 1 : (z < 2.5 ? 2 : 3)) }

    private func pushChrome(level lvl: Int? = nil) {
        // Assign only on change: @Observable fires on every SET (not just changes), so writing the
        // same value still invalidates readers. During a week scroll `week` changes every frame but
        // year/focus/level don't — deduping keeps the WeekPager (which reads year/focus) from
        // re-rendering per frame and re-applying `.scrollPosition`, which would jump the scroll.
        let newLevel = lvl ?? level(z)
        if chrome.level != newLevel { chrome.level = newLevel }
        if chrome.year != year { chrome.year = year }
        if chrome.focus != focus { chrome.focus = focus }
        if chrome.week != Double(week) { chrome.week = Double(week) }
        if chrome.dailyDom != daily.dom { chrome.dailyDom = daily.dom }
    }

    private func cancelTween() {
        if let t = tween { z = t.value(at: Date()); tween = nil }
        if let st = scrollTween { scrollY = st.value(at: Date()); scrollTween = nil }
        if let wt = weekTween { week = wt.value(at: Date()); weekTween = nil }
        if dayTween != nil { dayTween = nil; daily.anim = nil }   // settle a day-glide on its current day
        zoomAnchorHour = nil; zoomAnchorY = nil   // interrupted zoom → drop the anchor; next zoom recaptures
        snapWork?.cancel()
    }

    // (zoom anchor helpers live near sceneInput)

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
        if zoomAnchorHour == nil { captureZoomAnchor() }   // fresh for a button/click zoom; kept for a pinch settle
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
            // Fallback only; the invisible NSScrollView driver normally drives the timeline scroll.
            tlScroll = min(max(0, tlScroll - dy), timelineInfo(snapshot()).maxScroll)
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

    // ── Hour-timeline vertical scroll: mirror of an invisible NSScrollView (native elastic bounce) ──
    // Same trick as the year scroll: AppKit computes the elastic overscroll + momentum on a hidden
    // scroll view whose scrollable range == the timeline's maxScroll, and we mirror its offset here.
    // `onSetTlScroll` moves the driver programmatically (sync on gesture start / after a zoom).
    public var onSetTlScroll: ((CGFloat) -> Void)?
    // `onSetWeekScroll` moves the (invisible) week pager to a given content-offset x — used to PIN it
    // to the flip animation each frame so its own decelerate/snap animation can't diverge and twitch.
    public var onSetWeekScroll: ((CGFloat) -> Void)?
    /// Content-offset x of the week pager that shows fractional week `w` (= `w · 7 · dayW`, and the
    /// week grid spans `viewport.w − labelW`, so `dayW·7 = viewport.w − labelW`).
    private func weekOffset(_ w: CGFloat) -> CGFloat { w * max(0, viewport.w - Layout.labelW) }
    public var timelineMaxScroll: CGFloat { timelineInfo(snapshot()).maxScroll }

    /// Mirror the driver's live offset (may be < 0 or > maxScroll during the elastic bounce — that
    /// overscroll is exactly what we render). Only meaningful in week/day view.
    public func setTlScroll(_ y: CGFloat) { tlScroll = y }

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
        // Fade-only (selectYear): cross-fade the whole calendar with no scroll movement —
        // fade the outgoing year to 0, swap year + reset scroll at the midpoint, fade the
        // incoming year back to 1.
        if fa.fadeOnly {
            let t = clamp(CGFloat(date.timeIntervalSince(fa.start) / FADE_SWAP_DUR), 0, 1)
            if t >= 1 {
                year = fa.toYear; flipFade = 1; flipAnim = nil
                pushChrome()
                if let cb = flipDone { flipDone = nil; cb() }
                return
            }
            if t < 0.5 {                                     // outgoing year fades out
                let p = t / 0.5
                if year != fa.fromYear { year = fa.fromYear; pushChrome() }
                flipFade = 1 - easeInOut(p)
            } else {                                         // swap data, incoming year fades in
                let p = (t - 0.5) / 0.5
                if year != fa.toYear {
                    year = fa.toYear; scrollY = 0; onSetYearScroll?(0); pushChrome()
                }
                flipFade = easeInOut(p)
            }
            return
        }
        let vpH = viewport.h
        let maxY = yearMaxScroll(viewport)
        let dir = CGFloat(fa.dir)
        let rest: CGFloat = fa.dir > 0 ? 0 : maxY        // where the new year settles
        let t = clamp(CGFloat(date.timeIntervalSince(fa.start) / FLIP_DUR), 0, 1)
        if t >= 1 {
            year = fa.toYear; scrollY = rest; flipFade = 1; flipAnim = nil
            pushChrome(); onSetYearScroll?(rest)         // resync the scroll-view driver
            if let cb = flipDone { flipDone = nil; cb() }   // sequenced next phase (go-to-today)
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

    // ── Month view: vertical month↕month paging, driven by an invisible SwiftUI ScrollView ──
    // A hidden SwiftUI `ScrollView` with 12 page cells and `.scrollTargetBehavior(.paging)` does
    // the real work: native velocity-aware paging + the settle animation. We just observe its
    // absolute content offset (via `.onScrollGeometryChange`) and convert it to (focus, monthAnim).
    // No snap tween / recentre here — SwiftUI owns the physics; this is a pure projection.
    public var isMonthLevel: Bool { level(z) == 1 }

    /// The offset the pager should sit at to show the current focus month (`focus` whole pages in).
    public func monthPagerOffset(pageH: CGFloat) -> CGFloat { CGFloat(focus) * pageH }

    /// A scroll gesture starts — kill any zoom tween so they don't fight.
    public func beginMonthGesture() { cancelTween(); liveMonthScrolling = true }

    // ── Week view: horizontal day/week paging, driven by an invisible SwiftUI ScrollView ──
    // Same construct as the month pager, rotated horizontal: a strip of day cells + a custom
    // ScrollTargetBehavior that snaps to a day (small scroll) or a week boundary (large scroll).
    // Month-scoped for now — `week` is clamped to the month; crossing the edge (a flip) is TODO.
    public var isWeekLevel: Bool { level(z) == 2 }
    public var isDayLevel: Bool { level(z) == 3 }
    /// Day-view split: the timeline's width as a fraction of the content area (the rest is the daily
    /// dashboard). Driven by the drag handle on the timeline↔dashboard boundary; clamped so neither
    /// side collapses.
    public func setDailyFrac(_ f: CGFloat) { daily.frac = clamp(f, 0.22, 0.82); chrome.dailyResync &+= 1 }
    /// True when the current overscroll pull has passed the flip threshold — peeked on fingers-up so
    /// the catcher can withhold `.ended` from the pager (preventing a stale snap animation).
    public var weekFlipArmed: Bool { isWeekLevel && (weekPull?.armed ?? false) }

    /// The pager offset that shows the current `week` (fractional weeks × the 7-day grid width).
    public func weekPagerOffset(dayW: CGFloat) -> CGFloat { week * 7 * dayW }

    public func beginWeekGesture() { cancelTween(); weekTween = nil; liveWeekScrolling = true }

    public func beginDayGesture() { cancelTween(); liveDayScrolling = true }

    /// Project the day pager's horizontal offset onto (daily.dom, daily.anim). Each day cell is `dayW`
    /// wide (the day column's own width), so `offsetX / dayW` is a continuous day index: `daily.dom` is
    /// the anchored day and the fractional remainder becomes the slide progress. Past a month edge the
    /// (AppKit-rubber-banded) offset runs negative / beyond max; there we PREVIEW the neighbor month's
    /// first/last day sliding in (via the spillover day-page: day 0 / day dim+1) and arm a flip.
    public func setDayProgress(_ offsetX: CGFloat) {
        guard isDayLevel, !isDayFlipping else { return }
        let dayW = daily.frac * (viewport.w - Layout.labelW)
        guard dayW > 0 else { return }
        let dim = daysInMonth(year, focus)
        let maxOff = CGFloat(dim - 1) * dayW
        var norm = offsetX / dayW - CGFloat(daily.dom - 1)   // progress relative to the current anchor
        while norm >= 1, daily.dom < dim { daily.dom += 1; norm -= 1 }
        while norm <= -1, daily.dom > 1 { daily.dom -= 1; norm += 1 }
        let overLeft = offsetX < 0 ? -offsetX : 0
        let overRight = offsetX > maxOff ? offsetX - maxOff : 0
        // At the edges, map the rubber-band to a day-page PREVIEW: the neighbor month's day (day dim+1
        // resolves to next month's 1st; day 0 to prev month's last) slides in via the spillover day-page.
        if daily.dom >= dim, overRight > 0 {
            norm = min(0.999, overRight / dayW * dayOverMul)
        } else if daily.dom <= 1, overLeft > 0 {
            norm = -min(0.999, overLeft / dayW * dayOverMul)
        } else {
            if daily.dom >= dim { norm = min(0, norm) }
            if daily.dom <= 1 { norm = max(0, norm) }
        }
        daily.anim = abs(norm) < 0.001 ? nil : PageAnim(dir: norm > 0 ? 1 : -1, p: min(1, abs(norm)))
        // Arm a boundary flip while the overscroll is live.
        if liveDayScrolling, overLeft > 2 || overRight > 2 {
            let dir = overRight > 0 ? 1 : -1
            let over = dir > 0 ? overRight : overLeft
            let tm = dir > 0 ? (focus + 1) % 12 : (focus + 11) % 12
            let ty = dir > 0 ? (focus == 11 ? year + 1 : year) : (focus == 0 ? year - 1 : year)
            dayPull = DayPull(dir: dir, over: over, armed: over >= dayFlipOver, targetMonth: tm, targetYear: ty)
        } else {
            dayPull = nil
        }
        // Keep `week` on the week that contains the day we scrolled to, so zooming back out lands on
        // THAT week (not the one we entered day view from).
        week = CGFloat(weekOfDate(year, focus, daily.dom))
        pushChrome()
        scheduleDaySettle()
    }

    /// Safety-net for the day pager: forwarded webview scrolls can leave the SwiftUI ScrollView settled
    /// a hair off a day boundary (its snap behaviour didn't fully fire), so `daily.anim` keeps a leftover
    /// `p` and everything downstream (panel interactivity, the note toggle, the landing position) stays
    /// stuck mid-swipe. If scrolling goes idle with a residual, snap to the nearest day and re-sync the
    /// pager. Rescheduled on every offset change, so it only fires once the scroll has actually stopped.
    private func scheduleDaySettle() {
        daySettleWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.settleDay() }
        daySettleWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: w)
    }
    private func settleDay() {
        // The 0.1s debounce already proves the scroll is idle, so don't gate on `liveDayScrolling` —
        // a forwarded gesture that never delivered `.ended` leaves that flag stuck true, which is the
        // very case we're rescuing. Clear it here too.
        guard isDayLevel, !isDayFlipping, dayTween == nil else { return }
        liveDayScrolling = false
        guard let a = daily.anim else { return }        // already settled → nothing to do
        let dim = daysInMonth(year, focus)
        if a.p > 0.5 {                                  // past halfway → adopt the neighbour day
            let nd = daily.dom + a.dir
            if nd >= 1, nd <= dim { daily.dom = nd }
        }
        daily.anim = nil                                // clear the residual → back to "at rest"
        week = CGFloat(weekOfDate(year, focus, daily.dom))
        pushChrome(); chrome.dailyResync &+= 1          // re-sync the pager strip to the snapped day
    }

    /// Fingers lifted in day view. If a boundary pull passed the threshold, complete the day-page
    /// across the month edge (p→1), then re-anchor focus/year/day to the neighbor day. Returns true if
    /// a flip started (so the catcher can withhold `.ended` / swallow momentum, like the week flip).
    @discardableResult
    public func endDayGesture() -> Bool {
        liveDayScrolling = false
        let pull = dayPull
        dayPull = nil
        guard let pull, pull.armed, !isDayFlipping, isDayLevel else { return false }
        let toDom = pull.dir > 0 ? 1 : daysInMonth(pull.targetYear, pull.targetMonth)
        dayFlip = DayFlip(dir: pull.dir, toYear: pull.targetYear, toFocus: pull.targetMonth,
                          toDom: toDom, startP: daily.anim?.p ?? 0, start: Date())
        return true
    }

    /// Per-frame day-flip. `focus` is HELD at the from-month while the day-page eases to completion —
    /// the incoming neighbor day is drawn as the spillover day (day 0 / dim+1), so it's already the
    /// real neighbor date. At p=1 we commit: swap focus/year/day to the neighbor and re-sync the pager
    /// (and the year-view scroll, so zooming out lands on the new month).
    private func advanceDayFlip(_ df: DayFlip, at date: Date) {
        let t = clamp(CGFloat(date.timeIntervalSince(df.start) / DAY_FLIP_DUR), 0, 1)
        if t >= 1 {
            year = df.toYear; focus = df.toFocus; daily.dom = df.toDom
            daily.anim = nil; daily.over = 0; dayFlip = nil   // END the flip (else it re-commits every frame)
            week = CGFloat(weekOfDate(year, focus, daily.dom))
            scrollY = clamp(centerScroll(for: focus), 0, yearMaxScroll(viewport))
            onSetYearScroll?(scrollY)
            pushChrome()
            chrome.dailyResync += 1
            return
        }
        daily.anim = PageAnim(dir: df.dir, p: lerp(df.startP, 1, easeOut(t)))
        pushChrome()
    }

    /// Project the week pager's horizontal offset onto `week`. Day cells are `dayW` wide and a
    /// week is 7 of them, so `offsetX / (7·dayW)` is the fractional week index within the month.
    /// Past either edge the (AppKit-rubber-banded) offset runs negative / beyond max; we let `week`
    /// follow it (bounded) so the window elastically slides past the boundary, and detect the
    /// overscroll to arm a month flip.
    public func setWeekProgress(_ offsetX: CGFloat, dayW: CGFloat) {
        guard isWeekLevel, !isWeekFlipping, dayW > 0 else { return }
        let span = 7 * dayW
        let maxWeek = CGFloat(max(0, weeksInMonth(year, focus) - 1))
        let maxOff = maxWeek * span
        // Elastic: follow the rubber-banded offset past each edge, AMPLIFYING the overscroll so the
        // window travels further than AppKit's (heavily damped) rubber-band alone would allow — a
        // more generous, tactile pull. Arming/indicator use the raw px `over`, so the flip threshold
        // feel is unchanged; only the on-screen travel grows.
        let raw = offsetX / span
        if raw < 0 { week = clamp(raw * weekOverMul, -1.6, 0) }
        else if raw > maxWeek { week = clamp(maxWeek + (raw - maxWeek) * weekOverMul, maxWeek, maxWeek + 1.6) }
        else { week = raw }
        let overLeft = offsetX < 0 ? -offsetX : 0
        let overRight = offsetX > maxOff ? offsetX - maxOff : 0
        if liveWeekScrolling, overLeft > 2 || overRight > 2 {
            let dir = overRight > 0 ? 1 : -1
            let over = dir > 0 ? overRight : overLeft
            let fdow = firstDOW(year, focus)
            let dim = daysInMonth(year, focus)
            // A boundary week is "shared" (dim-swap) when it holds spillover from the neighbor:
            // the right edge shares unless the month ends on Saturday; the left unless it starts Sunday.
            let shared = dir > 0 ? ((fdow + dim - 1) % 7 != 6) : (fdow != 0)
            let tm = dir > 0 ? (focus + 1) % 12 : (focus + 11) % 12
            let ty = dir > 0 ? (focus == 11 ? year + 1 : year) : (focus == 0 ? year - 1 : year)
            weekPull = WeekPull(dir: dir, over: over, armed: over >= weekFlipOver,
                                shared: shared, targetMonth: tm, targetYear: ty)
        } else {
            weekPull = nil
        }
        pushChrome()
    }

    /// Project the pager's absolute content offset onto (focus, monthAnim). The page cells are
    /// `pageH` tall, so `offsetY / pageH` is a continuous month index; `focus` is the anchored
    /// month and the fractional remainder becomes the page-turn progress. `focus` advances as the
    /// offset crosses each page boundary, so a multi-page fling walks through the months in order.
    public func setMonthProgress(_ offsetY: CGFloat, pageH: CGFloat) {
        guard isMonthLevel, !isMonthFlipping, pageH > 0 else { return }
        let startFocus = focus
        var norm = offsetY / pageH - CGFloat(focus)
        while norm >= 1, focus < 11 { focus += 1; norm -= 1 }   // crossed into the next month
        while norm <= -1, focus > 0 { focus -= 1; norm += 1 }   // crossed into the previous month
        if focus >= 11 { norm = min(0, norm) }                  // Dec: clamp elastic overscroll
        if focus <= 0 { norm = max(0, norm) }                   // Jan
        monthAnim = abs(norm) < 0.001 ? nil
            : PageAnim(dir: norm > 0 ? 1 : -1, p: min(1, abs(norm)))
        // Elastic overscroll past Jan (top) / Dec (bottom) arms a cross-year flip. The pager
        // document is [0, 11·pageH]; a live drag can push the offset outside that, and paging
        // caps one page per gesture so this only fires when already resting at the boundary.
        let maxOff = CGFloat(11) * pageH
        let overTop = offsetY < 0 ? -offsetY : 0
        let overBot = offsetY > maxOff ? offsetY - maxOff : 0
        // Elastic: the month follows the (AppKit-rubber-banded) overscroll and snaps back with it.
        monthFlipShift = overTop > 0 ? overTop : (overBot > 0 ? -overBot : 0)
        if liveMonthScrolling, overTop > 2 || overBot > 2 {
            let atTop = overTop > 0
            monthPull = YearPull(targetYear: atTop ? year - 1 : year + 1, atTop: atTop,
                                 over: atTop ? overTop : overBot, armed: (atTop ? overTop : overBot) >= Layout.yearFlipOver)
        } else {
            monthPull = nil
        }
        // Keep the year-view scroll in step with the month we paged to, so zooming back out
        // lands on this month (centred, clamped so Jan/Dec sit at the top/bottom).
        if focus != startFocus {
            scrollY = clamp(centerScroll(for: focus), 0, yearMaxScroll(viewport))
            onSetYearScroll?(scrollY)
        }
        pushChrome()
    }

    /// Fingers lifted in month view. If a boundary pull passed the threshold, launch the
    /// cross-year flip (Jan → previous Dec, Dec → next Jan); otherwise the pager bounces back.
    public func endMonthGesture() {
        liveMonthScrolling = false
        let pull = monthPull
        monthPull = nil
        guard let pull, pull.armed, !isMonthFlipping, isMonthLevel else { return }
        let dir = pull.atTop ? -1 : 1
        monthFlip = MonthFlip(dir: dir, fromYear: year, fromFocus: focus,
                              toYear: year + dir, toFocus: dir < 0 ? 11 : 0,
                              startShift: monthFlipShift, start: Date())   // continue from the elastic pull
    }

    /// Two-phase month boundary flip, per frame. Phase 1: the current month slides off (down for
    /// a prev-flip, up for next) and fades out. Phase 2: the cross-year month enters from the
    /// opposite edge and fades in. Year/focus swap at the midpoint; the pager re-syncs then too.
    private func advanceMonthFlip(_ mf: MonthFlip, at date: Date) {
        let dir = CGFloat(mf.dir)
        let OFF = viewport.h + Layout.monthH
        let t = clamp(CGFloat(date.timeIntervalSince(mf.start) / MONTH_FLIP_DUR), 0, 1)
        if t >= 1 {
            year = mf.toYear; focus = mf.toFocus
            monthFlipShift = 0; flipFade = 1; monthFlip = nil
            scrollY = clamp(centerScroll(for: focus), 0, yearMaxScroll(viewport))
            onSetYearScroll?(scrollY)          // new year → keep the year-view scroll in step
            pushChrome()
            return
        }
        if t < 0.5 {                                    // outgoing month exits + fades
            let p = t / 0.5
            if year != mf.fromYear || focus != mf.fromFocus { year = mf.fromYear; focus = mf.fromFocus }
            monthFlipShift = lerp(mf.startShift, dir < 0 ? OFF : -OFF, easeInOut(p))  // continue from the pull
            flipFade = 1 - p
        } else {                                        // incoming (cross-year) month enters + fades
            let p = (t - 0.5) / 0.5
            if year != mf.toYear || focus != mf.toFocus {
                year = mf.toYear; focus = mf.toFocus
                pushChrome()
                chrome.monthResync += 1               // re-sync the (guarded) pager to the new focus
            }
            let enter = dir < 0 ? -OFF : OFF           // prev → Dec from top; next → Jan from bottom
            monthFlipShift = enter * (1 - easeOut(p))
            flipFade = p
        }
    }

    /// Fingers lifted in week view. If a boundary pull passed the threshold, launch the month-edge
    /// flip: the focus/week re-anchor to the neighbor month and the dim/bright split cross-fades.
    /// Returns true if a flip started (so the catcher can swallow the fling's trailing momentum).
    @discardableResult
    public func endWeekGesture() -> Bool {
        liveWeekScrolling = false
        let pull = weekPull
        weekPull = nil
        guard let pull, pull.armed, !isWeekFlipping, isWeekLevel else { return false }
        let toFocus = pull.targetMonth, toYear = pull.targetYear
        let maxWeekFrom = CGFloat(max(0, weeksInMonth(year, focus) - 1))
        // Rest week in FROM-month coordinates that shows the boundary week:
        //  · shared boundary → the SAME 7 days stay put (last/first week of the from-month);
        //  · aligned boundary → advance one week PAST the edge (into the neighbor's fresh week).
        let targetWeek: CGFloat = pull.dir > 0 ? (pull.shared ? maxWeekFrom : maxWeekFrom + 1)
                                               : (pull.shared ? 0 : -1)
        // Final anchor in DESTINATION coordinates: dir>0 → its first week; dir<0 → its last week.
        let toWeek: CGFloat = pull.dir > 0 ? 0 : CGFloat(max(0, weeksInMonth(toYear, toFocus) - 1))
        // `targetWeek` (from-coords) and `toWeek` (to-coords) are the SAME on-screen position; the
        // constant offset between the two coordinate systems is `delta = targetWeek - toWeek`. So the
        // overscrolled `week` (from-coords) maps to `week - delta` in destination coords.
        let delta = targetWeek - toWeek
        let startWeek = week - delta
        // Swap the anchor NOW, on release: month name, track names, day labels ("3"→"Jun 3") and the
        // breadcrumb all update immediately — the on-screen window doesn't move (startWeek matches the
        // current screen position) and `spillFactor` at fade=0 matches the pre-release dim, so the only
        // thing left to animate is the event cross-fade that follows.
        year = toYear; focus = toFocus; week = startWeek
        weekFlipFade = 0
        weekFlip = WeekFlip(dir: pull.dir, startWeek: startWeek, toWeek: toWeek, start: Date())
        // Keep the year-view scroll in step with the month we flipped into (exactly as month paging
        // does), so zooming out lands on this month — and one more zoom-out centers it in the year.
        scrollY = clamp(centerScroll(for: focus), 0, yearMaxScroll(viewport))
        onSetYearScroll?(scrollY)
        pushChrome()
        return true
    }

    /// Per-frame week-flip. The anchor already swapped to the destination month on release; here the
    /// window just eases from the overscrolled `startWeek` back to `toWeek` while `weekFlipFade` 0→1
    /// drives `spillFactor`'s dim/bright cross-fade. At t=1 we settle and re-sync the pager.
    private func advanceWeekFlip(_ wf: WeekFlip, at date: Date) {
        let t = clamp(CGFloat(date.timeIntervalSince(wf.start) / WEEK_FLIP_DUR), 0, 1)
        if t >= 1 {
            week = wf.toWeek
            weekFlipFade = 0; weekFlip = nil
            onSetWeekScroll?(weekOffset(week))   // pin the pager to rest BEFORE the guard lifts (no stray callback)
            pushChrome()
            chrome.weekResync += 1
            return
        }
        week = lerp(wf.startWeek, wf.toWeek, easeOut(t))   // settle the window (bounce-back)
        weekFlipFade = easeInOut(t)                        // cross-fade the events (after the text swap)
        onSetWeekScroll?(weekOffset(week))                 // pin the (invisible) pager each frame so its
                                                           // own snap/decelerate animation can't diverge → twitch
    }

    public func onMagnify(delta: CGFloat, at p: CGPoint, began: Bool, ended: Bool) {
        if began {
            cancelTween()              // clears any held anchor; recapture fresh for this gesture
            monthAnim = nil            // a pinch overrides an in-flight month page
            // …and an in-flight DAY page: settle onto the nearest day and clear the anim, so a leftover
            // `daily.anim` can't blank out the other days as we zoom out (dailyFade also guards this).
            if let a = daily.anim {
                let to = daily.dom + a.dir
                if a.p >= 0.5, to >= 1, to <= daysInMonth(year, focus) {
                    daily.dom = to; week = CGFloat(weekOfDate(year, focus, daily.dom))
                }
                daily.anim = nil
            }
            magStartZ = z
            magAccum = 0
            captureFocus(at: p)
            captureZoomAnchor(pointerY: p.y)
        } else if ended {
            tweenZ(to: z.rounded())    // keeps the pinch's anchor through the settle
        } else {
            magAccum += delta
            z = clamp(magStartZ + magAccum * PINCH_SENS, 0, 3)
            applyZoomAnchor(at: z)     // hold the centre/now hour across the pinch (no jump)
            pushChrome()
        }
    }

    /// Capture the hour to hold at the viewport centre for the whole of a zoom gesture. It must be held
    /// (not recomputed per frame): near month view `maxScroll → 0` clamps the scroll, so a per-frame
    /// re-derivation would collapse the anchor back to the geometric centre (noon). A view with scroll
    /// freedom (week) has a real focal hour → preserve it. A whole-day-fit view (month) has none → anchor
    /// to the current time, so zooming IN leans toward now (e.g. 11pm → bottom of the timeline).
    private func captureZoomAnchor(pointerY: CGFloat? = nil) {
        let tl = timelineInfo(snapshot())
        guard tl.hourH > 0 else { zoomAnchorHour = nil; zoomAnchorY = nil; return }
        if tl.maxScroll >= 1 {
            // Week (has scroll freedom) → a real focal hour: hold the current centre hour.
            zoomAnchorHour = (tlScroll + tl.viewH / 2) / tl.hourH; zoomAnchorY = nil
        } else if weekContainsToday() {
            // Whole-day fit AND we're going into today's week → lean toward the current time (centred).
            zoomAnchorHour = nowFrac(); zoomAnchorY = nil
        } else if let py = pointerY, py > tl.tlTop, py < tl.tlBottom {
            // Whole-day fit, another week → anchor the hour under the cursor and keep it under the cursor.
            zoomAnchorHour = (py - tl.tlTop + tl.scroll) / tl.hourH; zoomAnchorY = py
        } else {
            zoomAnchorHour = 12; zoomAnchorY = nil   // no pointer over the timeline → neutral midday centre
        }
    }

    /// Rescale `tlScroll` so the held anchor hour stays at `zoomAnchorY` (centre if nil) at zoom `newZ`,
    /// clamped in range. The focus-month timeline viewport is stable across the month↔week zoom, so only
    /// `hourH` changes: y = tlTop + hour·hourH − scroll ⇒ scroll = hour·hourH − (anchorY − tlTop).
    private func applyZoomAnchor(at newZ: CGFloat) {
        guard let anchor = zoomAnchorHour else { return }
        var g = snapshot(); g.z = newZ
        let tl = timelineInfo(g)
        guard tl.hourH > 0 else { return }
        let anchorY = zoomAnchorY ?? (tl.tlTop + tl.viewH / 2)
        let clamped = min(max(0, anchor * tl.hourH - (anchorY - tl.tlTop)), tl.maxScroll)
        if clamped != tlScroll { tlScroll = clamped; onSetTlScroll?(clamped) }
    }

    /// Whether the currently-targeted week window (focus + week) contains today.
    private func weekContainsToday() -> Bool {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: now)
        guard c.year == year, let cm = c.month, let cd = c.day else { return false }
        return weekContains(cm - 1, cd)
    }
    /// Does the current week window (year/focus/week) show the given day (target month `tm` 0-based,
    /// `td` 1-based)? Assumes the target is in the shown `year`.
    private func weekContains(_ tm: Int, _ td: Int) -> Bool {
        let relDom: Int
        if tm == focus { relDom = td }
        else if tm == focus - 1 { relDom = td - daysInMonth(year, focus - 1) }
        else if tm == focus + 1 { relDom = daysInMonth(year, focus) + td }
        else { return false }
        let d = CGFloat(relDom) - (1 - CGFloat(firstDOW(year, focus)) + week * 7)   // vs window start
        return d > -1 && d < 7
    }

    /// Current wall-clock time as a fractional hour (0–24), for anchoring the timeline scroll.
    private func nowFrac() -> CGFloat {
        let c = Calendar.current.dateComponents([.hour, .minute], from: now)
        return CGFloat(c.hour ?? 0) + CGFloat(c.minute ?? 0) / 60
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
            // Record the day under the pinch (for a zoom-IN to day view), but DON'T snap `week` to
            // its integer — that would jump a non-aligned 7-day window to the nearest week the moment
            // you start zooming OUT. The fractional window position is preserved through the zoom.
            // A spillover day can't be zoomed into: clamp to the nearest focus-month day, keep focus.
            if let d = dayAtPointInWeek(p.x, g) {
                let rd = relDomOf(year, focus, d.year, d.month, d.day) ?? d.day
                daily.dom = min(daysInMonth(year, focus), max(1, rd))
            }
        default: break
        }
        pushChrome()
    }

    /// Day view: is `p` inside the daily-dashboard panel (the right region)? Pointer actions there
    /// belong to the dashboard web view, not the calendar canvas — otherwise a click/drag over the
    /// panel (or the band strip hidden behind it) would create bands / select events you can't see.
    /// Self-gating: `dashboardLeftAnimated` is `vp.w` outside day view, so this is false there.
    public func inDayDashboard(_ p: CGPoint) -> Bool {
        p.x >= dashboardLeftAnimated(snapshot())
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
        if z >= DETAIL_Z, let id = deadlineAt(p, g) {
            selectedId = id
            drag = Drag(kind: .ddlMove, startPoint: p, eventId: id, origDdl: seedDeadlines.first { $0.id == id })
            return
        }
        // 4. empty timeline → a DRAG creates; a plain click deselects (if something was
        //    selected) or navigates. Selection is cleared on up (not now) so the drag
        //    can still create.
        if z >= 1.5, let spot = createSpot(at: p, g) {
            drag = Drag(kind: .create, startPoint: p, anchorHour: spot.anchor, createYear: spot.year, createMonth: spot.month, createDay: spot.day, priorSelection: prior)
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
    private func beginTxn() { editGen &+= 1; if pendingUndo == nil { pendingUndo = editState } }
    private func commitTxn() {
        undoWork?.cancel(); undoWork = nil
        guard let snap = pendingUndo else { return }
        pendingUndo = nil
        guard snap != editState else { return }     // no-op edit → no entry
        deadlineGen &+= 1                            // an edit committed → re-solve deadline label sides
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
    private func restore(_ s: EditState) {
        editGen &+= 1
        seedEvents = s.events; seedBands = s.bands; seedDeadlines = s.deadlines
        richById = s.rich; trackNames = s.trackNames; dailyNotes = s.dailyNotes
        selectedId = nil; schedulePersist()
    }
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
        if z >= DETAIL_Z, let id = deadlineAt(p, g) { return id }
        return nil
    }

    // ── Drawer canvas-shift ───────────────────────────────────────────────────────
    // Slide the calendar left so the drawer item centers in the free area beside the drawer.
    // Formula ports dashboard.css: shift = clamp(0, evcenter − (X − D)/2, D), with X the
    // window width, D the drawer width, evcenter the item's unshifted center (window coords).
    /// Begin (or re-solve) the shift for the item shown in the drawer. `drawerWidth` is the
    /// horizontal space the drawer occupies on the right.
    public func openDrawerShift(id: String, drawerWidth D: CGFloat) {
        shiftTween = Tween(from: drawerShift, to: drawerShiftTarget(id: id, drawerWidth: D),
                           start: Date(), duration: DRAWER_SHIFT_DUR, ease: easeOut)
    }
    /// Slide the calendar back to rest when the drawer closes.
    public func closeDrawerShift() {
        shiftTween = Tween(from: drawerShift, to: 0, start: Date(), duration: DRAWER_SHIFT_DUR, ease: easeOut)
    }
    /// Re-solve the shift immediately (no tween) while the drawer is being resized, so the
    /// canvas tracks the drag frame-for-frame (like the web's `.cc-drawer-resizing`).
    public func updateDrawerShift(id: String, drawerWidth D: CGFloat) {
        shiftTween = nil
        drawerShift = drawerShiftTarget(id: id, drawerWidth: D)
    }

    private func drawerShiftTarget(id: String, drawerWidth D: CGFloat) -> CGFloat {
        guard z < 2.5 else { print("[shift] z=\(z) ≥ 2.5 (daily) → 0"); return 0 }   // daily: dashboard owns the right
        // Center on the specific focused OCCURRENCE, not the series base. `selectedId` holds the
        // clicked box id (a recurrence occurrence carries a synthetic occKey), while `id` here is the
        // drawer's collapsed source id. Prefer the selected box when it belongs to this same series.
        let boxId = (selectedId.flatMap { sourceId(of: $0) == id ? $0 : nil }) ?? id
        // If we can't locate the box, DON'T shift — a bogus center (e.g. viewport middle) would
        // over-shift a left-edge item off-screen. With a real center the clamp keeps it on-screen.
        guard let X = itemCenterViewportX(boxId) else { print("[shift] no center: id=\(id) box=\(boxId) sel=\(selectedId ?? "nil") z=\(z) → 0"); return 0 }
        let W = viewport.w + Layout.padLeft + Layout.padRight        // window width
        // Place the event at the centre of the free area left of the drawer, (W − D)/2: shift left by
        // X − (W − D)/2; never shift right (≥ 0); never more than a drawer width (≤ D).
        let s = min(max(0, X - (W - D) / 2), D)
        print("[shift] box=\(boxId) X=\(Int(X)) W=\(Int(W)) D=\(Int(D)) → \(Int(s))")
        return s
    }

    /// The item's horizontal center in window coordinates (geometry x + padLeft), or nil if it
    /// has no on-screen rect right now. Looks up the DISPLAY arrays (recurrence + promoted ghosts),
    /// which is what hit-testing selects from — so a selected ghost id resolves instead of falling nil.
    private func itemCenterViewportX(_ id: String) -> CGFloat? {
        let g = snapshot()
        if let b = displayBands(for: year).first(where: { $0.id == id }), let r = bandEventRect(b, g, anim: g.monthAnim) {
            return r.x + r.w / 2 + Layout.padLeft
        }
        if z >= 1.5, let e = displayEvents(for: year).first(where: { $0.id == id }) {
            let tl = timelineInfo(g)
            let sameDay = displayEvents(for: year).filter { $0.month == e.month && $0.day == e.day }
            if let r = eventRect(e, year, focus, tl, g.vp, layoutDay(sameDay)[e.id]) {
                return r.minX + r.width / 2 + Layout.padLeft
            }
        }
        if z >= 1.5, let d = displayDeadlines(for: year).first(where: { $0.id == id }), let pos = deadlinePos(d, g) {
            // Deadline spans both the moment line [x, x+colW] AND its side label pill — center on the
            // union of the two: (min of the two lefts + max of the two rights) / 2.
            let label = deadlineLabelInfo(d, lineX: pos.x, lineY: pos.y, colW: pos.w, g).rect
            let left = min(pos.x, label.minX), right = max(pos.x + pos.w, label.maxX)
            return (left + right) / 2 + Layout.padLeft
        }
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

    // ── Derived bands for the year / band view ──────────────────────────────────────────
    // What the band lane actually draws, expanded from the lean data + rich fields:
    //   • base bands (a base individually deleted via exdate / past `until` is dropped)
    //   • recurring band ghosts — the same span shifted to each occurrence date (holes = exdates)
    //   • timed/deadline events promoted (rich.promoteTrack) to 1-day ghost bands on their lane,
    //     on the base day AND every recurrence occurrence
    // Read-only copies get a synthetic occKey id; the base band / promoted base keep their real id
    // (so a click still resolves to the source item). Cached per (year, editGen) — recurrence is
    // only re-expanded when the data changes, not on navigation frames.
    // ── Color preview (hovering a drawer swatch previews the color live on the item) ───────────
    private var colorPreview: (id: String, color: String)?
    public func setColorPreview(_ id: String, _ color: String) { colorPreview = (id, color) }
    /// Clear the preview. If `color` is given, only clears when it's still the active preview — so a
    /// swatch's mouse-leave doesn't wipe a preview a newer swatch just set.
    public func clearColorPreview(_ color: String? = nil) {
        if let color, colorPreview?.color != color { return }
        colorPreview = nil
    }
    /// Overlay the preview color on any box of the previewed series (applied after the cache, so it
    /// never persists or invalidates recurrence expansion).
    private func withPreview<T>(_ items: [T], _ id: (T) -> String, _ setColor: (inout T, String) -> Void) -> [T] {
        guard let pv = colorPreview else { return items }
        return items.map { var x = $0; if sourceId(of: id(x)) == pv.id { setColor(&x, pv.color) }; return x }
    }

    public func displayBands(for year: Int) -> [BandEvent] {
        withPreview(ensureBandCache(year).bands, { $0.id }, { $0.color = $1 })
    }
    /// Provenance/kind markers per band box id (recurrent / promoted / ai / imported), for the badge
    /// glyphs the overlay draws. Same cache as displayBands.
    public func bandBadges(for year: Int) -> [String: EventBadges] { ensureBandCache(year).badges }

    /// Provenance/kind markers for a box, from its SOURCE item's rich fields + the box's nature.
    /// Shared by the band and timed-event caches so both show the same glyphs.
    private func itemBadges(_ src: String, recurrent: Bool, promoted: Bool) -> EventBadges {
        var b: EventBadges = []
        if recurrent { b.insert(.recurrent) }
        if promoted { b.insert(.promoted) }
        if let rf = richById[src] {
            if rf.createdByAI { b.insert(.ai) }
            if rf.source != "manual" { b.insert(.imported) }
        }
        return b
    }

    private func ensureBandCache(_ year: Int) -> (bands: [BandEvent], badges: [String: EventBadges]) {
        if let c = bandCache, c.year == year, c.gen == editGen { return (c.bands, c.badges) }
        func repeatOf(_ id: String) -> Repeat? { Repeat.parse(richById[id]?.repeatJSON) }
        // Markers for a box, from its SOURCE item's rich fields + the box's nature.
        func badges(_ src: String, recurrent: Bool, promoted: Bool) -> EventBadges {
            var b: EventBadges = []
            if recurrent { b.insert(.recurrent) }
            if promoted { b.insert(.promoted) }
            if let rf = richById[src] {
                if rf.createdByAI { b.insert(.ai) }
                if rf.source != "manual" { b.insert(.imported) }
            }
            return b
        }
        var out: [BandEvent] = []
        var badgeMap: [String: EventBadges] = [:]

        for b in seedBands where b.year == year {
            if baseHidden(occDate(YMD(b.year, b.month, b.startDay)), repeatOf(b.id)) { continue }
            out.append(b)
            badgeMap[b.id] = badges(b.id, recurrent: repeatOf(b.id) != nil, promoted: false)
        }
        for b in seedBands {
            guard let r = repeatOf(b.id) else { continue }
            let span = b.endDay - b.startDay
            for o in occurrenceDates(YMD(b.year, b.month, b.startDay), r, year) {
                let endDay = min(o.day + span, daysInMonth(year, o.month))
                let key = occKey(b.id, o)
                out.append(BandEvent(id: key, year: year, month: o.month, track: b.track,
                                     startDay: o.day, endDay: endDay, title: b.title, color: b.color))
                badgeMap[key] = badges(b.id, recurrent: true, promoted: false)
            }
        }
        func promote(_ id: String, _ y: Int, _ m: Int, _ day: Int, _ title: String, _ color: String) {
            guard let track = richById[id]?.promoteTrack else { return }
            let r = repeatOf(id)
            if y == year && !baseHidden(occDate(YMD(y, m, day)), r) {
                // A distinct occurrence-key id (not the raw source id) so the promoted bar is its own
                // box: selecting the original timeline event highlights it (same source) without also
                // making it the focused box, and vice-versa. sourceId() maps both back to `id`.
                let key = occKey(id, YMD(y, m, day))
                out.append(BandEvent(id: key, year: year, month: m, track: track, startDay: day, endDay: day, title: title, color: color))
                badgeMap[key] = badges(id, recurrent: r != nil, promoted: true)
            }
            for o in occurrenceDates(YMD(y, m, day), r, year) {
                let key = occKey(id, o)
                out.append(BandEvent(id: key, year: year, month: o.month, track: track,
                                     startDay: o.day, endDay: o.day, title: title, color: color))
                badgeMap[key] = badges(id, recurrent: true, promoted: true)
            }
        }
        for e in seedEvents { promote(e.id, e.year, e.month, e.day, e.title, e.color) }
        for d in seedDeadlines { promote(d.id, d.year, d.month, d.day, d.title, d.color) }

        bandCache = (year, editGen, out, badgeMap)
        return (out, badgeMap)
    }

    // ── Derived timed events for the day / detail timeline ──────────────────────────────
    // Base timed events (a base deleted via exdate / past `until` is dropped) + recurring "ghost"
    // occurrences on their occurrence days (holes = exdates), each a copy with the same hours and a
    // synthetic occKey id. The timeline only draws the focused day's items, so off-day occurrences
    // are culled downstream; the ghosts just make a recurring event appear on every occurrence day.
    // Cached per (year, editGen) — like displayBands.
    private var eventCache: (year: Int, gen: Int, events: [TimedEvent], badges: [String: EventBadges])?
    public func displayEvents(for year: Int) -> [TimedEvent] {
        withPreview(ensureEventCache(year).events, { $0.id }, { $0.color = $1 })
    }
    public func eventBadges(for year: Int) -> [String: EventBadges] { ensureEventCache(year).badges }

    private func ensureEventCache(_ year: Int) -> (events: [TimedEvent], badges: [String: EventBadges]) {
        if let c = eventCache, c.year == year, c.gen == editGen { return (c.events, c.badges) }
        func repeatOf(_ id: String) -> Repeat? { Repeat.parse(richById[id]?.repeatJSON) }
        var out: [TimedEvent] = []
        var badgeMap: [String: EventBadges] = [:]
        for e in seedEvents where e.year == year {
            if baseHidden(occDate(YMD(e.year, e.month, e.day)), repeatOf(e.id)) { continue }
            out.append(e)
            badgeMap[e.id] = itemBadges(e.id, recurrent: repeatOf(e.id) != nil, promoted: false)
        }
        for e in seedEvents {
            guard let r = repeatOf(e.id) else { continue }
            for o in occurrenceDates(YMD(e.year, e.month, e.day), r, year) {
                let key = occKey(e.id, o)
                out.append(TimedEvent(id: key, year: year, month: o.month, day: o.day,
                                      startHour: e.startHour, endHour: e.endHour, title: e.title, color: e.color))
                badgeMap[key] = itemBadges(e.id, recurrent: true, promoted: false)
            }
        }
        eventCache = (year, editGen, out, badgeMap)
        return (out, badgeMap)
    }

    // ── Derived deadlines for the deadline layer ────────────────────────────────────────
    // Base deadlines (a base deleted via exdate / past `until` is dropped) + recurring ghost
    // occurrences on their occurrence days (holes = exdates), each a copy at the same hour with a
    // synthetic occKey id. Cached per (year, editGen) — like displayEvents / displayBands.
    private var ddlCache: (year: Int, gen: Int, deadlines: [Deadline])?
    public func displayDeadlines(for year: Int) -> [Deadline] {
        if let c = ddlCache, c.year == year, c.gen == editGen { return withPreview(c.deadlines, { $0.id }, { $0.color = $1 }) }
        func repeatOf(_ id: String) -> Repeat? { Repeat.parse(richById[id]?.repeatJSON) }
        var out: [Deadline] = []
        for d in seedDeadlines where d.year == year {
            if baseHidden(occDate(YMD(d.year, d.month, d.day)), repeatOf(d.id)) { continue }
            out.append(d)
        }
        for d in seedDeadlines {
            guard let r = repeatOf(d.id) else { continue }
            for o in occurrenceDates(YMD(d.year, d.month, d.day), r, year) {
                out.append(Deadline(id: occKey(d.id, o), year: year, month: o.month, day: o.day,
                                    hour: d.hour, title: d.title, color: d.color, originTz: d.originTz))
            }
        }
        ddlCache = (year, editGen, out)
        return withPreview(out, { $0.id }, { $0.color = $1 })
    }

    // ── View-scoped item sets (include cross-year-boundary spillover) ────────────────────
    // The scene is year-scoped, but a week/day-view window at a month edge can show a neighbor month
    // that lives in the ADJACENT year (Dec↔Jan). Merge those neighbor-year items ONLY in week/day
    // view — in year/month view a neighbor-year event would wrongly render in the current year's band
    // (the non-weekish path positions by month alone). Other focuses' neighbors are the same year.
    private var boundaryYears: [Int] {
        guard z > 1 else { return [] }   // spillover columns only appear past pure month level
        if focus == 0 { return [year - 1] }
        if focus == 11 { return [year + 1] }
        return []
    }
    public func viewEvents() -> [TimedEvent] { displayEvents(for: year) + boundaryYears.flatMap { displayEvents(for: $0) } }
    public func viewBands() -> [BandEvent] { displayBands(for: year) + boundaryYears.flatMap { displayBands(for: $0) } }
    public func viewDeadlines() -> [Deadline] { displayDeadlines(for: year) + boundaryYears.flatMap { displayDeadlines(for: $0) } }
    public func viewBandBadges() -> [String: EventBadges] {
        var m = bandBadges(for: year); for y in boundaryYears { m.merge(bandBadges(for: y)) { a, _ in a } }; return m
    }
    public func viewEventBadges() -> [String: EventBadges] {
        var m = eventBadges(for: year); for y in boundaryYears { m.merge(eventBadges(for: y)) { a, _ in a } }; return m
    }

    // ── Offline deadline-label side assignment (left/right, overlap-minimising) ──────────
    // Recomputed only when the month (focus/year), detail-visibility, or the deadline set changes;
    // cached otherwise (NOT per frame / not on scroll). The overlay + hit-test use this as each
    // label's base side; the runtime hover-flip can still override one on top.
    private var ddlSides: [String: Bool] = [:]
    private var ddlSidesKey: (focus: Int, incoming: Int, year: Int, gen: Int, detail: Bool, dayView: Bool)?
    public func deadlineSides() -> [String: Bool] {
        let detail = z >= DETAIL_Z
        // Day view forces every label to the left (one wide column); week/month minimises overlap. Both
        // have detail==true, so the day-view state must be its own cache key or the week assignment
        // would stay cached into day view (labels stuck on the right).
        let dayView = z > 2
        // During a month page-turn, `focus` is the anchor and `focus+dir` is the incoming month —
        // known the moment scrolling starts. Solve for BOTH so the incoming labels are already
        // assigned when the turn settles (no post-scroll flip). incoming = -1 when not turning.
        let incoming = monthAnim.flatMap { a -> Int? in let m = focus + a.dir; return (0...11).contains(m) ? m : nil } ?? -1
        if let k = ddlSidesKey, k.focus == focus, k.incoming == incoming, k.year == year, k.gen == deadlineGen, k.detail == detail, k.dayView == dayView {
            return ddlSides
        }
        if detail {
            var s = deadlineSidesForMonth(focus)
            if incoming >= 0 { for (id, v) in deadlineSidesForMonth(incoming) where s[id] == nil { s[id] = v } }
            ddlSides = s
        } else {
            ddlSides = [:]
        }
        ddlSidesKey = (focus, incoming, year, deadlineGen, detail, dayView)
        return ddlSides
    }
    /// Overlap-minimising side assignment for ONE month's deadlines, at that month's resting layout.
    private func deadlineSidesForMonth(_ month: Int) -> [String: Bool] {
        var g = snapshot(); g.focus = month; g.monthAnim = nil
        return deadlineSideAssignment(displayDeadlines(for: year), g)
    }

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

    // ── Rich fields (tags / repeat / promote), keyed by the item's base id ─────────────────────
    // The drawer opens with the source (base) id, so these read/write the same key. Not on the undo
    // stack yet (EditState only snapshots the lean arrays); they persist + invalidate the display cache.
    public func richTags(_ id: String) -> [String] { richById[id]?.tags ?? [] }
    public func notes(_ id: String) -> String { richById[id]?.notes ?? "" }
    public func setNotes(_ id: String, _ v: String) {
        var rf = richById[id] ?? RichFields()
        guard rf.notes != v else { return }
        rf.notes = v; richById[id] = rf
        // NOT in the calendar undo stack: notes are edited in the drawer's CodeMirror, which owns its
        // own undo (Cmd+Z while it's focused). Recording here would let its internal undo re-post the
        // note and pollute the calendar stack. Matches the web (notes are a separate lower layer).
        schedulePersist()
    }
    /// Per-occurrence note (recurring events), keyed by the focused box id.
    public func occNote(_ id: String, _ key: String) -> String { richById[id]?.occurrenceNotes?[key] ?? "" }
    public func setOccNote(_ id: String, _ key: String, _ v: String) {
        var rf = richById[id] ?? RichFields()
        var occ = rf.occurrenceNotes ?? [:]
        guard occ[key] != v else { return }
        occ[key] = v.isEmpty ? nil : v
        rf.occurrenceNotes = occ.isEmpty ? nil : occ
        richById[id] = rf
        schedulePersist()   // per-occurrence note: CodeMirror-owned undo, not the calendar stack (see setNotes)
    }

    // ── Daily dashboard data (feeds the WebView TODO index + deadline list) ────────────────────
    // Mirrors the web's TodoEventContext[] so the bundled `todos.ts` tokenizer + sectioning render
    // identically. Wall-clock strings ("YYYY-MM-DD[THH:MM:SS]"); a timed event carries its year here.
    private struct TodoContext: Codable { var id, kind, title, color: String; var tags: [String]; var start, end: String; var originTz: String?; var notes: String?; var occurrenceNotes: [String: String]? }
    private struct DashDeadline: Codable { var id: String; var year, month, day: Int; var hour: Double; var title, color: String }
    private struct DashPayload: Codable { var events: [TodoContext]; var deadlines: [DashDeadline]; var viewIso, today: String; var dailyNotes: [String: String] }

    private func wall(_ y: Int, _ m0: Int, _ d: Int, _ hour: CGFloat? = nil) -> String {
        let base = String(format: "%04d-%02d-%02d", y, m0 + 1, d)
        guard let hour else { return base }
        let t = Int((hour * 60).rounded())
        return base + String(format: "T%02d:%02d:00", (t / 60) % 24, t % 60)
    }
    private func todoContexts() -> [TodoContext] {
        func ctx(_ id: String, _ kind: String, _ title: String, _ color: String, _ start: String, _ end: String, _ tz: String? = nil) -> TodoContext {
            let rf = richById[id]
            return TodoContext(id: id, kind: kind, title: title, color: color, tags: rf?.tags ?? [],
                               start: start, end: end, originTz: tz, notes: rf?.notes, occurrenceNotes: rf?.occurrenceNotes)
        }
        var out: [TodoContext] = []
        for e in seedEvents { out.append(ctx(e.id, "timed", e.title, e.color, wall(year, e.month, e.day, e.startHour), wall(year, e.month, e.day, e.endHour))) }
        for b in seedBands { out.append(ctx(b.id, "band", b.title, b.color, wall(b.year, b.month, b.startDay), wall(b.year, b.month, b.endDay))) }
        for d in seedDeadlines { let w = wall(d.year, d.month, d.day, d.hour); out.append(ctx(d.id, "deadline", d.title, d.color, w, w, d.originTz)) }
        return out
    }
    /// The JSON the dashboard WebView consumes: contexts + deadlines + the viewed day + real today.
    public func dashboardDataJSON() -> String {
        let dls = seedDeadlines.map { DashDeadline(id: $0.id, year: $0.year, month: $0.month, day: $0.day, hour: Double($0.hour), title: $0.title, color: $0.color) }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let today = String(format: "%04d-%02d-%02d", c.year ?? year, c.month ?? 1, c.day ?? 1)
        let r = resolveDate(year, focus, daily.dom)
        let viewIso = r.map { wall($0.year, $0.month, $0.day) } ?? wall(year, focus, daily.dom)
        let payload = DashPayload(events: todoContexts(), deadlines: dls, viewIso: viewIso, today: today, dailyNotes: dailyNotes)
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
        let reveal = Double(clamp(z - 2, 0, 1))
        let from = dayIso(daily.dom) ?? ""
        guard let a = daily.anim else { return (from, "", 0, 0, reveal) }
        return (from, dayIso(daily.dom + a.dir) ?? "", a.dir, Double(a.p), reveal)
    }
    /// Apply a dashboard checkbox toggle (or any note rewrite): the WebView sends back the new note.
    public func applyTodoNote(eventId: String, occKey: String?, value: String) {
        if let occKey, !occKey.isEmpty { setOccNote(eventId, occKey, value) } else { setNotes(eventId, value) }
    }

    // ── Daily note (the dashboard NOTE tab) — one markdown note per ISO date ────────────────────
    public func dailyNote(_ iso: String) -> String { dailyNotes[iso] ?? "" }
    public func setDailyNote(_ iso: String, _ v: String) {
        guard dailyNotes[iso] != v else { return }
        if v.isEmpty { dailyNotes[iso] = nil } else { dailyNotes[iso] = v }
        schedulePersist()
    }
    /// Merge imported daily notes (e.g. migrated from the web server); non-empty values win.
    public func importDailyNotes(_ notes: [String: String]) {
        for (iso, v) in notes where !v.isEmpty { dailyNotes[iso] = v }
        schedulePersist()
    }

    // ── Scoped delete for recurring events (matches the web: this / this+future / all) ─────────
    /// Remove just the focused occurrence — punch a hole by adding its date to the repeat exdates.
    public func deleteOccurrence(_ id: String, _ occKey: String) {
        guard var rep = repeatConfig(id), let ymd = occurrenceYMD(id, occKey) else { return }
        var ex = rep.exdates ?? []
        let iso = occDate(ymd)
        if !ex.contains(iso) { ex.append(iso) }
        rep.exdates = ex
        setRepeat(id, rep)
        if selectedId == occKey || selectedId == id { selectedId = nil }
    }
    /// Remove this occurrence and everything after — cap the series `until` the day before it.
    public func deleteFuture(_ id: String, _ occKey: String) {
        guard var rep = repeatConfig(id), let ymd = occurrenceYMD(id, occKey) else { return }
        rep.until = occDate(dayBefore(ymd))
        setRepeat(id, rep)
        if selectedId == occKey || selectedId == id { selectedId = nil }
    }
    /// The occurrence's date: a ghost box carries "id@Y-M-D" (0-based month); the base box uses the
    /// series' own base date.
    private func occurrenceYMD(_ id: String, _ occKey: String) -> YMD? {
        if let at = occKey.firstIndex(of: "@") {
            let p = occKey[occKey.index(after: at)...].split(separator: "-").compactMap { Int($0) }
            if p.count == 3 { return YMD(p[0], p[1], p[2]) }
        }
        if let b = seedBands.first(where: { $0.id == id }) { return YMD(b.year, b.month, b.startDay) }
        if let d = seedDeadlines.first(where: { $0.id == id }) { return YMD(d.year, d.month, d.day) }
        if let e = seedEvents.first(where: { $0.id == id }) { return YMD(year, e.month, e.day) }
        return nil
    }
    private func dayBefore(_ p: YMD) -> YMD {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        let d = c.date(from: DateComponents(year: p.year, month: p.month + 1, day: p.day)) ?? Date()
        let prev = c.date(byAdding: .day, value: -1, to: d) ?? d
        let x = c.dateComponents([.year, .month, .day], from: prev)
        return YMD(x.year ?? p.year, (x.month ?? 1) - 1, x.day ?? p.day)
    }
    public func repeatConfig(_ id: String) -> Repeat? { Repeat.parse(richById[id]?.repeatJSON) }
    public func promoteTrack(_ id: String) -> Int? { richById[id]?.promoteTrack }

    private func mutateRich(_ id: String, _ mutate: (inout RichFields) -> Void) {
        beginTxn()             // tags / repeat / promote are structural edits → one undo step each
        var rf = richById[id] ?? RichFields()
        mutate(&rf)
        richById[id] = rf
        editGen &+= 1          // repeat / promote change the expanded display set → invalidate the cache
        scheduleCommit()
        schedulePersist()
    }
    public func setTags(_ id: String, _ tags: [String]) { mutateRich(id) { $0.tags = tags } }
    public func setPromoteTrack(_ id: String, _ t: Int?) { mutateRich(id) { $0.promoteTrack = t } }
    public func setRepeat(_ id: String, _ r: Repeat?) {
        var json: String? = nil
        if let r, r.kind != "none", let data = try? JSONEncoder().encode(r) { json = String(data: data, encoding: .utf8) }
        mutateRich(id) { $0.repeatJSON = json }
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
            if let w = weekAtPointInMonth(p.x, g) { week = CGFloat(w); captureZoomAnchor(pointerY: p.y); tweenZ(to: 2) }
        case 2:
            // Only focus-month days drill into day view; spillover days aren't zoomable.
            if let d = dayAtPointInWeek(p.x, g), let rd = relDomOf(year, focus, d.year, d.month, d.day),
               rd >= 1, rd <= daysInMonth(year, focus) {
                daily.dom = rd; week = CGFloat(d.week); tweenZ(to: 3)
            }
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
        guard tl.colW > 0 else { return nil }
        // Only the day column under the cursor can contain the point. Resolve that column and hit-test
        // just that one day — packing it once. The old code re-filtered the full list and re-ran
        // layoutDay for EVERY event (O(N²) per mouse-move); with hundreds of events that stalled the
        // hover/cursor pipeline, so the mouse-driven cursor line lagged while everything else stayed
        // smooth. Pack against the same ghost-inclusive same-day set the overlay renders → hit rects
        // match the drawn rects.
        let relCursor = Int(floor((p.x - tl.x0) / tl.colW)) + 1
        if dailyFade(relCursor, g) <= 0.02 { return nil }
        // Include the neighbor year so a Dec↔Jan spillover column's events are hit-testable too.
        var pool = displayEvents(for: year)
        if focus == 0 { pool += displayEvents(for: year - 1) }
        if focus == 11 { pool += displayEvents(for: year + 1) }
        let sameDay = pool.filter { relDomOf(year, focus, $0.year, $0.month, $0.day) == relCursor }
        guard !sameDay.isEmpty else { return nil }
        let layout = layoutDay(sameDay)
        var found: (String, PointerKind)?
        for e in sameDay {
            guard let r = eventRect(e, year, focus, tl, g.vp, layout[e.id]) else { continue }
            let rect = CGRect(x: r.minX, y: tl.tlTop - tl.scroll + r.minY, width: r.width, height: r.height)
            if rect.contains(p) {
                let zone: PointerKind = (p.y - rect.minY < 5) ? .resizeTop : (rect.maxY - p.y < 5 ? .resizeBottom : .move)
                found = (e.id, zone)   // keep last → topmost drawn
            }
        }
        return found
    }

    private func createSpot(at p: CGPoint, _ g: SceneInput) -> (year: Int, month: Int, day: Int, anchor: CGFloat)? {
        let tl = timelineInfo(g)
        guard tl.reveal > 0.05, tl.hourH > 0, p.y >= tl.tlTop, p.y <= tl.tlBottom else { return nil }
        if z > 2 && p.x >= tl.x0 + CGFloat(daily.dom) * tl.colW { return nil }
        let (domOpt, hf) = pointToSlot(p.x, p.y, tl)
        guard let dom = domOpt, let r = resolveDate(year, focus, dom) else { return nil }
        return (r.year, r.month, r.day, snap(hf, 30))
    }

    private func applyMove(_ d: Drag, _ p: CGPoint, _ tl: TimelineInfo) {
        guard let orig = d.orig, let idx = seedEvents.firstIndex(where: { $0.id == d.eventId }) else { return }
        beginTxn()
        let dur = orig.endHour - orig.startHour
        let ns = max(0, min(24 - dur, snap(orig.startHour + (p.y - d.startPoint.y) / tl.hourH, 15)))
        var ev = seedEvents[idx]
        ev.startHour = ns; ev.endHour = ns + dur
        if let dom = pointToSlot(p.x, p.y, tl).dom, let r = resolveDate(year, focus, dom) { ev.year = r.year; ev.month = r.month; ev.day = r.day }
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
            // UUID (not the counter) so ids are globally unique — two devices creating
            // offline must never mint the same recordName. Prefix kept for readability.
            let id = "new-\(UUID().uuidString)"
            seedEvents.append(TimedEvent(id: id, year: d.createYear ?? year, month: mo, day: dy, startHour: a, endHour: min(24, a + 0.25), title: "New event", color: "blue"))
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
        for b in displayBands(for: year) {   // includes recurrence + promoted ghosts (selectable, read-only)
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
        // Ghost / promoted bars aren't in seedBands → they're read-only (move/resize no-op); only a
        // real, already-selected band exposes resize edges. Otherwise it's a move/select.
        let isReal = seedBands.contains { $0.id == bb.b.id }
        let zone: PointerKind = (isReal && bb.b.id == selectedId)
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
            let id = "newb-\(UUID().uuidString)"   // globally unique (see applyCreate)
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
        let dls = displayDeadlines(for: year)          // includes recurrence ghosts (selectable, read-only)
        let sides = deadlineSides()                     // same base sides the overlay uses
        var hit: String?
        for d in dls {
            guard let pos = deadlinePos(d, g) else { continue }
            // Hit the LABEL pill (at its base side) or the moment line itself.
            let onLine = p.x >= pos.x && p.x <= pos.x + pos.w && abs(p.y - pos.y) < 8
            let info = deadlineLabelInfo(d, lineX: pos.x, lineY: pos.y, colW: pos.w, g)
            if info.rect(onLeft: sides[d.id] ?? info.defaultOnLeft).contains(p) || onLine { hit = d.id }
        }
        return hit
    }

    private func applyDdlMove(_ d: Drag, _ p: CGPoint, _ g: SceneInput) {
        guard let orig = d.origDdl, let idx = seedDeadlines.firstIndex(where: { $0.id == d.eventId }) else { return }
        beginTxn()
        let tl = timelineInfo(g)
        // Delta-based: move relative to where the deadline was at mouse-down, by the mouse delta —
        // never jump to the absolute pointer (important when dragging the side label, not the line).
        var dd = seedDeadlines[idx]
        dd.hour = max(0, min(24, snap(orig.hour + (p.y - d.startPoint.y) / tl.hourH, 15)))
        let dayDelta = tl.colW > 0 ? Int(((p.x - d.startPoint.x) / tl.colW).rounded()) : 0
        if dayDelta != 0, let origRd = relDomOf(year, focus, orig.year, orig.month, orig.day),
           let r = resolveDate(year, focus, origRd + dayDelta) {
            dd.year = r.year; dd.month = r.month; dd.day = r.day
        } else {
            dd.year = orig.year; dd.month = orig.month; dd.day = orig.day
        }
        seedDeadlines[idx] = dd
    }

    public func onEscape() {
        cancelTween()
        tweenZ(to: CGFloat(max(0, level(z) - 1)))
    }

    public func onHover(at p: CGPoint) {
        if drawerOpen { onHoverExit(); return }   // drawer open → no calendar hover highlights
        let g = snapshot()
        var hv = Hover()
        switch level(z) {
        case 0:
            let m = monthRowAtPoint(p.x, p.y, g)
            hv.month = m
            hv.nameMonth = monthNameAtPoint(p.x, p.y, g)
            if let m { hv.dom = domInMonthBand(p.x, m, g) }
        case 1:
            // Crosshair: track lane (band cell or track-name gutter) + day column (band or timeline).
            let f = frameFor(focus, g)
            let bandTop = f.bandY, bandBottom = f.bandY + 4 * f.trackH
            let inGutter = p.x < Layout.labelW
            if p.y >= bandTop, p.y < bandBottom,
               (!inGutter || (p.x >= Layout.mnameW && p.x <= Layout.labelW - Layout.rightPad)) {
                hv.track = min(3, max(0, Int((p.y - bandTop) / f.trackH)))
            }
            if !inGutter { hv.dom = domInFocus(p.x, g) }   // day column when over content (band or timeline)
        default:
            // In daily view the right panel is the dashboard — no background time cursor there.
            // Use the FIXED dashboard boundary (pan-independent) so a mid-scroll cursor near the edge
            // doesn't leak into the dashboard region.
            if z > 2, p.x >= dashboardLeft(g) { hover = .none; return }
            let c = cellInWeek(p.x, p.y, g)
            hv.dom = c.dom; hv.hour = c.hour; hv.hourFrac = c.hourFrac; hv.nearLeft = c.nearLeft
        }
        // Hover stickiness: if the cursor is still inside the currently-hovered event,
        // keep it — so moving into an overlap doesn't hand the highlight to the event
        // underneath. Only when the cursor leaves it do we re-pick the topmost.
        if let cur = hoveredEventId, bandContains(cur, p, g) {
            // keep hoveredEventId — a band (no timeline cursor change)
        } else if let cur = hoveredEventId, timedContains(cur, p, g) {
            hv.overTimed = true   // keep hoveredEventId — a timed event
        } else if let b = bandAt(p, g) { hoveredEventId = b.id }
        else if z >= 1.5, let e = eventAt(p, g) { hoveredEventId = e.id; hv.overTimed = true }
        else if z >= DETAIL_Z, let d = deadlineAt(p, g) { hoveredEventId = d; hv.overDeadline = true }
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
        let sameDay = displayEvents(for: year).filter { $0.month == e.month && $0.day == e.day }
        guard let r = eventRect(e, year, focus, tl, g.vp, layoutDay(sameDay)[e.id]) else { return false }
        return CGRect(x: r.minX, y: tl.tlTop - tl.scroll + r.minY, width: r.width, height: r.height).contains(p)
    }

    public func onHoverExit() { hover = .none; hoveredEventId = nil }

    /// Clear the current event selection — the same effect as a plain click on empty calendar space.
    /// Used by the daily-dashboard WebView so clicking its empty content deselects too.
    public func deselect() { selectedId = nil }

    public enum CursorHint { case normal, grab, resizeLR, text }
    public func cursorHint(at p: CGPoint) -> CursorHint {
        if trackNameHit(at: p) != nil { return .text }   // editable lane label
        let g = snapshot()
        if let hit = bandAt(p, g) {
            if hit.zone == .bandResizeL || hit.zone == .bandResizeR { return .resizeLR }
            return hit.id == selectedId ? .text : .grab   // a selected band edits its title on click
        }
        if z >= 1.5, let hit = eventAt(p, g) { return hit.id == selectedId ? .text : .grab }
        if z >= DETAIL_Z, deadlineAt(p, g) != nil { return .grab }
        return .normal   // empty calendar → plain arrow (no create "+" cursor)
    }

    // ── Seed data (display only, until the sync layer lands) ─────────────────────
    private static func makeSeeds(year: Int, month: Int, day: Int) -> [TimedEvent] {
        let d0 = max(1, min(daysInMonth(year, month) - 2, day))
        return [
            TimedEvent(id: "s1", year: year, month: month, day: d0, startHour: 9, endHour: 10, title: "Standup", color: "blue"),
            TimedEvent(id: "s2", year: year, month: month, day: d0, startHour: 11, endHour: 12.5, title: "Design review", color: "green"),
            TimedEvent(id: "s3", year: year, month: month, day: d0, startHour: 11.5, endHour: 13, title: "1:1 with Alex", color: "yellow"),
            TimedEvent(id: "s4", year: year, month: month, day: d0, startHour: 14, endHour: 15, title: "Lecture", color: "red"),
            TimedEvent(id: "s5", year: year, month: month, day: min(daysInMonth(year, month), d0 + 1), startHour: 10, endHour: 11.5, title: "Research sync", color: "blue"),
            TimedEvent(id: "s6", year: year, month: month, day: min(daysInMonth(year, month), d0 + 1), startHour: 16, endHour: 18, title: "Seminar", color: "purple"),
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
