// The mutable view-state + anim.tween clock. Geometry is stateless; this is where z,
// focus, week, scroll, hover, and the animation live. SwiftUI observes it directly.

import Foundation
import CoreGraphics
import CalendarGeometry

/// iCloud connectivity as the settings UI needs to describe it. `localOnly` means this
/// build isn't entitled for CloudKit (the unsigned dev binary), so it never touches iCloud;
/// the rest mirror `CKAccountStatus` once entitled.
public enum ICloudStatus: Sendable {
    case localOnly, available, noAccount, restricted, unavailable, unknown
}

/// Drives whether the calendar's per-frame `TimelineView` renders. The engine is a plain (non-
/// @Observable) type redrawn every frame; without this, `TimelineView(.animation)` burns a full-scene
/// render at display rate even when nothing changes. `awake` is the ONE observable bit the view reads:
/// `paused: !awake`. The engine wakes it on any input/animation/edit and sleeps it after a short idle.
@MainActor @Observable public final class RenderClock {
    public internal(set) var awake = true
}

// Plain reference type (not @Observable): the view redraws every frame via
// TimelineView(.animation), which reads a fresh SceneInput and advances the anim.tween
// from the display clock — so observation isn't needed and can't cause update loops.
@MainActor
public final class CalendarEngine {
    // Render loop: the calendar's TimelineView pauses when `renderClock.awake` is false (idle).
    public let renderClock = RenderClock()
    private var sleepWork: DispatchWorkItem?
    private let idleSleep: TimeInterval = 0.4   // sleep this long after the last activity (covers SwiftUI fades)

    /// Kick the render loop — call at every input / animation-start / edit entry point. Cheap +
    /// idempotent, so over-calling is fine. Wakes the clock (if asleep) and (re)arms the idle sleep.
    /// The sleep runs OFF the render pass (a work item, not inside sceneInput) so we never mutate the
    /// observable `awake` during a SwiftUI view update.
    public func wake() {
        if !renderClock.awake { renderClock.awake = true }
        armSleep()
    }
    /// (Re)schedule the idle sleep. While anything is animating the timer keeps deferring; once the
    /// scene is fully at rest for `idleSleep`, it pauses the TimelineView.
    private func armSleep() {
        sleepWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.needsRender { self.armSleep() } else { self.renderClock.awake = false }
        }
        sleepWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + idleSleep, execute: w)
    }
    /// Anything that changes the scene frame-to-frame (so the loop must stay awake). `isAnimating`
    /// covers the z/scroll/week/day tweens + flips; add the rest of the live/elastic/drag states.
    private var needsRender: Bool {
        isAnimating || anim.shiftTween != nil || anim.monthFlip != nil || drag != nil || daily.anim != nil
        || scroll.liveScrolling || scroll.liveMonthScrolling || scroll.liveWeekScrolling || scroll.liveDayScrolling
        || scroll.yearPull != nil || scroll.monthPull != nil || scroll.weekPull != nil || scroll.dayPull != nil
    }

    // View state
    public private(set) var z: CGFloat = 0
    public private(set) var focus: Int
    public private(set) var week: CGFloat = 0
    public private(set) var scrollY: CGFloat = 0
    public private(set) var tlScroll: CGFloat = 0
    private func fireDayLand() { if let cb = anim.dayLandDone { anim.dayLandDone = nil; cb() } }
    public private(set) var daily: DailyState
    public private(set) var hover: Hover = .none
    public private(set) var pointerPos: CGPoint?   // last hover point (calendar space) → is the cursor on the deadline "+"?
    /// The cursor is near the timeline's left border (week/day) → reveal the scale bar.
    public private(set) var nearTlEdge = false
    /// How close (px, either side of the border) the cursor must be to reveal the scale bar.
    private static let tlEdgeRevealDist: CGFloat = 80
    public private(set) var year: Int
    public let systemYear: Int          // the real "today" year at launch — anchors the picker range
    public var mainTz: String = "auto"  // deadline main timezone (for origin-tz labels); "auto" = device zone
    public var altTz: String = "none"   // View ▸ Alternative Timezone → the second hour column; "none" = off
    public private(set) var now: Date = Date()

    /// Fractional-hour shift for the alt-tz hour column (nil = off). DST-aware at `now`.
    private var altDeltaHours: CGFloat? {
        guard altTz != "none", !altTz.isEmpty, altTz != mainTz else { return nil }
        return CGFloat(DeadlineTZ.hourShift(from: mainTz, to: altTz, at: now))
    }
    /// Header abbreviation for the alt-tz column (e.g. "JST"), nil when off.
    private var altColumnLabel: String? {
        guard altTz != "none", !altTz.isEmpty, altTz != mainTz else { return nil }
        return DeadlineTZ.shortLabel(altTz, at: now)
    }
    public private(set) var weekHourH: CGFloat = 60   // set via setWeekHourH (clamped + persisted)
    public private(set) var viewport: Viewport = Viewport(w: 1, h: 1)
    /// The user's calendar DATA — the single mutable source of truth that edits mutate, undo
    /// snapshots, and the sync layer persists. (Historically the flat `items.events`/`items.bands`/
    /// `items.deadlines` fields; composed here so the engine's state has visible structure.)
    public internal(set) var items = CalendarItems()

    /// Derived-display caches + invalidation generations (see DisplayCaches).
    var caches = DisplayCaches()

    /// Read-only Apple Calendar imports (see ImportedItems) — separate from `items` by design.
    public internal(set) var imported = ImportedItems()

    /// The keyboard-navigation cursor family (see CursorState).
    public internal(set) var cursor = CursorState()

    /// In-flight animation machinery (see AnimState): tweens, flips, fades, zoom anchors, and
    /// the one-shot completion callbacks that sequence multi-phase navigations.
    var anim = AnimState()

    /// Transient scroll-gesture bookkeeping (see ScrollGestureState): live-phase flags, edge
    /// pulls, and overscroll arming. All internal — nothing here is view position.
    var scroll = ScrollGestureState()
    // Read-only events imported from Apple Calendar (EventKit). Kept SEPARATE from the seed arrays so
    // they never persist to disk / push to iCloud (they're re-fetched) and can't be edited — every edit
    // path targets the seed arrays. They're merged into the display caches (see ensureEventCache /
    // ensureBandCache). User overlays (tags/notes/promote) attach via `items.richById` by the stable id.
    // Imported id → EKEvent.eventIdentifier, rebuilt each merge. Transient (not persisted): only used to
    // build the `ical://ekevent/…` deep-link for "Edit original", which is only offered on a live import.
    let appleImporter = AppleCalendarImporter()   // internal: +AppleImport (stored props can't move to extensions)
    public var trackEditing = false        // an inline track-name field is open (freezes scroll)
    public let chrome = CalendarChrome()   // breadcrumb state for the toolbar

    public internal(set) var selectedId: String?                // internal(set): +Extensions files
    public private(set) var hoveredEventId: String?   // band/timed/deadline under the cursor

    // ── Keyboard navigation cursor ────────────────────────────────────────────────
    // `cursor.keyboardActive` gates only the CURSOR VISUAL (last-input-wins): a mouse move/click flips it off,
    // a dispatched nav key flips it on. The position below always persists. Block-cursor position is
    // interpreted per view (year → month; month → day; week/day → day + hour); grown one view at a time.
    // Band cursor = the block cursor's time position (cursor.blockMonth/cursor.blockDay) PLUS a lane. Only these two
    // extra bits of state: whether we're in band-cursor mode, and which of the 4 lanes.
    // One-step directional memory (see the doc): the last event move, so the exact reverse arrow returns.
    // Month view's extra Tab stops: which of the 4 track NAMES is focused (nil = not on a track name).
    public var onEditTrackName: ((_ month: Int, _ track: Int, _ rect: CGRect) -> Void)?

    // Day view's extra Tab stops: the dashboard TODO list and the daily NOTE become 2 keyboard focus
    // targets after the event cursor (see tabCursor). `cursor.dashStop` is the focused one (nil = not on the
    // dashboard); `cursor.dashNoteEditing` flips true once Enter focuses the note editor (the WebView owns keys
    // then). The focus ring itself is drawn INSIDE the WebView, driven via `onDashCommand`.
    public enum DashStop: Equatable { case todo, note }
    /// Commands to the dashboard WebView bridge — CalendarView wires this to the native TODO/NOTE tab
    /// and the carousel's JS `CK.nav*` calls (row cursor, toggle, open, focus-the-editor).
    public enum DashCmd: Equatable { case focus(DashStop?), move(Int), activate, open }
    public var onDashCommand: ((DashCmd) -> Void)?
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

    // Drawer canvas-shift: while the detail drawer is open the whole calendar slides left so
    // the selected item centers in the free area beside the drawer (ports the web's
    // .cc-drawer-open .app-shell transform). Tweened per-frame like z / week.
    public private(set) var drawerShift: CGFloat = 0
    private let DRAWER_SHIFT_DUR: TimeInterval = 0.28
    private var snapWork: DispatchWorkItem?
    // Year-view scroll is driven by a real NSScrollView (native elastic bounce + momentum).
    // The input bridge forwards wheel events to it and mirrors its offset back here via
    // setYearScroll(_:); onSetYearScroll moves it programmatically (flip / year switch).
    public var onSetYearScroll: ((CGFloat) -> Void)?
    public var onEditBand: ((_ id: String, _ rect: CGRect) -> Void)?   // open inline title editor
    public var bandEditing = false        // an inline band-title field is open (freezes scroll)
    public var onEditTimed: ((_ id: String, _ rect: CGRect) -> Void)?  // open inline timed-title editor
    public var timedEditing = false       // an inline timed-event-title field is open (freezes scroll)
    /// Open the detail drawer for a just-created item (deadline "+"); `selectTitle` → focus + select-all
    /// the default title so typing replaces it. Wired to the UI (ui.openEventId + ui.selectTitleOnOpen).
    public var onRequestOpenDrawer: ((_ id: String, _ selectTitle: Bool) -> Void)?
    public var drawerOpen = false         // the detail drawer is open → suppress calendar hover
    // Fired after an EXTERNAL data change (Apple re-import / iCloud remote apply) that may have removed the
    // item a drawer/dialog is showing. The UI re-validates and closes anything pointing at a vanished item.
    public var onExternalDataChange: (() -> Void)?
    // A blocking modal (the delete-confirm dialog) is up. Mirrored from the UI so the signed app's
    // menu-driven shortcuts (⌘I assistant, ⌘Z undo) — which bypass the calendar's key monitor — can
    // refuse to fire while it's open, matching the monitor's own block on ⌘K/⌘F/etc.
    public var inputModalUp = false
    public var yearFlipEnabled = true        // gate the prev/next-year flip
    // Year-flip transition: outgoing year scrolls out + fades, then the incoming year
    // slides in from the opposite edge + fades in. Driven by the per-frame clock.
    struct FlipAnim { var dir: Int; var fromYear: Int; var toYear: Int; var startScroll: CGFloat; var start: Date; var fadeOnly: Bool = false }
    public var isFlipping: Bool { anim.flipAnim != nil }
    private let FLIP_DUR: TimeInterval = 1.0
    private let FADE_SWAP_DUR: TimeInterval = 0.5   // selectYear cross-fade (out → swap → in), no scroll motion
    // Month-view boundary flip: at Jan/Dec, an overscroll pull past the edge flips to the
    // adjacent year's Dec/Jan. Two-phase like the year flip, but at month level: the current
    // month exits + fades (phase 1), then the cross-year month enters from the opposite edge
    // + fades in (phase 2). Reuses `anim.flipFade` for the fade; `anim.monthFlipShift` for the movement.
    struct MonthFlip { var dir: Int; var fromYear: Int; var fromFocus: Int; var toYear: Int; var toFocus: Int; var startShift: CGFloat; var start: Date }
    public var isMonthFlipping: Bool { anim.monthFlip != nil }
    private let MONTH_FLIP_DUR: TimeInterval = 0.8
    // week-view boundary flip (overscroll past a month edge in week view). The 7-day window
    // rubber-bands past the edge; on release, if armed, focus/week re-anchor to the neighbor month
    // and the dim/bright split cross-fades (`anim.weekFlipFade`). See setWeekProgress / endWeekGesture.
    struct WeekFlip { var dir: Int; var startWeek: CGFloat; var toWeek: CGFloat; var start: Date }
    public var isWeekFlipping: Bool { anim.weekFlip != nil }
    private let WEEK_FLIP_DUR: TimeInterval = 0.5
    private let weekFlipOver: CGFloat = 34   // on-screen overscroll (px) that arms a week flip
    private let weekOverMul: CGFloat = 1.9   // amplify the rubber-band travel past a month edge
    // day-view boundary flip (overscroll past a month edge in day view). Like the week flip, but a
    // single day: the day page previews the neighbor month's first/last day (via the spillover
    // day-page), and on release, if armed, it completes and focus/day re-anchor to that neighbor day.
    // No dim cross-fade — every day is distinct (there's no "same week" to reveal).
    struct DayFlip { var dir: Int; var toYear: Int; var toFocus: Int; var toDom: Int; var startP: CGFloat; var start: Date }
    public var isDayFlipping: Bool { anim.dayFlip != nil }
    public var dayFlipArmed: Bool { isDayLevel && (scroll.dayPull?.armed ?? false) }
    private let DAY_FLIP_DUR: TimeInterval = 0.42
    private let dayFlipOver: CGFloat = 40    // on-screen overscroll (px) that arms a day flip
    private let dayOverMul: CGFloat = 1.4    // maps rubber-band px → day-page progress (preview)
    // pinch state
    private var magStartZ: CGFloat = 0
    private var magAccum: CGFloat = 0
    private var nowTimer: Timer?
    // pointer / editing state
    var drag: Drag?
    private var createCounter = 0
    // Bumped on every mutation (edits + remote merges) so the derived-band cache (displayBands)
    // invalidates precisely — navigation frames (scroll/zoom/flip) don't touch it, so recurrence
    // expansion runs only when the data actually changed.
    // Bumped only when the deadline set / positions change at COMMIT (add / move-after / delete /
    // remote) — so the OFFLINE deadline-label side assignment recomputes then, not during a drag.
    // undo / redo (whole-state snapshots, coalesced per gesture / typing burst). Snapshots the FULL
    // editable set — events/bands/deadlines AND the rich metadata (notes, tags, repeat, promote),
    // per-month track names, and daily notes — so every edit is undoable, matching the web.
    private struct EditState: Equatable {
        var events: [TimedEvent]; var bands: [BandEvent]; var deadlines: [Deadline]
        var rich: [String: RichFields]; var trackNames: [[String]]; var dailyNotes: [String: String]
    }
    private var editState: EditState {
        EditState(events: items.events, bands: items.bands, deadlines: items.deadlines,
                  rich: items.richById, trackNames: items.trackNames, dailyNotes: items.dailyNotes)
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
    // Display-derivation caches — used by CalendarEngine+Display.swift:
    var colorPreview: (id: String, color: String)?   // internal: +Display (stored caches stay in the class)
    // Toolbar-search corpus — a pre-folded, flat index of every item across all years, rebuilt ONLY on a
    // data change (caches.editGen), so each keystroke scans a cached array instead of re-expanding/​re-folding the
    // whole calendar. See CalendarEngine+Search.swift.
    // The daily-dashboard NOTE tab: one markdown note per day, keyed by ISO date "YYYY-MM-DD".
    // ── Cloud-sync seam (Phase 1) ─────────────────────────────────────────────────
    // The state the sync layer last saw, for computing per-record deltas at persist.
    private var syncedState: PersistedState?
    /// Fired at the persist choke point with the record ids that changed since the last
    /// persist: (upserted, deleted). Phase 2's cloud layer maps these to CKSyncEngine
    /// pending changes. A change to the lane labels upserts `trackNamesRecordID`.
    public var onLocalChange: (([String], [String]) -> Void)?
    public static let trackNamesRecordID = "trackNames"
    private var cloud: CloudSync?
    /// Observable "last synced" state for the Connectivity menu. Always present (shows "local only" in
    /// the unentitled dev build); CloudSync writes `markSynced()` on each successful round-trip.
    public let syncMonitor = SyncMonitor(cloudEnabled: CloudSync.isEntitled)
    /// Start CloudKit sync when this build carries the iCloud entitlement (the signed
    /// CalendarApp). The unsigned CalendarMac dev binary isn't entitled → no-op, local-only.
    private func enableCloudSyncIfEntitled() {
        // NEVER sync in a recording/demo session: it would pull the user's real iCloud calendar into the
        // throwaway store (a privacy leak into GIFs), defeating the isolation. Mirrors importAppleCalendar's
        // demo guard.
        guard CloudSync.isEntitled, !Self.isDemoMode else { return }
        let c = CloudSync(engine: self)
        cloud = c
        Task { await c.startIfAccountAvailable() }
    }
    /// Nudge a cloud fetch/push (foreground, periodic, or the Connectivity menu's "Sync Now").
    public func syncNow() { cloud?.syncNow() }
    /// "Sync Now" from the Connectivity menu: refresh BOTH external sources — re-import Apple Calendar and
    /// fetch/push iCloud — and reflect progress in the monitor. No-op cloud in the local-only dev build.
    public func refreshConnectivity() {
        importAppleCalendar()
        guard cloud != nil else { return }
        syncMonitor.isSyncing = true
        cloud?.syncNow()
    }

    /// Current iCloud connectivity, for the settings UI. Instance-free (the settings window
    /// doesn't share the running engine) — reads the entitlement + CloudKit account status.
    /// CloudKit types stay contained in CloudSync; this just re-exports the module enum.
    public static func iCloudStatus() async -> ICloudStatus { await CloudSync.iCloudStatus() }

    // ── Demo / GIF-recording mode ──────────────────────────────────────────────────────────────
    /// True when launched for automated tutorial-GIF recording (env CC_DEMO=<scene>). In this mode the
    /// store is redirected to a throwaway dir (see ItemStore) and Apple Calendar import is skipped, so a
    /// recording never touches personal data. The DemoController scripts the on-screen scene.
    public static var isDemoMode: Bool { !(ProcessInfo.processInfo.environment["CC_DEMO"] ?? "").isEmpty }
    public static var demoScene: String { ProcessInfo.processInfo.environment["CC_DEMO"] ?? "" }
    /// Wipe the calendar to an empty state (recording scenes build their own deterministic content).
    public func demoClearEvents() {
        items.events = []; items.bands = []; items.deadlines = []; items.richById = [:]
        selectedId = nil; caches.editGen &+= 1; caches.deadlineGen &+= 1; wake()
    }
    /// Insert one ambient timed event (recording scenes; not on the undo stack, not selected).
    @discardableResult
    public func demoAddTimed(month: Int, day: Int, startHour: CGFloat, endHour: CGFloat, title: String, color: String) -> String {
        let id = "demo-\(items.events.count)"
        items.events.append(TimedEvent(id: id, year: year, month: month, day: day, startHour: startHour, endHour: endHour, title: title, color: color))
        caches.editGen &+= 1; caches.deadlineGen &+= 1; wake()
        return id
    }
    /// Insert one ambient all-day band (recording scenes; not selected).
    @discardableResult
    public func demoAddBand(month: Int, track: Int, startDay: Int, endDay: Int, title: String, color: String) -> String {
        let id = "demob-\(items.bands.count)"
        items.bands.append(BandEvent(id: id, year: year, month: month, track: track, startDay: startDay, endDay: endDay, title: title, color: color))
        caches.editGen &+= 1; caches.deadlineGen &+= 1; wake()
        return id
    }
    // Drive the REAL pointer/create path from VIEW-local points (GeometryReader space, 0,0 = top-left), so a
    // scripted drag creates an event exactly under the synthetic cursor — with the live create-preview. This
    // mirrors CatcherView.point(): geometry space = view − padLeft (+ the live drawer shift).
    private func demoViewToGeometry(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - Layout.padLeft + drawerShift, y: p.y) }
    public func demoPointerDown(atView p: CGPoint) { onPointerDown(at: demoViewToGeometry(p)) }
    public func demoPointerDrag(atView p: CGPoint) { onPointerDrag(at: demoViewToGeometry(p)) }
    public func demoPointerUp(atView p: CGPoint)   { onPointerUp(at: demoViewToGeometry(p)) }
    /// Rename the currently-selected event (recording scenes give a freshly drag-created event a real title).
    public func demoRenameSelected(_ title: String) {
        guard let id = selectedId, let i = items.events.firstIndex(where: { $0.id == id }) else { return }
        items.events[i].title = title; caches.editGen &+= 1; wake()
    }
    /// Rename the currently-selected BAND (band scenes name their freshly drag-created band).
    public func demoRenameSelectedBand(_ title: String) {
        guard let id = selectedId, let i = items.bands.firstIndex(where: { $0.id == id }) else { return }
        items.bands[i].title = title; caches.editGen &+= 1; wake()
    }
    /// Snap the view to year level, scrolled so `centerMonth` is visible (deterministic scene setup).
    public func demoGoToYear(centerMonth: Int) {
        cancelTween()
        z = 0; focus = centerMonth
        ensureMonthVisible(centerMonth, animated: false)
        caches.editGen &+= 1; caches.deadlineGen &+= 1; wake()
    }
    /// Drive the REAL pinch path (`onMagnify`) from a view point, so the month/week/day under `v` is exactly
    /// what fills the screen (`captureFocus` anchors on the pinch point — unlike the keyboard/block zoom,
    /// which snaps to the block cursor / today). The recording's pinch visual is drawn at this same point, so
    /// the gesture and the zoom target always line up. `delta` is trackpad-style magnification (PINCH_SENS
    /// scales it into z); a full single-level pinch accumulates ≈0.7 (see DemoController.pinch).
    public func demoMagnify(delta: CGFloat, atView v: CGPoint, began: Bool, ended: Bool) {
        onMagnify(delta: delta, at: demoViewToGeometry(v), began: began, ended: ended)
    }
    /// Double-click an item at a view point: select it (so it highlights) and open its drawer — the same
    /// outcome as a real double-click. Returns the item id, or nil if nothing was under the point.
    @discardableResult
    public func demoDoubleClick(atView v: CGPoint) -> String? {
        guard let id = itemId(at: demoViewToGeometry(v)) else { return nil }
        selectedId = id
        onRequestOpenDrawer?(id, false)
        caches.editGen &+= 1; wake()
        return id
    }
    /// Select an item by id (highlight it), e.g. a just-created event in the AI scene.
    public func demoSelect(_ id: String?) { selectedId = id; caches.editGen &+= 1; wake() }


    enum PointerKind {
        case navigate, move, resizeTop, resizeBottom, create           // timed
        case bandMove, bandResizeL, bandResizeR, bandCreate            // all-day bands
        case ddlMove                                                   // deadlines
    }
    struct Drag {
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
        var titleHit = false                 // down landed on the title text → a click there inline-edits it
        var activated = false
    }

    private let ZOOM_DUR: TimeInterval = 0.52
    private let PINCH_SENS: CGFloat = 1.6
    // Deadlines/timed events are hittable once the day-detail timeline is revealed (month-detail and
    // deeper), not just week/day — so a deadline can be interacted with in the monthly view too.
    let DETAIL_Z: CGFloat = 0.82

    public init() {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        year = c.year ?? 2026
        systemYear = c.year ?? 2026
        focus = (c.month ?? 1) - 1
        cursor.blockMonth = focus; cursor.blockDay = c.day ?? 1
        daily = DailyState(dom: c.day ?? 1, frac: 0.45)
        // No placeholder seed events (regular OR recording mode) — a fresh install starts with an empty
        // calendar; the recording scenes seed their own ambient data. Existing users load from the store below.
        items.events = []; items.bands = []; items.deadlines = []
        // self is now fully initialized — restore persisted edits over the seeds.
        if let s = store.load() {
            items.events = s.events; items.bands = s.bands; items.deadlines = s.deadlines
            items.richById = s.rich ?? [:]
            items.dailyNotes = s.dailyNotes ?? [:]
            // Backfill deadline origin tz from the rich side-map for stores written before Deadline
            // carried its own originTz (migrated data keeps it in rich); the field is canonical once set.
            for i in items.deadlines.indices where items.deadlines[i].originTz == nil {
                if let tz = items.richById[items.deadlines[i].id]?.originTz { items.deadlines[i].originTz = tz }
            }
            if let names = s.monthTrackNames, names.count == 12, names.allSatisfy({ $0.count == 4 }) { items.trackNames = names }
        } else {
            persistNow()   // seed the store on first launch
        }
        mainTz = UserDefaults.standard.string(forKey: Self.mainTzKey) ?? "auto"   // View ▸ Current Timezone
        altTz = UserDefaults.standard.string(forKey: Self.altTzKey) ?? "none"     // View ▸ Alternative Timezone
        migrateAnchors()   // stamp anchorTz on legacy items (needs mainTz resolved above)
        // The timeline scale-bar's chosen hour height survives restarts.
        if UserDefaults.standard.object(forKey: Self.weekHourHKey) != nil {
            weekHourH = clampHourH(CGFloat(UserDefaults.standard.double(forKey: Self.weekHourHKey)))
        }
        // Resume the create-counter past any persisted new-/newb- ids so fresh items don't
        // collide with reloaded ones (which produced duplicate SwiftUI ForEach ids).
        for id in items.events.map(\.id) + items.bands.map(\.id) {
            for pre in ["newb-", "new-"] where id.hasPrefix(pre) {
                if let n = Int(id.dropFirst(pre.count)) { createCounter = max(createCounter, n) }
            }
        }
        // Repair any duplicate ids already on disk (from the earlier collision bug).
        var seenIds = Set<String>()
        for i in items.bands.indices where !seenIds.insert(items.bands[i].id).inserted {
            createCounter += 1; items.bands[i].id = "newb-\(createCounter)"
        }
        for i in items.events.indices where !seenIds.insert(items.events[i].id).inserted {
            createCounter += 1; items.events[i].id = "new-\(createCounter)"
        }
        nowTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date(); self?.wake() }   // refresh the now-line (a render must run)
        }
        pushChrome()
        enableCloudSyncIfEntitled()
        armSleep()   // an untouched app settles to a paused (idle) render after the initial frame
    }

    /// A fixed anchor for a freshly created item: the current view (main) zone, resolved to a concrete
    /// id so it never drifts with the device (a stored anchor must not be "auto").
    var anchorNow: String { DeadlineTZ.concrete(mainTz) }   // internal: +Extensions files stamp anchors

    /// One-time backfill so every timed event and deadline carries an explicit `anchorTz` — the display
    /// pipeline needs it to convert into the current view zone. Legacy items stored their wall-clock in
    /// the main tz, so the anchor IS the (resolved) main tz and the stored hours stay valid untouched.
    /// A deadline that carried a legacy `originTz` is RE-ANCHORED to that origin (its `hour` was the
    /// main-tz equivalent, so we re-express it as the origin wall-clock), preserving both the instant and
    /// the "(AOE 23:59)" label. Idempotent — items that already have an anchor are skipped.
    private func migrateAnchors() {
        let main = DeadlineTZ.concrete(mainTz)
        var changed = false
        for i in items.events.indices where items.events[i].anchorTz == nil {
            items.events[i].anchorTz = main; changed = true
        }
        for i in items.deadlines.indices where items.deadlines[i].anchorTz == nil {
            let d = items.deadlines[i]
            if let origin = d.originTz,
               !DeadlineTZ.sameOffset(origin, mainTz, at: DeadlineTZ.instant(d.year, d.month, d.day, d.hour)) {
                let w = DeadlineTZ.convertWall(d.year, d.month, d.day, d.hour, from: mainTz, to: origin)
                items.deadlines[i].year = w.year; items.deadlines[i].month = w.month
                items.deadlines[i].day = w.day; items.deadlines[i].hour = w.hour
                items.deadlines[i].anchorTz = DeadlineTZ.concrete(origin)
            } else {
                items.deadlines[i].anchorTz = main
            }
            items.deadlines[i].originTz = nil   // folded into anchorTz; the legacy field is retired
            changed = true
        }
        if changed { persistNow() }
    }
    // ── Persistence ─────────────────────────────────────────────────────────────
    private func persistNow() {
        let state = PersistedState(events: items.events, bands: items.bands, deadlines: items.deadlines, monthTrackNames: items.trackNames, rich: items.richById, dailyNotes: items.dailyNotes)
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
        // Rich-field changes that DIDN'T move a body (a note/tag/promote/color edit) still need to sync:
        //   • a normal item id → re-save its body record (rich rides on it)
        //   • an imported SERIES key → its own standalone "Overlay" record (no body of ours to ride on)
        //   • an imported PER-OCCURRENCE key (the `hidden` dedup flag) → local-only, never synced
        let oldRich = old?.rich ?? [:], newRich = new.rich ?? [:]
        for k in Set(oldRich.keys).union(newRich.keys) where !isApplePerOccurrenceKey(k) {
            let o = oldRich[k], n = newRich[k]
            if o == n { continue }
            if isAppleSeriesKey(k) {
                // Only user-authored overlays are worth an iCloud record (skip managed-note-only churn).
                let keep = n.map(hasUserOverlay) ?? false
                if keep { upserts.append(k) } else { deletes.append(k) }
            } else {
                upserts.append(k)   // normal item: re-materialize its body with the new rich
            }
        }
        let delSet = Set(deletes)
        upserts = Array(Set(upserts).subtracting(delSet))
        deletes = Array(delSet)
        return (upserts, deletes)
    }

    // ── Cloud-sync seam: inbound + accessors (Phase 1) ────────────────────────────
    /// Snapshot of everything the sync layer needs to materialize records.
    public func syncSnapshot() -> PersistedState {
        PersistedState(events: items.events, bands: items.bands, deadlines: items.deadlines, monthTrackNames: items.trackNames, rich: items.richById, dailyNotes: items.dailyNotes)
    }
    /// Capture the current state as the sync baseline (call when the cloud layer attaches,
    /// so the first local edit emits an incremental delta rather than the whole store).
    public func beginSyncTracking() { syncedState = syncSnapshot() }
    public func loadSyncState() -> Data? { store.loadSyncState() }
    public func saveSyncState(_ data: Data?) { store.saveSyncState(data) }

    // ── Bulk import / export (File menu: .ics / .mdc) ──────────────────────────────────
    /// The full local dataset, for writing a .mdc backup. (Same shape the sync layer snapshots.)
    public func exportState() -> PersistedState { syncSnapshot() }

    /// Append imported items (e.g. from an .ics file) as editable seed items — ONE undoable step.
    public func importItems(events: [TimedEvent] = [], bands: [BandEvent] = [],
                            deadlines: [Deadline] = [], rich: [String: RichFields] = [:]) {
        guard !events.isEmpty || !bands.isEmpty || !deadlines.isEmpty else { return }
        beginTxn()
        items.events.append(contentsOf: events)
        items.bands.append(contentsOf: bands)
        items.deadlines.append(contentsOf: deadlines)
        for (k, v) in rich { items.richById[k] = v }
        commitTxn()
    }

    /// Replace the ENTIRE local dataset (restoring a .mdc backup) — ONE undoable step, so an accidental
    /// import can be undone. Bumps the caches + persists, exactly like `restore`.
    public func replaceAll(_ s: PersistedState) {
        commitTxn()
        undoStack.append(editState); if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        wake(); caches.editGen &+= 1; caches.deadlineGen &+= 1
        items.events = s.events; items.bands = s.bands; items.deadlines = s.deadlines
        items.richById = s.rich ?? [:]
        if let tn = s.monthTrackNames { items.trackNames = tn }
        items.dailyNotes = s.dailyNotes ?? [:]
        selectedId = nil
        schedulePersist()
    }

    /// Write the whole calendar to a `.mdc` backup (a zip mirroring the web export). Throws on I/O error.
    public func exportMDC(to url: URL) throws {
        let files = try MDCBackup.encode(exportState(), exportedAt: Date())
        try Zipper.write(files, to: url)
    }
    /// Restore a `.mdc` (or the web's `.zip`) backup — replaces the entire local dataset (undoable).
    public func importMDC(from url: URL) throws {
        let state = try MDCBackup.decode(try Zipper.read(url))
        replaceAll(state)
    }
    /// Import an `.ics` file's events as editable items. Returns how many were added.
    @discardableResult
    public func importICS(from url: URL) throws -> Int {
        let text = try String(contentsOf: url, encoding: .utf8)
        let (events, bands, rich) = ICSImport.items(from: text, provenance: url.lastPathComponent)
        importItems(events: events, bands: bands, rich: rich)
        return events.count + bands.count
    }

    /// Apply records fetched from the cloud. Upserts replace/insert by id; deletes remove.
    /// Deliberately bypasses undo history and the local-delta emit — this IS the synced
    /// state, so it must not echo back out or land on the undo stack.
    public func applyRemote(events: [TimedEvent] = [], bands: [BandEvent] = [],
                            deadlines: [Deadline] = [], trackNames newNames: [[String]]? = nil,
                            deletedIDs: [String] = [], rich: [String: RichFields] = [:]) {
        wake()                                       // remote data landed → a render must run
        caches.editGen &+= 1
        caches.deadlineGen &+= 1                            // remote change may add/move/remove deadlines
        for e in events { Self.upsert(&items.events, e) }
        for b in bands { Self.upsert(&items.bands, b) }
        for d in deadlines { Self.upsert(&items.deadlines, d) }
        for (id, rf) in rich { items.richById[id] = rf }
        if let newNames, newNames.count == 12, newNames.allSatisfy({ $0.count == 4 }) { items.trackNames = newNames }
        for id in deletedIDs {
            items.events.removeAll { $0.id == id }
            items.bands.removeAll { $0.id == id }
            items.deadlines.removeAll { $0.id == id }
            items.richById[id] = nil
            if selectedId == id { selectedId = nil }
        }
        let state = PersistedState(events: items.events, bands: items.bands, deadlines: items.deadlines, monthTrackNames: items.trackNames, rich: items.richById, dailyNotes: items.dailyNotes)
        store.save(state)
        syncedState = state   // adopt as baseline so the merge doesn't re-emit as a local delta
        if !deletedIDs.isEmpty { onExternalDataChange?() }   // a remote delete may have removed an open item
    }

    private static func upsert<T: Identifiable>(_ arr: inout [T], _ item: T) where T.ID == String {
        if let i = arr.firstIndex(where: { $0.id == item.id }) { arr[i] = item } else { arr.append(item) }
    }

    // ── Track names (editable lane labels, per month) ─────────────────────────────
    public func setTrackName(_ month: Int, _ track: Int, _ name: String) {
        guard month >= 0, month < items.trackNames.count, track >= 0, track < items.trackNames[month].count,
              items.trackNames[month][track] != name else { return }
        beginTxn()
        items.trackNames[month][track] = name
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
    func schedulePersist() {   // internal: +Extensions files persist too
        wake()   // universal edit chokepoint (covers non-txn setters: notes, rich fields, daily notes)
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistNow() }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// In keyboard block-cursor mode, the cursor drives the SAME soft highlight the mouse produces
    /// (year → whole month; month → the day column) — so `hover` is derived from the block position
    /// instead of the mouse. nil → fall back to the real mouse `hover`.
    private func blockHoverOverride() -> Hover? {
        guard cursor.keyboardActive, selectedId == nil, !drawerOpen else { return nil }
        if let t = cursor.trackNameCursor { return Hover(track: t) }   // track-name cursor: highlight its lane
        if cursor.bandCursorActive {   // band cursor: the month/week crosshair (lane + day)
            switch level(z) {
            case 0:  return Hover(month: cursor.blockMonth, dom: cursor.blockDay, track: cursor.bandCurTrack)
            case 1, 2: return Hover(dom: cursor.blockDay, track: cursor.bandCurTrack)
            default: return nil   // day view: ring only
            }
        }
        switch level(z) {
        case 0:  return Hover(month: cursor.blockMonth)
        case 1:  return Hover(dom: cursor.blockDay)
        case 2, 3:  // day column (soft) + hour cell (strong), matching a mouse hover
            return Hover(dom: level(z) == 2 ? cursor.blockDay : daily.dom, hour: Int(cursor.blockHour.rounded()))
        default: return nil
        }
    }

    // ── Frame snapshot ──────────────────────────────────────────────────────────
    func snapshot() -> SceneInput {
        SceneInput(z: z, focus: focus, week: week, vp: viewport, scrollY: scrollY, tlScroll: tlScroll,
                   now: now, year: year, hover: blockHoverOverride() ?? hover, weekHourH: weekHourH, daily: daily,
                   monthAnim: anim.monthAnim, altDeltaHours: altDeltaHours, altLabel: altColumnLabel,
                   yearPull: scroll.yearPull, flipFade: anim.flipFade,
                   animating: anim.tween != nil || anim.scrollTween != nil || anim.tlScrollTween != nil || anim.weekTween != nil || anim.dayTween != nil || anim.flipAnim != nil || anim.monthAnim != nil || anim.weekFlip != nil || anim.dayFlip != nil,
                   monthPull: scroll.monthPull, monthFlipShift: anim.monthFlipShift, weekPull: scroll.weekPull,
                   weekFlipDir: anim.weekFlip?.dir ?? 0, weekFlipFade: anim.weekFlipFade, dayPull: scroll.dayPull, mainTz: mainTz)
    }

    /// Read-only current scene input (does NOT advance tweens). For a second view that must render the
    /// same frame the main TimelineView already computed — e.g. the lifted-event copy above the scrim.
    public func snapshotInput() -> SceneInput { snapshot() }

    /// Advance the anim.tween to `date` and return the immutable input for this frame.
    public func sceneInput(at date: Date, viewport vp: Viewport) -> SceneInput {
        viewport = vp
        if let t = anim.tween {
            z = t.value(at: date)
            let done = t.isComplete(at: date)
            if done { z = t.to; anim.tween = nil }
            // hourH (and thus maxScroll) changes with z. Hold the anchor hour centred so the focus area
            // doesn't drift + snap as you zoom between week and month (a fixed-pixel scroll would map to a
            // moving hour). Also resyncs the driver. Release the anchor once the zoom settles.
            applyZoomAnchor(at: z)
            if done {
                anim.zoomAnchorHour = nil; anim.zoomAnchorY = nil
                if let cb = anim.zTweenDone { anim.zTweenDone = nil; cb() }   // sequenced next phase (e.g. go-to-today)
                if level(z) == 3 { fireDayLand() }                  // a jumpToDay landed at day view
            }
        }
        if let st = anim.scrollTween {
            scrollY = st.value(at: date); onSetYearScroll?(scrollY)
            if st.isComplete(at: date) {
                scrollY = st.to; anim.scrollTween = nil; onSetYearScroll?(scrollY)
                if let cb = anim.scrollTweenDone { anim.scrollTweenDone = nil; cb() }   // then zoom in
            }
        }
        if let tt = anim.tlScrollTween {
            tlScroll = tt.value(at: date); onSetTlScroll?(tlScroll)
            if tt.isComplete(at: date) { tlScroll = tt.to; anim.tlScrollTween = nil; onSetTlScroll?(tlScroll) }
        }
        if let wt = anim.weekTween {
            week = wt.value(at: date)
            if wt.isComplete(at: date) {
                week = wt.to; anim.weekTween = nil
                if let cb = anim.weekTweenDone { anim.weekTweenDone = nil; cb() }   // sequenced next phase (go-to-today)
            }
        }
        if let dt = anim.dayTween {
            // Fractional-day glide: floor → the anchor day, the fraction → a ±1 day-page so the day column
            // pans + cross-fades toward today (same visual as a manual day scroll), engine-side only.
            let dim = daysInMonth(year, focus)
            if dt.isComplete(at: date) {
                daily.dom = max(1, min(dim, Int(dt.to.rounded()))); daily.anim = nil; anim.dayTween = nil
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
        if let st = anim.shiftTween {
            drawerShift = st.value(at: date)
            if st.isComplete(at: date) { drawerShift = st.to; anim.shiftTween = nil }
        }
        if let fa = anim.flipAnim { advanceFlip(fa, at: date) }
        if let mf = anim.monthFlip { advanceMonthFlip(mf, at: date) }
        if let wf = anim.weekFlip { advanceWeekFlip(wf, at: date) }
        if let df = anim.dayFlip { advanceDayFlip(df, at: date) }
        return snapshot()
    }

    public func setViewport(_ size: CGSize) {
        let vp = Viewport(w: size.width - Layout.padLeft - Layout.padRight, h: size.height)
        // No-op guard: AppKit calls CatcherView.layout() (→ setViewport) on EVERY display cycle while the
        // calendar renders, and `sceneInput` already keeps `viewport` current each frame. Waking on a
        // same-size call created a layout→wake→render→layout feedback loop that pinned the CPU and
        // defeated the idle pause. Only act on a real resize (or the first layout).
        if scroll.didInitialScroll, vp.w == viewport.w, vp.h == viewport.h { return }
        wake()   // genuine resize / initial layout → re-render the scene
        viewport = vp
        if !scroll.didInitialScroll, viewport.h > 1 {
            scroll.didInitialScroll = true          // once: center today's month (clamped to top/bottom).
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
        wake()
        let tWeek = CGFloat((firstDOW(ty, tm) + td - 1) / 7)
        cancelTween(); anim.flipAnim = nil
        anim.zTweenDone = nil; anim.weekTweenDone = nil; anim.flipDone = nil; anim.scrollTweenDone = nil
        anim.dayLandDone = onLand

        // At the year layout: set focus/week/day, GLIDE the vertical scroll to centre the target month
        // (avoids the old instant snap), then zoom in. Used by every path that routes through the year.
        let flyFromYear: () -> Void = { [weak self] in
            guard let self else { return }
            self.placeDayAtYear(ty, tm, td, tWeek)
            let target = clamp(self.centerScroll(for: tm), 0, yearMaxScroll(self.viewport))
            if abs(target - self.scrollY) < 1 {
                self.tweenZ(to: 3, dur: 1.05)                    // already centred → zoom straight in
            } else {
                self.anim.scrollTween = Tween(from: self.scrollY, to: target, start: Date(), duration: 0.5, ease: easeInOut)
                self.anim.scrollTweenDone = { [weak self] in self?.tweenZ(to: 3, dur: 1.05) }
            }
        }
        let flyOutThenIn: () -> Void = { [weak self] in   // zoom OUT to the year, then fly in
            guard let self else { return }
            if self.level(self.z) == 0 { flyFromYear() }
            else { self.anim.zTweenDone = flyFromYear; self.tweenZ(to: 0, dur: 0.58) }
        }

        // ── Cross-year: out to the year, ONE flip to the target year (skips intervening years), then in. ──
        if ty != year {
            let dir = ty > year ? 1 : -1
            let startFlip: () -> Void = { [weak self] in
                guard let self else { return }
                self.anim.flipDone = flyFromYear
                self.anim.flipAnim = FlipAnim(dir: dir, fromYear: self.year, toYear: ty, startScroll: self.scrollY, start: Date())
            }
            if level(z) == 0 { startFlip() }
            else { anim.zTweenDone = startFlip; tweenZ(to: 0, dur: 0.58) }
            return
        }

        // ── Same year. ──
        let sameMonth = focus == tm
        switch level(z) {
        case 3:   // day view
            if sameMonth {                       // glide the day strip to the target (no zoom out)
                if daily.dom == td { fireDayLand(); break }
                let dist = abs(td - daily.dom)
                anim.dayTween = Tween(from: CGFloat(daily.dom), to: CGFloat(td), start: Date(),
                                 duration: min(0.7, 0.2 + 0.035 * Double(dist)), ease: easeInOut)
            } else { flyOutThenIn() }
        case 2:   // week view
            if weekContains(tm, td) {            // target is on screen → zoom straight into it
                daily.dom = td; pushChrome(); chrome.dailyResync &+= 1
                tweenZ(to: 3, dur: 0.7)
            } else if sameMonth {                // scroll to its week, then zoom in
                daily.dom = td
                anim.weekTween = Tween(from: week, to: tWeek, start: Date(), duration: 0.32, ease: easeInOut)
                anim.weekTweenDone = { [weak self] in self?.tweenZ(to: 3, dur: 0.7) }
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
        daily.anim = nil; anim.monthAnim = nil; anim.weekTween = nil; anim.weekFlip = nil
        pushChrome()
        chrome.monthResync &+= 1; chrome.weekResync &+= 1; chrome.dailyResync &+= 1
    }

    /// Programmatic view navigation for the assistant's `set_view` tool. Mirrors the web set_view:
    /// optionally switch year, focus a month (0-based), and/or zoom to a named level. Unspecified
    /// arguments are left unchanged. UI-only — moves the view, never mutates data.
    public func setView(year targetYear: Int? = nil, zoom: String? = nil, focusedMonth: Int? = nil,
                        day: Int? = nil) {
        wake()
        // A concrete day → fly straight there (jumpToDay handles cross-year travel, focus, and
        // landing in the day view). The day IS the destination; other args just refine it.
        if let d = day {
            let ty = targetYear ?? year
            let m = max(0, min(11, focusedMonth ?? focus))
            jumpToDay(ty, m, max(1, min(daysInMonth(ty, m), d)))
            return
        }
        if let ty = targetYear, ty != year { selectYear(ty) }
        if let m = focusedMonth, (0...11).contains(m) {
            focus = m
            chrome.monthResync &+= 1   // land the pager on the newly-focused month
        }
        switch zoom?.lowercased() {
        case "year":  zoomToYear()
        case "month": zoomToMonth()
        case "week":  zoomToWeek()
        case "day":   tweenZ(to: 3)
        default:      break
        }
    }

    /// Jump to another calendar year. Resets vertical scroll to the top, like the web's selectYear.
    public func selectYear(_ y: Int) {
        guard y != year, !isFlipping else { return }
        wake()
        // Don't swap instantly: fade the whole year out, swap the data at the midpoint, fade
        // the new year in (a pure cross-fade, no scroll motion — see advanceFlip's fadeOnly path).
        anim.flipAnim = FlipAnim(dir: 0, fromYear: year, toYear: y, startScroll: scrollY, start: Date(), fadeOnly: true)
    }

    // ── Levels + anim.tween helpers ────────────────────────────────────────────────────
    func level(_ z: CGFloat) -> Int { z < 0.5 ? 0 : (z < 1.5 ? 1 : (z < 2.5 ? 2 : 3)) }

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
        // Breadcrumb "most visible" month/day: once a month page (or day page) is more than halfway in,
        // the crumb shows the incoming one — so it updates mid-animation, not on landing. (A year-edge
        // flip swaps `focus`/`daily.dom` at its own midpoint, so this tracks those too.)
        let df = anim.monthAnim.map { $0.p >= 0.5 ? min(11, max(0, focus + $0.dir)) : focus } ?? focus
        if chrome.displayFocus != df { chrome.displayFocus = df }
        let dd = daily.anim.map { $0.p >= 0.5 ? min(daysInMonth(year, focus), max(1, daily.dom + $0.dir)) : daily.dom } ?? daily.dom
        if chrome.displayDom != dd { chrome.displayDom = dd }
    }

    func cancelTween() {
        if let t = anim.tween { z = t.value(at: Date()); anim.tween = nil }
        if let st = anim.scrollTween { scrollY = st.value(at: Date()); anim.scrollTween = nil }
        if let wt = anim.weekTween { week = wt.value(at: Date()); anim.weekTween = nil }
        if anim.dayTween != nil { anim.dayTween = nil; daily.anim = nil }   // settle a day-glide on its current day
        anim.zoomAnchorHour = nil; anim.zoomAnchorY = nil   // interrupted zoom → drop the anchor; next zoom recaptures
        snapWork?.cancel()
    }

    // (zoom anchor helpers live near sceneInput)

    private func scheduleWeekSnap(_ maxWeek: CGFloat) {
        snapWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let target = clamp((self.week * 7).rounded() / 7, 0, maxWeek)
            self.anim.weekTween = Tween(from: self.week, to: target, start: Date(), duration: 0.2, ease: easeInOut)
        }
        snapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    public func tweenZ(to target: CGFloat, dur: TimeInterval? = nil) {
        wake()
        if anim.zoomAnchorHour == nil { captureZoomAnchor() }   // fresh for a button/click zoom; kept for a pinch settle
        anim.tween = Tween(from: z, to: clamp(target, 0, 3), start: Date(), duration: dur ?? ZOOM_DUR, ease: easeInOut)
        pushChrome(level: level(clamp(target, 0, 3)))
    }

    // ── Gestures ──────────────────────────────────────────────────────────────────
    public func onWheel(dx: CGFloat, dy: CGFloat) {
        wake()
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
            anim.weekTween = nil
            let maxWeek = CGFloat(max(0, weeksInMonth(year, focus) - 1))
            week = clamp(week - dx / (viewport.w - Layout.labelW), 0, maxWeek)  // swipe-left → later days
            scheduleWeekSnap(maxWeek)
        } else if b == 3 {
            scroll.wheelAccumX += dx
            if abs(scroll.wheelAccumX) > 55 {
                daily.dom = min(daysInMonth(year, focus), max(1, daily.dom + (scroll.wheelAccumX < 0 ? 1 : -1)))  // swipe-left → next day
                scroll.wheelAccumX = 0
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
    public func setTlScroll(_ y: CGFloat) { wake(); tlScroll = y }

    // ── Year-view scroll: mirror of the native NSScrollView driver ───────────────────
    public var isYearLevel: Bool { level(z) == 0 }

    /// Fingers-down phase begins. Record whether we were already resting at an edge —
    /// a flip is only allowed for a pull that STARTS from the edge (not a fast scroll
    /// from the middle that happens to overshoot into it).
    public func beginYearScrollGesture() {
        wake()
        scroll.liveScrolling = true
        let maxY = yearMaxScroll(viewport)
        scroll.startedAtTop = scrollY <= 2
        scroll.startedAtBottom = scrollY >= maxY - 2
    }

    /// Mirror the scroll view's live offset (may be < 0 or > maxScroll during elastic
    /// overscroll, which is exactly what gives the native bounce). Computes the pull
    /// hint only while a finger-driven gesture is live.
    public func setYearScroll(_ y: CGFloat) {
        wake()
        scrollY = y
        let maxY = yearMaxScroll(viewport)
        let over: CGFloat = y < 0 ? -y : (y > maxY ? y - maxY : 0)
        let atTop = y < 0
        scroll.lastOverscroll = (over, atTop)
        if scroll.liveScrolling, over > 2 {
            let eligible = (atTop && scroll.startedAtTop) || (!atTop && scroll.startedAtBottom)
            let target = atTop ? year - 1 : year + 1
            scroll.yearPull = eligible
                ? YearPull(targetYear: target, atTop: atTop, over: over, armed: over >= Layout.yearFlipOver) : nil
        } else {
            scroll.yearPull = nil
        }
    }

    /// Fingers lifted — if the pull passed the threshold, flip the year (landing on the
    /// continuous edge: prev→bottom, next→top). Otherwise the scroll view bounces back
    /// natively and we do nothing.
    public func endYearScrollGesture() {
        scroll.liveScrolling = false
        scroll.yearPull = nil
        guard yearFlipEnabled, !isFlipping else { return }
        let (over, atTop) = scroll.lastOverscroll
        guard over >= Layout.yearFlipOver else { return }
        guard (atTop && scroll.startedAtTop) || (!atTop && scroll.startedAtBottom) else { return }  // must start from the edge
        let dir = atTop ? -1 : 1
        let target = year + dir            // unbounded — flip any number of years
        anim.flipAnim = FlipAnim(dir: dir, fromYear: year, toYear: target, startScroll: scrollY, start: Date())
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
                year = fa.toYear; anim.flipFade = 1; anim.flipAnim = nil
                pushChrome()
                if let cb = anim.flipDone { anim.flipDone = nil; cb() }
                return
            }
            if t < 0.5 {                                     // outgoing year fades out
                let p = t / 0.5
                if year != fa.fromYear { year = fa.fromYear; pushChrome() }
                anim.flipFade = 1 - easeInOut(p)
            } else {                                         // swap data, incoming year fades in
                let p = (t - 0.5) / 0.5
                if year != fa.toYear {
                    year = fa.toYear; scrollY = 0; onSetYearScroll?(0); pushChrome()
                }
                anim.flipFade = easeInOut(p)
            }
            return
        }
        let vpH = viewport.h
        let maxY = yearMaxScroll(viewport)
        let dir = CGFloat(fa.dir)
        let rest: CGFloat = fa.dir > 0 ? 0 : maxY        // where the new year settles
        let t = clamp(CGFloat(date.timeIntervalSince(fa.start) / FLIP_DUR), 0, 1)
        if t >= 1 {
            year = fa.toYear; scrollY = rest; anim.flipFade = 1; anim.flipAnim = nil
            pushChrome(); onSetYearScroll?(rest)         // resync the scroll-view driver
            if let cb = anim.flipDone { anim.flipDone = nil; cb() }   // sequenced next phase (go-to-today)
            return
        }
        if t < 0.5 {                                     // outgoing year exits + fades
            let p = t / 0.5
            if year != fa.fromYear { year = fa.fromYear; pushChrome() }
            scrollY = fa.startScroll + dir * easeInOut(p) * vpH
            anim.flipFade = 1 - p
        } else {                                         // incoming year enters + fades
            let p = (t - 0.5) / 0.5
            if year != fa.toYear { year = fa.toYear; pushChrome() }
            let enter = rest - dir * vpH                 // from the opposite edge (off-screen)
            scrollY = enter + (rest - enter) * easeOut(p)
            anim.flipFade = p
        }
    }

    // ── Month view: vertical month↕month paging, driven by an invisible SwiftUI ScrollView ──
    // A hidden SwiftUI `ScrollView` with 12 page cells and `.scrollTargetBehavior(.paging)` does
    // the real work: native velocity-aware paging + the settle animation. We just observe its
    // absolute content offset (via `.onScrollGeometryChange`) and convert it to (focus, anim.monthAnim).
    // No snap anim.tween / recentre here — SwiftUI owns the physics; this is a pure projection.
    public var isMonthLevel: Bool { level(z) == 1 }

    /// The offset the pager should sit at to show the current focus month (`focus` whole pages in).
    public func monthPagerOffset(pageH: CGFloat) -> CGFloat { CGFloat(focus) * pageH }

    /// A scroll gesture starts — kill any zoom anim.tween so they don't fight.
    public func beginMonthGesture() { wake(); cancelTween(); scroll.liveMonthScrolling = true }

    // ── Week view: horizontal day/week paging, driven by an invisible SwiftUI ScrollView ──
    // Same construct as the month pager, rotated horizontal: a strip of day cells + a custom
    // ScrollTargetBehavior that snaps to a day (small scroll) or a week boundary (large scroll).
    // Month-scoped for now — `week` is clamped to the month; crossing the edge (a flip) is TODO.
    public var isWeekLevel: Bool { level(z) == 2 }
    public var isDayLevel: Bool { level(z) == 3 }
    /// Day-view split: the timeline's width as a fraction of the content area (the rest is the daily
    /// dashboard). Driven by the drag handle on the timeline↔dashboard boundary; clamped so neither
    /// side collapses.
    public func setDailyFrac(_ f: CGFloat) { wake(); daily.frac = clamp(f, 0.22, 0.82); chrome.dailyResync &+= 1 }
    /// True when the current overscroll pull has passed the flip threshold — peeked on fingers-up so
    /// the catcher can withhold `.ended` from the pager (preventing a stale snap animation).
    public var weekFlipArmed: Bool { isWeekLevel && (scroll.weekPull?.armed ?? false) }
    public var monthFlipArmed: Bool { isMonthLevel && (scroll.monthPull?.armed ?? false) }

    /// The pager offset that shows the current `week` (fractional weeks × the 7-day grid width).
    public func weekPagerOffset(dayW: CGFloat) -> CGFloat { week * 7 * dayW }

    public func beginWeekGesture() { wake(); cancelTween(); anim.weekTween = nil; scroll.liveWeekScrolling = true }

    public func beginDayGesture() { wake(); cancelTween(); scroll.liveDayScrolling = true }

    /// Project the day pager's horizontal offset onto (daily.dom, daily.anim). Each day cell is `dayW`
    /// wide (the day column's own width), so `offsetX / dayW` is a continuous day index: `daily.dom` is
    /// the anchored day and the fractional remainder becomes the slide progress. Past a month edge the
    /// (AppKit-rubber-banded) offset runs negative / beyond max; there we PREVIEW the neighbor month's
    /// first/last day sliding in (via the spillover day-page: day 0 / day dim+1) and arm a flip.
    public func setDayProgress(_ offsetX: CGFloat) {
        guard isDayLevel, !isDayFlipping else { return }
        wake()
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
        if scroll.liveDayScrolling, overLeft > 2 || overRight > 2 {
            let dir = overRight > 0 ? 1 : -1
            let over = dir > 0 ? overRight : overLeft
            let tm = dir > 0 ? (focus + 1) % 12 : (focus + 11) % 12
            let ty = dir > 0 ? (focus == 11 ? year + 1 : year) : (focus == 0 ? year - 1 : year)
            scroll.dayPull = DayPull(dir: dir, over: over, armed: over >= dayFlipOver, targetMonth: tm, targetYear: ty)
        } else {
            scroll.dayPull = nil
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
        scroll.daySettleWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.settleDay() }
        scroll.daySettleWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: w)
    }
    private func settleDay() {
        // Only rescue a residual once the gesture is genuinely OVER — never snap while fingers are still
        // on the trackpad (a mid-scroll pause). The catcher now marks `scroll.liveDayScrolling` for the whole
        // finger-down phase — direct AND webview-forwarded — and clears it on `.ended` (which also
        // schedules this settle), so this gate cleanly separates "paused mid-scroll" from "done".
        guard isDayLevel, !isDayFlipping, anim.dayTween == nil, !scroll.liveDayScrolling else { return }
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
        scroll.liveDayScrolling = false
        let pull = scroll.dayPull
        scroll.dayPull = nil
        if let pull, pull.armed, !isDayFlipping, isDayLevel {
            let toDom = pull.dir > 0 ? 1 : daysInMonth(pull.targetYear, pull.targetMonth)
            anim.dayFlip = DayFlip(dir: pull.dir, toYear: pull.targetYear, toFocus: pull.targetMonth,
                              toDom: toDom, startP: daily.anim?.p ?? 0, start: Date())
            return true
        }
        scheduleDaySettle()   // fingers up, no flip → settle any residual once the pager's momentum stops
        return false
    }

    /// Per-frame day-flip. `focus` is HELD at the from-month while the day-page eases to completion —
    /// the incoming neighbor day is drawn as the spillover day (day 0 / dim+1), so it's already the
    /// real neighbor date. At p=1 we commit: swap focus/year/day to the neighbor and re-sync the pager
    /// (and the year-view scroll, so zooming out lands on the new month).
    private func advanceDayFlip(_ df: DayFlip, at date: Date) {
        let t = clamp(CGFloat(date.timeIntervalSince(df.start) / DAY_FLIP_DUR), 0, 1)
        if t >= 1 {
            year = df.toYear; focus = df.toFocus; daily.dom = df.toDom
            daily.anim = nil; daily.over = 0; anim.dayFlip = nil   // END the flip (else it re-commits every frame)
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
        wake()
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
        if scroll.liveWeekScrolling, overLeft > 2 || overRight > 2 {
            let dir = overRight > 0 ? 1 : -1
            let over = dir > 0 ? overRight : overLeft
            let fdow = firstDOW(year, focus)
            let dim = daysInMonth(year, focus)
            // A boundary week is "shared" (dim-swap) when it holds spillover from the neighbor:
            // the right edge shares unless the month ends on Saturday; the left unless it starts Sunday.
            let shared = dir > 0 ? ((fdow + dim - 1) % 7 != 6) : (fdow != 0)
            let tm = dir > 0 ? (focus + 1) % 12 : (focus + 11) % 12
            let ty = dir > 0 ? (focus == 11 ? year + 1 : year) : (focus == 0 ? year - 1 : year)
            scroll.weekPull = WeekPull(dir: dir, over: over, armed: over >= weekFlipOver,
                                shared: shared, targetMonth: tm, targetYear: ty)
        } else {
            scroll.weekPull = nil
        }
        pushChrome()
    }

    /// Project the pager's absolute content offset onto (focus, anim.monthAnim). The page cells are
    /// `pageH` tall, so `offsetY / pageH` is a continuous month index; `focus` is the anchored
    /// month and the fractional remainder becomes the page-turn progress. `focus` advances as the
    /// offset crosses each page boundary, so a multi-page fling walks through the months in order.
    public func setMonthProgress(_ offsetY: CGFloat, pageH: CGFloat) {
        guard isMonthLevel, !isMonthFlipping, pageH > 0 else { return }
        wake()
        let startFocus = focus
        var norm = offsetY / pageH - CGFloat(focus)
        while norm >= 1, focus < 11 { focus += 1; norm -= 1 }   // crossed into the next month
        while norm <= -1, focus > 0 { focus -= 1; norm += 1 }   // crossed into the previous month
        if focus >= 11 { norm = min(0, norm) }                  // Dec: clamp elastic overscroll
        if focus <= 0 { norm = max(0, norm) }                   // Jan
        anim.monthAnim = abs(norm) < 0.001 ? nil
            : PageAnim(dir: norm > 0 ? 1 : -1, p: min(1, abs(norm)))
        // Elastic overscroll past Jan (top) / Dec (bottom) arms a cross-year flip. The pager
        // document is [0, 11·pageH]; a live drag can push the offset outside that, and paging
        // caps one page per gesture so this only fires when already resting at the boundary.
        let maxOff = CGFloat(11) * pageH
        let overTop = offsetY < 0 ? -offsetY : 0
        let overBot = offsetY > maxOff ? offsetY - maxOff : 0
        // Elastic: the month follows the (AppKit-rubber-banded) overscroll and snaps back with it.
        anim.monthFlipShift = overTop > 0 ? overTop : (overBot > 0 ? -overBot : 0)
        if scroll.liveMonthScrolling, overTop > 2 || overBot > 2 {
            let atTop = overTop > 0
            scroll.monthPull = YearPull(targetYear: atTop ? year - 1 : year + 1, atTop: atTop,
                                 over: atTop ? overTop : overBot, armed: (atTop ? overTop : overBot) >= Layout.yearFlipOver)
        } else {
            scroll.monthPull = nil
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
        scroll.liveMonthScrolling = false
        let pull = scroll.monthPull
        scroll.monthPull = nil
        guard let pull, pull.armed, !isMonthFlipping, isMonthLevel else { return }
        let dir = pull.atTop ? -1 : 1
        anim.monthFlip = MonthFlip(dir: dir, fromYear: year, fromFocus: focus,
                              toYear: year + dir, toFocus: dir < 0 ? 11 : 0,
                              startShift: anim.monthFlipShift, start: Date())   // continue from the elastic pull
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
            anim.monthFlipShift = 0; anim.flipFade = 1; anim.monthFlip = nil
            scrollY = clamp(centerScroll(for: focus), 0, yearMaxScroll(viewport))
            onSetYearScroll?(scrollY)          // new year → keep the year-view scroll in step
            pushChrome()
            return
        }
        if t < 0.5 {                                    // outgoing month exits + fades
            let p = t / 0.5
            if year != mf.fromYear || focus != mf.fromFocus { year = mf.fromYear; focus = mf.fromFocus }
            anim.monthFlipShift = lerp(mf.startShift, dir < 0 ? OFF : -OFF, easeInOut(p))  // continue from the pull
            anim.flipFade = 1 - p
        } else {                                        // incoming (cross-year) month enters + fades
            let p = (t - 0.5) / 0.5
            if year != mf.toYear || focus != mf.toFocus {
                year = mf.toYear; focus = mf.toFocus
                pushChrome()
                chrome.monthResync += 1               // re-sync the (guarded) pager to the new focus
            }
            let enter = dir < 0 ? -OFF : OFF           // prev → Dec from top; next → Jan from bottom
            anim.monthFlipShift = enter * (1 - easeOut(p))
            anim.flipFade = p
        }
    }

    /// Fingers lifted in week view. If a boundary pull passed the threshold, launch the month-edge
    /// flip: the focus/week re-anchor to the neighbor month and the dim/bright split cross-fades.
    /// Returns true if a flip started (so the catcher can swallow the fling's trailing momentum).
    @discardableResult
    public func endWeekGesture() -> Bool {
        scroll.liveWeekScrolling = false
        let pull = scroll.weekPull
        scroll.weekPull = nil
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
        anim.weekFlipFade = 0
        anim.weekFlip = WeekFlip(dir: pull.dir, startWeek: startWeek, toWeek: toWeek, start: Date())
        // Keep the year-view scroll in step with the month we flipped into (exactly as month paging
        // does), so zooming out lands on this month — and one more zoom-out centers it in the year.
        scrollY = clamp(centerScroll(for: focus), 0, yearMaxScroll(viewport))
        onSetYearScroll?(scrollY)
        pushChrome()
        return true
    }

    /// Per-frame week-flip. The anchor already swapped to the destination month on release; here the
    /// window just eases from the overscrolled `startWeek` back to `toWeek` while `anim.weekFlipFade` 0→1
    /// drives `spillFactor`'s dim/bright cross-fade. At t=1 we settle and re-sync the pager.
    private func advanceWeekFlip(_ wf: WeekFlip, at date: Date) {
        let t = clamp(CGFloat(date.timeIntervalSince(wf.start) / WEEK_FLIP_DUR), 0, 1)
        if t >= 1 {
            week = wf.toWeek
            anim.weekFlipFade = 0; anim.weekFlip = nil
            onSetWeekScroll?(weekOffset(week))   // pin the pager to rest BEFORE the guard lifts (no stray callback)
            pushChrome()
            chrome.weekResync += 1
            return
        }
        week = lerp(wf.startWeek, wf.toWeek, easeOut(t))   // settle the window (bounce-back)
        anim.weekFlipFade = easeInOut(t)                        // cross-fade the events (after the text swap)
        onSetWeekScroll?(weekOffset(week))                 // pin the (invisible) pager each frame so its
                                                           // own snap/decelerate animation can't diverge → twitch
    }

    public func onMagnify(delta: CGFloat, at p: CGPoint, began: Bool, ended: Bool) {
        wake()
        if began {
            cancelTween()              // clears any held anchor; recapture fresh for this gesture
            anim.monthAnim = nil            // a pinch overrides an in-flight month page
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
        guard tl.hourH > 0 else { anim.zoomAnchorHour = nil; anim.zoomAnchorY = nil; return }
        if tl.maxScroll >= 1 {
            // Week (has scroll freedom) → a real focal hour: hold the current centre hour.
            anim.zoomAnchorHour = (tlScroll + tl.viewH / 2) / tl.hourH; anim.zoomAnchorY = nil
        } else if weekContainsToday() {
            // Whole-day fit AND we're going into today's week → lean toward the current time (centred).
            anim.zoomAnchorHour = nowFrac(); anim.zoomAnchorY = nil
        } else if let py = pointerY, py > tl.tlTop, py < tl.tlBottom {
            // Whole-day fit, another week → anchor the hour under the cursor and keep it under the cursor.
            anim.zoomAnchorHour = (py - tl.tlTop + tl.scroll) / tl.hourH; anim.zoomAnchorY = py
        } else {
            anim.zoomAnchorHour = 12; anim.zoomAnchorY = nil   // no pointer over the timeline → neutral midday centre
        }
    }

    /// Rescale `tlScroll` so the held anchor hour stays at `anim.zoomAnchorY` (centre if nil) at zoom `newZ`,
    /// clamped in range. The focus-month timeline viewport is stable across the month↔week zoom, so only
    /// `hourH` changes: y = tlTop + hour·hourH − scroll ⇒ scroll = hour·hourH − (anchorY − tlTop).
    private func applyZoomAnchor(at newZ: CGFloat) {
        guard let anchor = anim.zoomAnchorHour else { return }
        var g = snapshot(); g.z = newZ
        let tl = timelineInfo(g)
        guard tl.hourH > 0 else { return }
        let anchorY = anim.zoomAnchorY ?? (tl.tlTop + tl.viewH / 2)
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
        // The now-line sits at the current instant expressed in the VIEW (main) timezone, so it lines up
        // with events once they're converted into that zone (not the device zone, which may differ).
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: DeadlineTZ.iana(mainTz)) ?? .current
        let c = cal.dateComponents([.hour, .minute], from: now)
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
        wake()
        commitTxn()   // flush any pending (e.g. drawer typing) before a new gesture
        cancelTween()
        let g = snapshot()
        let prior = selectedId   // decide deselect-vs-navigate on a plain click (see onPointerUp)
        // 1. all-day bands (on the lanes) — selectable at every zoom incl. year view
        if let hit = bandAt(p, g) {
            selectedId = hit.id
            drag = Drag(kind: hit.zone, startPoint: p, eventId: hit.id,
                        origBand: items.bands.first { $0.id == hit.id }, priorSelection: prior)
            return
        }
        // 2. timed events (on the timeline)
        if z >= 1.5, let hit = eventAt(p, g) {
            selectedId = hit.id
            drag = Drag(kind: hit.zone, startPoint: p, eventId: hit.id, orig: items.events.first { $0.id == hit.id },
                        priorSelection: prior, titleHit: hit.overTitle)
            return
        }
        // 3. deadlines (on the timeline)
        if z >= DETAIL_Z, let id = deadlineAt(p, g) {
            selectedId = id
            drag = Drag(kind: .ddlMove, startPoint: p, eventId: id, origDdl: items.deadlines.first { $0.id == id })
            return
        }
        // 3b. deadline quick-add "+" (near a day's left edge, on an hour line) → create a deadline and
        //     open the drawer with its default title selected. Checked before the empty-timeline drag so
        //     a click on the "+" creates a deadline rather than starting a timed-event drag.
        if z >= 1.5, let spot = deadlineAddSpot(g), hypot(p.x - spot.x, p.y - spot.y) < 12 {
            let id = createDeadline(year: spot.year, month: spot.month, day: spot.day,
                                    hour: CGFloat(spot.hour), title: "New Deadline", color: "default")
            onRequestOpenDrawer?(id, true)
            drag = nil
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
        wake()
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
        wake()
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
            case .move:
                // click the TITLE of an ALREADY-selected timed event → edit its title inline (the I-beam
                // affordance). A click elsewhere on the body (grab) leaves it selected without editing.
                // Pass the click so the editor opens over the SEGMENT you clicked (a cross-midnight event
                // draws on several days), not always the first one.
                if d.priorSelection == d.eventId, d.titleHit, let id = d.eventId { editTimed(id, at: p) }
            default:
                break
            }
            return
        }
        // discard a too-small created timed event
        if d.kind == .create, let id = d.eventId, let e = items.events.first(where: { $0.id == id }), e.endHour - e.startHour < 0.25 {
            items.events.removeAll { $0.id == id }
            if selectedId == id { selectedId = nil }
        }
        // a freshly drag-created band → open its title editor so the name is focused for typing
        if d.kind == .bandCreate, let id = d.eventId, items.bands.contains(where: { $0.id == id }) {
            editBand(id)
        }
    }

    public func deleteSelected() {
        guard let id = selectedId else { return }
        beginTxn()
        items.events.removeAll { $0.id == id }
        items.bands.removeAll { $0.id == id }
        items.deadlines.removeAll { $0.id == id }
        selectedId = nil
        commitTxn()
    }

    // ── Undo / redo ───────────────────────────────────────────────────────────────
    // internal (not private): the CalendarEngine+*.swift extension files open/commit txns too.
    func beginTxn() { wake(); caches.editGen &+= 1; if pendingUndo == nil { pendingUndo = editState } }
    func commitTxn() {   // internal: +Extensions files commit txns too
        undoWork?.cancel(); undoWork = nil
        guard let snap = pendingUndo else { return }
        pendingUndo = nil
        guard snap != editState else { return }     // no-op edit → no entry
        caches.deadlineGen &+= 1                            // an edit committed → re-solve deadline label sides
        undoStack.append(snap)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        schedulePersist()
    }
    func scheduleCommit() {                    // coalesce a typing burst
        undoWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.commitTxn() }
        undoWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
    private func restore(_ s: EditState) {
        wake()
        caches.editGen &+= 1
        items.events = s.events; items.bands = s.bands; items.deadlines = s.deadlines
        items.richById = s.rich; items.trackNames = s.trackNames; items.dailyNotes = s.dailyNotes
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
        wake()
        anim.shiftTween = Tween(from: drawerShift, to: drawerShiftTarget(id: id, drawerWidth: D),
                           start: Date(), duration: DRAWER_SHIFT_DUR, ease: easeOut)
    }
    /// Slide the calendar back to rest when the drawer closes.
    public func closeDrawerShift() {
        wake()
        anim.shiftTween = Tween(from: drawerShift, to: 0, start: Date(), duration: DRAWER_SHIFT_DUR, ease: easeOut)
    }
    /// Re-solve the shift immediately (no anim.tween) while the drawer is being resized, so the
    /// canvas tracks the drag frame-for-frame (like the web's `.cc-drawer-resizing`).
    public func updateDrawerShift(id: String, drawerWidth D: CGFloat) {
        wake()
        anim.shiftTween = nil
        drawerShift = drawerShiftTarget(id: id, drawerWidth: D)
    }

    private func drawerShiftTarget(id: String, drawerWidth D: CGFloat) -> CGFloat {
        guard z < 2.5 else { return 0 }   // daily: dashboard owns the right
        // Center on the specific focused OCCURRENCE, not the series base. `selectedId` holds the
        // clicked box id (a recurrence occurrence carries a synthetic occKey), while `id` here is the
        // drawer's collapsed source id. Prefer the selected box when it belongs to this same series.
        let boxId = (selectedId.flatMap { sourceId(of: $0) == id ? $0 : nil }) ?? id
        // If we can't locate the box, DON'T shift — a bogus center (e.g. viewport middle) would
        // over-shift a left-edge item off-screen. With a real center the clamp keeps it on-screen.
        guard let X = itemCenterViewportX(boxId) else { return 0 }
        let W = viewport.w + Layout.padLeft + Layout.padRight        // window width
        // Place the event at the centre of the free area left of the drawer, (W − D)/2: shift left by
        // X − (W − D)/2; never shift right (≥ 0); never more than a drawer width (≤ D).
        return min(max(0, X - (W - D) / 2), D)
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
            let sameDay = eventsOn(year, e.month, e.day)
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

    /// Open the inline title editor for the timed event `id` (a ghost's source), over its box. The
    /// keyboard "Enter → edit title" and the click-a-selected-event gesture both route here.
    public func editTimed(_ id: String, at p: CGPoint? = nil) {
        let g = snapshot()
        let tl = timelineInfo(g)
        guard z >= 1.5, tl.reveal > 0.05, tl.hourH > 0 else { return }
        let src = sourceId(of: id)
        // Position over the DISPLAY event's segment the user is on. A cross-midnight event draws across
        // several day columns; the editor should open on the segment you clicked (`p`), not always the
        // first. Segmenting the display copy (not the stored seed) keeps this right under tz conversion too.
        guard let disp = viewEvents().first(where: { $0.id == id }) else { return }
        func rectFor(_ sev: TimedEvent) -> CGRect? {
            guard let r = eventRect(sev, year, focus, tl, g.vp, layoutDay(eventsOn(sev.year, sev.month, sev.day))[sev.id]) else { return nil }
            return CGRect(x: r.minX, y: tl.tlTop - tl.scroll + r.minY, width: r.width, height: r.height)
        }
        let segs = timedSegments(disp)
        let rect = (p.flatMap { pt in segs.lazy.compactMap { rectFor($0.event) }.first { $0.contains(pt) } })
            ?? segs.first.flatMap { rectFor($0.event) }
        guard let rect else { return }
        onEditTimed?(src, rect)
    }
    /// The kind of the selected BOX — every display box (base, occurrence ghost, promoted band) is an
    /// independent item, so the kind comes from which display array the *exact* box id is in, NOT from
    /// its source. A promoted band therefore selects as a band even though its source is a timed event.
    /// Band takes precedence so a promoted-recurring box (whose id can appear as both a band and a timed
    /// ghost) reads as the band you see. Drives which keyboard state we're in.
    private enum SelKind { case none, timed, band, deadline }
    private var selectedKind: SelKind {
        guard let s = selectedId else { return .none }
        if viewBands().contains(where: { $0.id == s }) { return .band }
        if viewEvents().contains(where: { $0.id == s }) { return .timed }
        if viewDeadlines().contains(where: { $0.id == s }) { return .deadline }
        return .none
    }
    public var selectedIsTimed: Bool { selectedKind == .timed }
    public var selectedIsBand: Bool { selectedKind == .band }
    public var selectedIsDeadline: Bool { selectedKind == .deadline }

    // ── Tab cycling between cursors (block ⇄ event; band cursor is a later increment) ──────────────
    // One-step inverse memory: the last block⇄event pairing. If a Tab is the exact inverse of the last,
    // we restore the remembered side instead of re-deriving via carry-over — so Tab then ⇧Tab round-trips
    // exactly even where carry-over is lossy (see docs/prompts/keyboard_control.md).
    private var tabLink: (month: Int, day: Int, hour: CGFloat, eventId: String)?

    private enum NavDomain { case block, band, event }
    private var currentDomain: NavDomain { selectedId != nil ? .event : (cursor.bandCursorActive ? .band : .block) }

    /// Tab / ⇧Tab cycle the cursor DOMAIN: block → band → event → block (⇧Tab reverses). Each step
    /// carries the position over (leftmost/earliest anchor) so the cycle round-trips.
    public func tabCursor(_ forward: Bool) {
        enterKeyboardMode()
        // Month view inserts 4 track-name stops between Event and Block (after Event, before wrapping).
        let inMonth = level(z) == 1
        if let t = cursor.trackNameCursor {
            if forward { if t < 3 { cursor.trackNameCursor = t + 1 } else { cursor.trackNameCursor = nil } }   // track 3 → block
            else if t > 0 { cursor.trackNameCursor = t - 1 }
            else {   // track 0 → event (⇧Tab); no event in view → skip the empty stop to the band cursor
                cursor.trackNameCursor = nil
                if let eid = nearestEventToBlock() { selectedId = eid; scrollToSelected() }
                else { cursor.bandCursorActive = true; cursor.bandCurTrack = 0 }
            }
            return
        }
        if inMonth {
            if selectedId != nil && forward { deselect(); cursor.trackNameCursor = 0; return }   // event → track 0
            if currentDomain == .block && !forward { cursor.trackNameCursor = 3; return }         // block ← track 3
        }
        // Day view inserts 2 dashboard stops (TODO, then NOTE) between Event and Block.
        let inDay = level(z) == 3
        if let s = cursor.dashStop {
            if forward {
                if s == .todo { cursor.dashStop = .note; onDashCommand?(.focus(.note)) }
                else { cursor.dashStop = nil; onDashCommand?(.focus(nil)); cursor.blockDay = daily.dom }   // note → block (wrap)
            } else {
                if s == .note { cursor.dashStop = .todo; onDashCommand?(.focus(.todo)) }
                else {                                                                        // todo → event (back)
                    cursor.dashStop = nil; onDashCommand?(.focus(nil))
                    if let eid = cursor.dashReturnEvent, isVisibleEvent(eid) { selectedId = eid }
                    else if let eid = nearestEventToBlock() { selectedId = eid }
                    if selectedId != nil { scrollToSelected() }
                    else { cursor.bandCursorActive = true; cursor.bandCurTrack = 0 }   // no event in view → skip the empty stop to band
                }
            }
            return
        }
        if inDay {
            if selectedId != nil && forward {   // event → TODO stop (remember it for the round-trip)
                cursor.dashReturnEvent = selectedId; deselect(); cursor.dashStop = .todo; onDashCommand?(.focus(.todo)); return
            }
            if currentDomain == .block && !forward { cursor.dashStop = .note; onDashCommand?(.focus(.note)); return }   // block ← NOTE
        }
        let from = currentDomain
        let to: NavDomain = forward
            ? (from == .block ? .band : (from == .band ? .event : .block))
            : (from == .block ? .event : (from == .event ? .band : .block))
        switch (from, to) {
        case (.block, .band), (.band, .block):   // block ⇄ band: same time cell, just add/drop the lane
            cursor.bandCursorActive = (to == .band)
            if to == .band { cursor.bandCurTrack = 0 }
        case (.band, .event):                     // band → the band under the cell, else the nearest timed/
            cursor.bandCursorActive = false              // deadline event (week/day), else skip the empty stop
            if let b = bandForCursor() { selectedId = b.id }
            else if let eid = nearestEventToBlock() { selectedId = eid; tabLink = (cursor.blockMonth, cursor.blockDay, cursor.blockHour, eid) }
            else { skipEventForward() }           // truly no event in view → skip the empty event stop
        case (.event, .band):                     // event → its start cell (band) or (lane 0, its day)
            if let sel = selectedId {
                if let b = displayBands(for: year).first(where: { $0.id == sel }) { cursor.blockMonth = b.month; cursor.bandCurTrack = b.track; cursor.blockDay = b.startDay }
                else if let e = displayEvents(for: year).first(where: { $0.id == sel }) { cursor.blockMonth = e.month; cursor.bandCurTrack = 0; cursor.blockDay = e.day }
                else if let d = displayDeadlines(for: year).first(where: { $0.id == sel }) { cursor.blockMonth = d.month; cursor.bandCurTrack = 0; cursor.blockDay = d.day }
            }
            selectedId = nil; cursor.bandCursorActive = true
            if level(z) == 0 { ensureMonthVisible(cursor.blockMonth, animated: true) }
        case (.event, .block):                    // event → its earliest anchor (with inverse memory)
            if let sel = selectedId {
                if let link = tabLink, link.eventId == sel { cursor.blockMonth = link.month; cursor.blockDay = link.day; cursor.blockHour = link.hour }
                else { setBlockToEventAnchor(sel) }
                tabLink = (cursor.blockMonth, cursor.blockDay, cursor.blockHour, sel)
            }
            selectedId = nil; cursor.bandCursorActive = false
            syncBlockVisible()
        case (.block, .event):                    // block → nearest event (with inverse memory)
            if let link = tabLink, link.month == cursor.blockMonth, link.day == cursor.blockDay,
               abs(link.hour - cursor.blockHour) < 0.01, isVisibleEvent(link.eventId) {
                selectedId = link.eventId
            } else if let eid = nearestEventToBlock() {
                selectedId = eid; tabLink = (cursor.blockMonth, cursor.blockDay, cursor.blockHour, eid)
            }
            if selectedId == nil { cursor.bandCursorActive = true; cursor.bandCurTrack = 0 }   // no event in view → skip the empty stop to the band cursor
        default: break
        }
        // Scroll whatever event we landed on into view: a timed/deadline event above or below the
        // timeline viewport (week/day) glides into sight; a band scrolls to its month/day. (req 2)
        if selectedId != nil { scrollToSelected() }
    }

    /// Forward Tab reached the event stop but found nothing to select → advance to the stop that follows
    /// the (empty) event stop in this view, so Tab never lands on a dead event cursor: month → the first
    /// track-name stop, day → the TODO stop, week/year → the block cursor (already the state here).
    private func skipEventForward() {
        switch level(z) {
        case 1: cursor.trackNameCursor = 0
        case 3: cursor.dashReturnEvent = nil; cursor.dashStop = .todo; onDashCommand?(.focus(.todo))
        default: break
        }
    }

    private func isVisibleEvent(_ id: String) -> Bool {
        viewBands().contains { $0.id == id } || viewEvents().contains { $0.id == id } || viewDeadlines().contains { $0.id == id }
    }

    /// The band the band-cursor cell sits on: the band covering `(month, track, day)`, else the nearest
    /// band in that month. Shared by Tab (band→event) and Enter-to-select.
    private func bandForCursor() -> BandEvent? {
        let m = level(z) == 0 ? cursor.blockMonth : focus
        let hit = viewBands().first { $0.month == m && $0.track == cursor.bandCurTrack && $0.startDay <= cursor.blockDay && $0.endDay >= cursor.blockDay }
        return hit ?? viewBands().filter { $0.month == m }
            .min(by: { (bandDayDist($0, cursor.blockDay), abs($0.track - cursor.bandCurTrack)) < (bandDayDist($1, cursor.blockDay), abs($1.track - cursor.bandCurTrack)) })
    }

    /// Enter from the band cursor (any view) or the block cursor (week/day) → enter event-cursor mode on
    /// the relevant event: the band under the band cell, else the nearest event to the block cell. Keeps
    /// the one-step Tab memory in sync so a following ⇧Tab round-trips back to the originating cell.
    public func selectFromCursor() {
        enterKeyboardMode()
        if cursor.bandCursorActive {
            if let b = bandForCursor() { cursor.bandCursorActive = false; selectedId = b.id; scrollToSelected() }
        } else if cursor.trackNameCursor == nil, level(z) >= 2 {   // block cursor — week/day only (per spec)
            if let eid = nearestEventToBlock() {
                selectedId = eid; tabLink = (cursor.blockMonth, cursor.blockDay, cursor.blockHour, eid); ensureSelectedEventVisible()
            }
        }
    }

    // ── View preferences ───────────────────────────────────────────────────────────────────────
    nonisolated public static let showHiddenImportedKey = "cc.view.showHiddenImported"
    /// View ▸ Current Timezone — the main tz for deadline origin-time labels. "auto" = device zone.
    nonisolated public static let mainTzKey = "cc.view.mainTz"
    /// The timeline scale-bar's per-hour height (week/day views). Persisted across launches.
    nonisolated public static let weekHourHKey = "cc.view.weekHourH"

    /// Set the week/day timeline's per-hour height (the scale-bar's zoom). Clamped + persisted.
    public func setWeekHourH(_ h: CGFloat) {
        wake()
        let clamped = clampHourH(h)
        guard clamped != weekHourH else { return }
        weekHourH = clamped
        UserDefaults.standard.set(Double(clamped), forKey: Self.weekHourHKey)
    }
    /// View ▸ Alternative Timezone — the second hour column on the timeline. "none" = off.
    nonisolated public static let altTzKey = "cc.view.altTz"
    /// The "View ▸ Show Hidden Imported Events" toggle (UserDefaults-backed so the menu's checkmark and
    /// the renderer share one source of truth). When on, user-hidden imported events draw with a dotted bar.
    public var showHiddenImported: Bool { UserDefaults.standard.bool(forKey: Self.showHiddenImportedKey) }
    /// A View-menu preference changed (posted via `.calendarViewPrefsChanged`) → invalidate the display
    /// cache and repaint. The pref value itself lives in UserDefaults; this just re-derives the scene.
    public func viewPrefsChanged() {
        mainTz = UserDefaults.standard.string(forKey: Self.mainTzKey) ?? "auto"   // View ▸ Current Timezone
        altTz = UserDefaults.standard.string(forKey: Self.altTzKey) ?? "none"     // View ▸ Alternative Timezone
        caches.editGen &+= 1; caches.deadlineGen &+= 1; wake()
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

    // ── Keyboard navigation cursor: input mode, movement, geometry, zoom ───────────
    /// True while any view anim.tween/flip is in flight — the cursor ring should follow the geometry each
    /// frame WITHOUT its own spring (avoids lag during zoom/scroll); it springs only for discrete moves.
    public var isAnimating: Bool {
        anim.tween != nil || anim.scrollTween != nil || anim.tlScrollTween != nil || anim.weekTween != nil || anim.dayTween != nil ||
        anim.flipAnim != nil || anim.monthAnim != nil || anim.weekFlip != nil || anim.dayFlip != nil
    }

    /// A mouse move/click hides the keyboard cursor visual (state persists).
    public func enterMouseMode() { if cursor.keyboardActive { cursor.keyboardActive = false; wake() } }
    /// A dispatched nav/action key shows the keyboard cursor.
    public func enterKeyboardMode() { if !cursor.keyboardActive { cursor.keyboardActive = true; wake() } }

    /// Move the block cursor by an arrow. `dy`: up = -1, down = +1; `dx`: left = -1, right = +1.
    /// (Year view only for now — up/down step a month, left/right are no-ops.)
    public func blockArrow(dx: Int, dy: Int) {
        enterKeyboardMode()
        switch level(z) {
        case 0:   // year: up/down = month
            let m = max(0, min(11, cursor.blockMonth + dy))
            if m != cursor.blockMonth { cursor.blockMonth = m; ensureMonthVisible(m, animated: true) }
        case 1:   // month: left/right = day (wraps across weeks); up/down = no-op
            let d = max(1, min(daysInMonth(year, focus), cursor.blockDay + dx))
            if d != cursor.blockDay { cursor.blockDay = d }
        case 2:   // week: up/down = hour; left/right = day (+ glide the focus window to follow)
            if dy != 0 { stepHour(dy) }
            if dx != 0 {
                let d = max(1, min(daysInMonth(year, focus), cursor.blockDay + dx))
                if d != cursor.blockDay { cursor.blockDay = d; ensureDayVisibleWeek(d) }
            }
        case 3:   // day: up/down = hour; left/right = swipe to the prev/next day
            if dy != 0 { stepHour(dy) }
            if dx != 0 { swipeDay(dx) }
        default:
            break
        }
    }

    /// ⌘N — create a new event at the block cursor. Week/day (an hour cell) → a 1-hour timed event on
    /// that day/hour, selected + its inline title editor opened for immediate naming. Month/year → no-op.
    public func createEventAtBlock() {
        enterKeyboardMode()
        guard selectedId == nil, !drawerOpen else { return }
        guard level(z) >= 2 else { return }   // month/year → no-op
        let d = level(z) == 2 ? cursor.blockDay : daily.dom
        let h = cursor.blockHour
        beginTxn()
        let id = "new-\(UUID().uuidString)"
        items.events.append(TimedEvent(id: id, year: year, month: focus, day: d,
                                     startHour: h, endHour: min(24, h + 1), title: "New event", color: "blue",
                                     anchorTz: anchorNow))
        selectedId = id
        commitTxn()
        editTimed(id)   // open the inline title editor so the name is focused right away
    }

    // ── Band cursor (block cursor + a lane) ────────────────────────────────────────
    /// Move the band cursor. ↑/↓ walk the 4 lanes (in year view, across month/quarter boundaries);
    /// ←/→ walk days (week/month/year may shift the focus window; day view swipes).
    public func bandArrow(dx: Int, dy: Int) {
        enterKeyboardMode()
        if dy != 0 {
            if level(z) == 0 {   // year: lanes stack across all 12 months (0…47), crossing quarters
                let flat = max(0, min(11 * 4 + 3, cursor.blockMonth * 4 + cursor.bandCurTrack + dy))
                cursor.blockMonth = flat / 4; cursor.bandCurTrack = flat % 4
                cursor.blockDay = min(daysInMonth(year, cursor.blockMonth), max(1, cursor.blockDay))
                ensureMonthVisible(cursor.blockMonth, animated: true)
            } else {
                cursor.bandCurTrack = max(0, min(3, cursor.bandCurTrack + dy))
            }
        }
        if dx != 0 {
            let m = level(z) == 0 ? cursor.blockMonth : focus
            switch level(z) {
            case 0, 1: cursor.blockDay = max(1, min(daysInMonth(year, m), cursor.blockDay + dx))
            case 2:    let d = max(1, min(daysInMonth(year, focus), cursor.blockDay + dx)); if d != cursor.blockDay { cursor.blockDay = d; ensureDayVisibleWeek(d) }
            default:   swipeDay(dx)   // day view
            }
        }
    }

    /// The band cursor's cell rect (geometry space): one day column × one lane.
    public func bandCursorRect() -> CGRect? {
        guard cursor.keyboardActive, !Self.isDemoMode, cursor.bandCursorActive, selectedId == nil, !drawerOpen else { return nil }
        let g = snapshot()
        let m = level(z) == 0 ? cursor.blockMonth : focus
        let f = frameFor(m, g)
        let day = min(daysInMonth(year, m), max(1, cursor.blockDay))
        return CGRect(x: f.x0 + CGFloat(day - 1) * f.dayW, y: f.bandY + CGFloat(cursor.bandCurTrack) * f.trackH,
                      width: f.dayW, height: f.trackH)
    }

    /// ⌘N in band-cursor mode — create a 1-day band at the cursor cell, select it, open its title editor.
    public func createBandAtCursor() {
        enterKeyboardMode()
        guard cursor.bandCursorActive, selectedId == nil, !drawerOpen else { return }
        let m = level(z) == 0 ? cursor.blockMonth : focus
        let day = min(daysInMonth(year, m), max(1, cursor.blockDay))
        beginTxn()
        let id = "new-\(UUID().uuidString)"
        items.bands.append(BandEvent(id: id, year: year, month: m, track: cursor.bandCurTrack, startDay: day, endDay: day, title: "New event", color: "blue"))
        selectedId = id
        cursor.bandCursorActive = false
        commitTxn()
        editBand(id)
    }

    // ── Track-name cursor (month view's extra Tab stops) ───────────────────────────
    /// The focused track-name gutter cell (geometry space), or nil when not on a track name.
    public func trackNameCursorRect() -> CGRect? {
        guard cursor.keyboardActive, !Self.isDemoMode, let t = cursor.trackNameCursor, selectedId == nil, !drawerOpen, level(z) == 1 else { return nil }
        let g = snapshot()
        let f = frameFor(focus, g)
        let y = f.bandY + CGFloat(t) * f.trackH
        return CGRect(x: Layout.mnameW, y: y, width: Layout.labelW - Layout.mnameW - Layout.rightPad, height: f.trackH)
    }

    /// Enter on a focused track name → open its inline editor (Enter again commits — see TrackNameEditor).
    public func editFocusedTrackName() {
        guard let t = cursor.trackNameCursor, let rect = trackNameCursorRect() else { return }
        onEditTrackName?(focus, t, rect)
    }

    /// The selected event's anchor (month, day, hour) — nil if nothing selected. Bands anchor at their
    /// start day + noon; timed/deadlines at their day + start hour.
    private func selectedAnchor() -> (month: Int, day: Int, hour: CGFloat)? {
        guard let sel = selectedId else { return nil }
        if let b = displayBands(for: year).first(where: { $0.id == sel }) { return (b.month, b.startDay, 12) }
        if let e = displayEvents(for: year).first(where: { $0.id == sel }) { return (e.month, e.day, e.startHour) }
        if let d = displayDeadlines(for: year).first(where: { $0.id == sel }) { return (d.month, d.day, d.hour) }
        return nil
    }

    /// ⌘= — zoom IN one level, keeping the current focus. With an event selected, the view lands on that
    /// event's month/week/day (it stays selected). With a cursor, this is blockZoomIn's placement.
    public func cmdZoomIn() {
        enterKeyboardMode()
        guard let a = selectedAnchor() else { blockZoomIn(); return }
        cursor.trackNameCursor = nil
        switch level(z) {
        case 0: focus = a.month; cursor.blockMonth = a.month; cursor.blockDay = a.day; ensureMonthVisible(a.month, animated: false); tweenZ(to: 1)
        case 1: week = CGFloat(weekOfDate(year, focus, a.day)); daily.dom = a.day; cursor.blockDay = a.day; cursor.blockHour = a.hour; tweenZ(to: 2)
        case 2: daily.dom = a.day; cursor.blockHour = a.hour; tweenZ(to: 3)
        default: break   // day is the deepest
        }
    }

    /// ⌘− — zoom OUT one level, keeping the current focus. With an event selected, the higher-level view
    /// lands on the event so it stays visible; otherwise the block cursor carries over (syncBlockToView).
    public func cmdZoomOut() {
        enterKeyboardMode()
        cursor.trackNameCursor = nil
        clearDashStop()
        let dest = max(0, level(z) - 1)
        if let a = selectedAnchor() {
            focus = a.month
            week = CGFloat(weekOfDate(year, a.month, a.day)); daily.dom = a.day
            cursor.blockMonth = a.month; cursor.blockDay = a.day; cursor.blockHour = a.hour
        }
        tweenZ(to: CGFloat(dest))
        if selectedId == nil { syncBlockToView(dest) }
    }

    /// Space / ⌘= — zoom IN one level, carrying the block cursor with the placement rules.
    public func blockZoomIn() {
        enterKeyboardMode()
        cursor.trackNameCursor = nil   // track names are month-only; zooming leaves them → block cursor
        switch level(z) {
        case 0:   // year → month: focus the cursor's month; land the day on today (if that month) else the 1st.
            focus = cursor.blockMonth
            let t = Calendar.current.dateComponents([.year, .month, .day], from: now)
            let isCurMonth = (t.year == year) && ((t.month ?? 0) - 1 == cursor.blockMonth)
            cursor.blockDay = isCurMonth ? (t.day ?? 1) : 1
            ensureMonthVisible(cursor.blockMonth, animated: false)   // instant; the zoom repositions immediately after
            tweenZ(to: 1)
        case 1:   // month → week: focus the cursor's week; land the hour on now (if the week has today) else noon.
            week = CGFloat(weekOfDate(year, focus, cursor.blockDay))
            daily.dom = cursor.blockDay
            let t = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: now)
            let weekHasToday = (t.year == year) && ((t.month ?? 0) - 1 == focus)
                && weekOfDate(year, focus, t.day ?? 1) == weekOfDate(year, focus, cursor.blockDay)
            cursor.blockHour = weekHasToday ? CGFloat(t.hour ?? 12) : 12   // land on the hour cell containing now
            tweenZ(to: 2)
        case 2:   // week → day: same hour, on the cursor's day
            daily.dom = min(daysInMonth(year, focus), max(1, cursor.blockDay))
            tweenZ(to: 3)
        default:
            break   // day view is the deepest — Space is a no-op
        }
    }

    /// The block cursor's cell rect in geometry space (pre-padLeft), or nil when it shouldn't show
    /// (mouse mode, an event/drawer is active, or a view without a cursor yet).
    public func blockCursorRect() -> CGRect? {
        guard cursor.keyboardActive, !Self.isDemoMode, !cursor.bandCursorActive, cursor.trackNameCursor == nil, selectedId == nil, cursor.dashStop == nil, !drawerOpen else { return nil }
        let g = snapshot()
        switch level(z) {
        case 0:
            // Cover the ENTIRE month row — from the left edge (the month-name gutter) to the right.
            let f = yearFrame(cursor.blockMonth, g.vp, scrollY)
            return CGRect(x: 0, y: f.bandY, width: g.vp.w, height: 4 * f.trackH)
        case 1:
            // A day COLUMN: the band cell on top + the day's timeline below it.
            let f = frameFor(focus, g)
            let tl = timelineInfo(g)
            let d = max(1, min(daysInMonth(year, focus), cursor.blockDay))
            let x = f.x0 + CGFloat(d - 1) * f.dayW
            return CGRect(x: x, y: f.bandY, width: f.dayW, height: max(4 * f.trackH, tl.tlBottom - f.bandY))
        case 2, 3:
            // An HOUR cell: the day column × one hour row. (Day view: the shown day is daily.dom.)
            let tl = timelineInfo(g)
            guard tl.hourH > 0 else { return nil }
            let d = level(z) == 2 ? cursor.blockDay : daily.dom
            let x = tl.x0 + CGFloat(d - 1) * tl.colW
            let y = tl.tlTop + cursor.blockHour * tl.hourH - tl.scroll
            return CGRect(x: x, y: y, width: tl.colW, height: tl.hourH)
        default:
            return nil
        }
    }

    /// The dashed-ring rect for the SELECTED event box (geometry space, pre-padLeft) — the event-cursor
    /// visual, shown in keyboard mode. Looks up the exact box in the DISPLAY arrays (so a promoted band /
    /// occurrence ghost rings its own box, not the whole series).
    public func selectionRingRect() -> CGRect? {
        guard cursor.keyboardActive, let sel = selectedId, !drawerOpen else { return nil }
        let g = snapshot()
        if let b = displayBands(for: year).first(where: { $0.id == sel }), let r = bandEventRect(b, g, anim: g.monthAnim) {
            return CGRect(x: r.x, y: r.y, width: r.w, height: r.h)
        }
        if z >= 1.5, let e = displayEvents(for: year).first(where: { $0.id == sel }) {
            let tl = timelineInfo(g)
            let sameDay = eventsOn(year, e.month, e.day)
            if let r = eventRect(e, year, focus, tl, g.vp, layoutDay(sameDay)[e.id]) {
                return CGRect(x: r.minX, y: tl.tlTop - tl.scroll + r.minY, width: r.width, height: r.height)
            }
        }
        if z >= 1.5, let d = displayDeadlines(for: year).first(where: { $0.id == sel }), let pos = deadlinePos(d, g) {
            return CGRect(x: pos.x, y: pos.y - 9, width: pos.w, height: 18)   // the moment-line band
        }
        return nil
    }

    /// Scroll the year view (if needed) so month `m`'s band is fully on screen. `animated` glides the
    /// scroll (a `anim.scrollTween`, like jumpToDay) rather than snapping — used when the cursor walks off
    /// the visible region.
    func ensureMonthVisible(_ m: Int, animated: Bool) {
        let cTop = yearFrame(m, viewport, 0).bandY - Layout.yearTop   // scroll-independent content top
        let h = 4 * Layout.trackH
        let viewTop = Layout.yearTop, viewBottom = viewport.h - Layout.bottomPad
        // On-screen top = viewTop - scrollY + cTop. Keep [top, top+h] within [viewTop, viewBottom].
        let maxScrollForVisible = cTop                                   // any more → top clips above
        let minScrollForVisible = cTop + h - (viewBottom - viewTop)      // any less → bottom clips below
        // Base the clamp on where we're HEADED (an in-flight anim.tween's target) so rapid presses chain.
        var s = anim.scrollTween?.to ?? scrollY
        if s > maxScrollForVisible { s = maxScrollForVisible }
        if s < minScrollForVisible { s = minScrollForVisible }
        s = clamp(s, 0, yearMaxScroll(viewport))
        if abs(s - scrollY) < 0.5 { return }                            // already visible enough
        if animated {
            // Pace-locked like the day/week glides: duration scales with the scroll distance (~0.3s per
            // month band) so holding ↑/↓ scrolls at a CONSTANT speed instead of a fixed duration crawling
            // over a growing gap. ease OUT (not in-out) so each auto-repeat re-press kicks forward at full
            // speed rather than restarting in the slow ease-IN ramp. `scrollY` is already the live value.
            let dur = max(0.12, 0.3 * Double(abs(s - scrollY) / Layout.monthH))
            anim.scrollTween = Tween(from: scrollY, to: s, start: Date(), duration: dur, ease: easeOut)
        } else {
            anim.scrollTween = nil; scrollY = s; onSetYearScroll?(scrollY)
        }
    }

    public func onHover(at p: CGPoint) {
        if drawerOpen { onHoverExit(); return }   // drawer open → no calendar hover highlights
        pointerPos = p                            // for the deadline "+" hover glow (pixel-precise)
        // Timeline scale-bar proximity reveal: the bar fades in only when the cursor approaches
        // the timeline's left border (week/day views). Observable + wake, so the overlay reacts
        // even when the render loop is idle.
        let near = level(z) >= 2 && abs(p.x - Layout.labelW) < Self.tlEdgeRevealDist
        if near != nearTlEdge { nearTlEdge = near; wake() }
        let g = snapshot()
        let prevHover = hover, prevHovered = hoveredEventId   // wake the render only if the visual actually changes
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
        // Wake on any change, plus every move while near a day's left edge so the deadline "+" glow
        // tracks the cursor pixel-precisely (the cell-based `hv` alone wouldn't change within a cell).
        if hv != prevHover || hoveredEventId != prevHovered || hv.nearLeft == true { wake() }
    }

    private func bandContains(_ id: String, _ p: CGPoint, _ g: SceneInput) -> Bool {
        guard let b = items.bands.first(where: { $0.id == id }), let r = bandEventRect(b, g, anim: g.monthAnim) else { return false }
        return CGRect(x: r.x, y: r.y, width: r.w, height: r.h).contains(p)
    }
    private func timedContains(_ id: String, _ p: CGPoint, _ g: SceneInput) -> Bool {
        guard z >= 1.5, let e = items.events.first(where: { $0.id == id }) else { return false }
        let tl = timelineInfo(g)
        guard tl.reveal > 0.05, tl.hourH > 0 else { return false }
        guard p.y >= tl.tlTop, p.y <= tl.tlBottom else { return false }   // clip to the timeline (see eventAt)
        let sameDay = eventsOn(year, e.month, e.day)
        guard let r = eventRect(e, year, focus, tl, g.vp, layoutDay(sameDay)[e.id]) else { return false }
        return CGRect(x: r.minX, y: tl.tlTop - tl.scroll + r.minY, width: r.width, height: r.height).contains(p)
    }

    public func onHoverExit() {
        if hover != .none || hoveredEventId != nil { wake() }
        hover = .none; hoveredEventId = nil; pointerPos = nil
        if nearTlEdge { nearTlEdge = false; wake() }
    }

    /// Clear the hover HIGHLIGHT only — used when scrolling starts (the content moves under a
    /// stationary cursor, so the highlight is stale) — but keep the pointer position and the
    /// scale-bar proximity (`nearTlEdge`): the mouse hasn't gone anywhere.
    public func clearHoverHighlight() {
        if hover != .none || hoveredEventId != nil { wake() }
        hover = .none; hoveredEventId = nil
    }

    /// Clear the current event selection — the same effect as a plain click on empty calendar space.
    /// Used by the daily-dashboard WebView so clicking its empty content deselects too.
    public func deselect() { selectedId = nil; cursor.bandCursorActive = false }   // Esc from an event → block cursor (home)

    public func cursorHint(at p: CGPoint) -> CursorHint {
        if trackNameHit(at: p) != nil { return .text }   // editable lane label
        let g = snapshot()
        if let hit = bandAt(p, g) {
            if hit.zone == .bandResizeL || hit.zone == .bandResizeR { return .resizeLR }
            return hit.id == selectedId ? .text : .grab   // a selected band edits its title on click
        }
        // Timed event: the top/bottom edges resize (↕); the title of a SELECTED event is an I-beam (a second
        // click inline-edits it); the accent bar, the time text, and the empty body are a grab hand.
        if z >= 1.5, let hit = eventAt(p, g) {
            switch hit.zone {
            case .resizeTop, .resizeBottom: return .resizeV
            default: return (hit.id == selectedId && hit.overTitle) ? .text : .grab
            }
        }
        if z >= DETAIL_Z, deadlineAt(p, g) != nil { return .grab }
        return .normal   // empty calendar → plain arrow (no create "+" cursor)
    }


}
