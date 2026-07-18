// The mutable view-state + tween clock. Geometry is stateless; this is where z,
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
// TimelineView(.animation), which reads a fresh SceneInput and advances the tween
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
        isAnimating || shiftTween != nil || monthFlip != nil || drag != nil || daily.anim != nil
        || liveScrolling || liveMonthScrolling || liveWeekScrolling || liveDayScrolling
        || yearPull != nil || monthPull != nil || weekPull != nil || dayPull != nil
    }

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
    public private(set) var pointerPos: CGPoint?   // last hover point (calendar space) → is the cursor on the deadline "+"?
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
    public var weekHourH: CGFloat = 60
    public private(set) var viewport: Viewport = Viewport(w: 1, h: 1)
    public private(set) var seedEvents: [TimedEvent] = []
    public private(set) var seedBands: [BandEvent] = []
    public private(set) var seedDeadlines: [Deadline] = []
    // Read-only events imported from Apple Calendar (EventKit). Kept SEPARATE from the seed arrays so
    // they never persist to disk / push to iCloud (they're re-fetched) and can't be edited — every edit
    // path targets the seed arrays. They're merged into the display caches (see ensureEventCache /
    // ensureBandCache). User overlays (tags/notes/promote) attach via `richById` by the stable id.
    public private(set) var importedEvents: [TimedEvent] = []
    public private(set) var importedBands: [BandEvent] = []
    // Imported id → EKEvent.eventIdentifier, rebuilt each merge. Transient (not persisted): only used to
    // build the `ical://ekevent/…` deep-link for "Edit original", which is only offered on a live import.
    private var appleEventIds: [String: String] = [:]
    public private(set) var trackNames = Array(repeating: TRACKS.map { $0.name }, count: 12)  // per month
    public var trackEditing = false        // an inline track-name field is open (freezes scroll)
    public let chrome = CalendarChrome()   // breadcrumb state for the toolbar

    public private(set) var selectedId: String?
    public private(set) var hoveredEventId: String?   // band/timed/deadline under the cursor

    // ── Keyboard navigation cursor ────────────────────────────────────────────────
    // `keyboardActive` gates only the CURSOR VISUAL (last-input-wins): a mouse move/click flips it off,
    // a dispatched nav key flips it on. The position below always persists. Block-cursor position is
    // interpreted per view (year → month; month → day; week/day → day + hour); grown one view at a time.
    public private(set) var keyboardActive = false
    public private(set) var blockMonth = 0
    public private(set) var blockDay = 1
    public private(set) var blockHour: CGFloat = 12
    // Band cursor = the block cursor's time position (blockMonth/blockDay) PLUS a lane. Only these two
    // extra bits of state: whether we're in band-cursor mode, and which of the 4 lanes.
    public private(set) var bandCursorActive = false
    public private(set) var bandCurTrack = 0
    // Month view's extra Tab stops: which of the 4 track NAMES is focused (nil = not on a track name).
    public private(set) var trackNameCursor: Int?
    public var onEditTrackName: ((_ month: Int, _ track: Int, _ rect: CGRect) -> Void)?

    // Day view's extra Tab stops: the dashboard TODO list and the daily NOTE become 2 keyboard focus
    // targets after the event cursor (see tabCursor). `dashStop` is the focused one (nil = not on the
    // dashboard); `dashNoteEditing` flips true once Enter focuses the note editor (the WebView owns keys
    // then). The focus ring itself is drawn INSIDE the WebView, driven via `onDashCommand`.
    public enum DashStop: Equatable { case todo, note }
    public private(set) var dashStop: DashStop?
    public private(set) var dashNoteEditing = false
    private var dashReturnEvent: String?   // the event to re-select when ⇧Tab leaves the TODO stop
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

    private var tween: Tween?
    private var scrollTween: Tween?            // year-view vertical scroll glide (before a zoom-in)
    private var scrollTweenDone: (() -> Void)?
    private var tlScrollTween: Tween?          // timeline (hour) scroll glide — keyboard hour-cursor follow
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
    private var bandCache: (year: Int, gen: Int, bands: [BandEvent], badges: [String: EventBadges], byMonth: [Int: [BandEvent]])?
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
    /// Observable "last synced" state for the Connectivity menu. Always present (shows "local only" in
    /// the unentitled dev build); CloudSync writes `markSynced()` on each successful round-trip.
    public let syncMonitor = SyncMonitor(cloudEnabled: CloudSync.isEntitled)
    /// Start CloudKit sync when this build carries the iCloud entitlement (the signed
    /// CalendarApp). The unsigned CalendarMac dev binary isn't entitled → no-op, local-only.
    private func enableCloudSyncIfEntitled() {
        guard CloudSync.isEntitled else { return }
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
        seedEvents = []; seedBands = []; seedDeadlines = []; richById = [:]
        selectedId = nil; editGen &+= 1; deadlineGen &+= 1; wake()
    }
    /// Insert one ambient timed event (recording scenes; not on the undo stack, not selected).
    @discardableResult
    public func demoAddTimed(month: Int, day: Int, startHour: CGFloat, endHour: CGFloat, title: String, color: String) -> String {
        let id = "demo-\(seedEvents.count)"
        seedEvents.append(TimedEvent(id: id, year: year, month: month, day: day, startHour: startHour, endHour: endHour, title: title, color: color))
        editGen &+= 1; deadlineGen &+= 1; wake()
        return id
    }
    /// Insert one ambient all-day band (recording scenes; not selected).
    @discardableResult
    public func demoAddBand(month: Int, track: Int, startDay: Int, endDay: Int, title: String, color: String) -> String {
        let id = "demob-\(seedBands.count)"
        seedBands.append(BandEvent(id: id, year: year, month: month, track: track, startDay: startDay, endDay: endDay, title: title, color: color))
        editGen &+= 1; deadlineGen &+= 1; wake()
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
        guard let id = selectedId, let i = seedEvents.firstIndex(where: { $0.id == id }) else { return }
        seedEvents[i].title = title; editGen &+= 1; wake()
    }
    /// Rename the currently-selected BAND (band scenes name their freshly drag-created band).
    public func demoRenameSelectedBand(_ title: String) {
        guard let id = selectedId, let i = seedBands.firstIndex(where: { $0.id == id }) else { return }
        seedBands[i].title = title; editGen &+= 1; wake()
    }
    /// Snap the view to year level, scrolled so `centerMonth` is visible (deterministic scene setup).
    public func demoGoToYear(centerMonth: Int) {
        cancelTween()
        z = 0; focus = centerMonth
        ensureMonthVisible(centerMonth, animated: false)
        editGen &+= 1; deadlineGen &+= 1; wake()
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
        editGen &+= 1; wake()
        return id
    }
    /// Select an item by id (highlight it), e.g. a just-created event in the AI scene.
    public func demoSelect(_ id: String?) { selectedId = id; editGen &+= 1; wake() }

    // ── Apple Calendar import (EventKit) ──────────────────────────────────────────────
    // Enabled-state + selected calendars live in UserDefaults so the (separate) Settings window and the
    // running engine share them without a direct reference; Settings posts `.appleCalendarSettingsChanged`
    // to nudge an immediate re-import. Imported events are read-only + kept out of persistence/iCloud.
    public static let appleEnabledKey = "cc.appleCal.enabled"
    public static let appleCalendarsKey = "cc.appleCal.ids"
    private let appleImporter = AppleCalendarImporter()

    public var appleSyncEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.appleEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.appleEnabledKey) }
    }
    public var appleCalendarIds: [String] {
        get { (UserDefaults.standard.array(forKey: Self.appleCalendarsKey) as? [String]) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.appleCalendarsKey) }
    }
    /// Access probe + the calendar list + the TCC prompt — for the Settings picker. Access status is
    /// static so the isolated Settings window can read it without the engine.
    public static var appleAccess: AppleCalendarImporter.Access { AppleCalendarImporter.access }
    public func appleCalendars() -> [AppleCalendarInfo] { appleImporter.calendars() }
    public func requestAppleAccess() async -> Bool { await appleImporter.requestAccess() }

    /// Re-fetch the enabled Apple calendars for the visible year ±1 and merge them in as read-only
    /// events (full-window re-fetch; Apple has no incremental cursor). Disabled/unauthorized → clears
    /// any previously-imported set. Cheap to call on launch, foreground, and settings change.
    public func importAppleCalendar() {
        if Self.isDemoMode { return }   // recording session → never touch the user's Apple Calendar
        // Proceed unless disabled or access is explicitly DENIED. We don't require `.authorized` here:
        // the status lags for a beat after a fresh grant, but `fetch()` asks the store directly and
        // returns real events during that window (empty if truly no access), so the first import right
        // after connecting isn't lost.
        guard appleSyncEnabled, AppleCalendarImporter.access != .denied else {
            if !importedEvents.isEmpty || !importedBands.isEmpty {
                importedEvents = []; importedBands = []; editGen &+= 1; deadlineGen &+= 1; wake()
            }
            return
        }
        let cal = Calendar.current
        let from = cal.date(from: DateComponents(year: year - 1, month: 1, day: 1)) ?? Date()
        let to   = cal.date(from: DateComponents(year: year + 3, month: 1, day: 1)) ?? Date()
        mergeAppleEvents(appleImporter.fetch(from: from, to: to, calendarIds: appleCalendarIds))
    }

    /// Case/punctuation/whitespace-insensitive title key (ported from the web's `normTitle`).
    static func normTitle(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
    /// Exact dedup key for a timed event: normalized title + calendar day + exact start minute.
    private func timedKey(_ title: String, _ y: Int, _ m: Int, _ d: Int, _ startHour: CGFloat) -> String {
        "\(Self.normTitle(title))|\(y)-\(m)-\(d)@\(Int((startHour * 60).rounded()))"
    }
    /// Store an imported event's `hidden` flag (a deduped shadow of the user's own event). Returns
    /// whether it changed, so the caller can persist. Only mints a rich-fields entry when actually hiding.
    private func setImportedHidden(_ id: String, _ hidden: Bool) -> Bool {
        if hidden {
            var rf = richById[id] ?? RichFields()
            if rf.hidden { return false }
            rf.hidden = true; richById[id] = rf; return true
        } else if var rf = richById[id], rf.hidden {
            rf.hidden = false; richById[id] = rf; return true
        }
        return false
    }
    /// Set an imported event's note to `fresh` managed block composed with any existing user postfix
    /// (a blank `fresh` drops the managed block, keeping the user's text). Returns whether it changed.
    private func setImportedNote(_ id: String, _ fresh: String) -> Bool {
        let composed = ManagedNote.replaceManaged(richById[id]?.notes, fresh)
        let newVal: String? = composed.isEmpty ? nil : composed
        if (richById[id]?.notes ?? "") == (newVal ?? "") { return false }
        var rf = richById[id] ?? RichFields()
        rf.notes = newVal
        richById[id] = rf
        return true
    }

    private func mergeAppleEvents(_ fetched: [FetchedAppleEvent]) {
        let cal = Calendar.current
        // Dedup: the user's OWN timed events (exact key), so an imported event that shadows one can be
        // hidden. displayEvents includes recurrence occurrences; exclude imported ids so we compare only
        // against the user's real calendar, not a prior Apple import.
        var ownTimed = Set<String>()
        for y in (year - 1)...(year + 2) {
            for e in displayEvents(for: y) where !isImported(e.id) { ownTimed.insert(timedKey(e.title, e.year, e.month, e.day, e.startHour)) }
        }
        var events: [TimedEvent] = []
        var seen = Set<String>()       // self-dedup: a copied event can share a UID → collides on our id
        var richChanged = false
        var seriesNote: [String: String] = [:]   // series key → freshly-rendered managed block (computed once)
        var seriesVisible = Set<String>()         // series keys with ≥1 non-hidden occurrence this import
        appleEventIds.removeAll(keepingCapacity: true)
        for e in fetched.sorted(by: { $0.start < $1.start }) {
            if e.allDay { continue }   // never import all-day events (product decision)
            let sc = cal.dateComponents([.year, .month, .day, .hour, .minute], from: e.start)
            guard let y = sc.year, let mo1 = sc.month, let d = sc.day else { continue }
            let m = mo1 - 1
            let sh = CGFloat(sc.hour ?? 0) + CGFloat(sc.minute ?? 0) / 60
            let ec = cal.dateComponents([.year, .month, .day, .hour, .minute], from: e.end)
            var eh = CGFloat(ec.hour ?? 0) + CGFloat(ec.minute ?? 0) / 60
            if ec.year != y || ec.month != mo1 || ec.day != d || eh <= sh { eh = 24 }   // multi-day / past midnight → clamp to day end
            let id = "apple-\(e.uid)-\(String(format: "%04d%02d%02d-%02d%02d", y, mo1, d, sc.hour ?? 0, sc.minute ?? 0))"
            guard seen.insert(id).inserted else { continue }
            if let eid = e.eventId { appleEventIds[id] = eid }
            // Exact-match dedup: an imported event that shadows one of the user's OWN events (same title +
            // same day + same start) is still imported, but flagged HIDDEN on its entry — we prefer the
            // editable event and don't draw the shadow. The flag is stored/persisted, so re-imports keep it.
            let hidden = ownTimed.contains(timedKey(e.title, y, m, d, sh))
            if setImportedHidden(id, hidden) { richChanged = true }   // per-occurrence flag (local-only)
            // Vendor "managed note" is SERIES-level (provenance, meeting link, location, organizer,
            // attendees, description don't vary per occurrence). Compute it once per series and remember
            // whether any occurrence is visible; a fully-shadowed series drops its managed block below.
            let sk = Self.appleSeriesKey(id)
            if !hidden { seriesVisible.insert(sk) }
            if seriesNote[sk] == nil, ManagedNote.hasDetail(url: e.url, location: e.location, organizer: e.organizer, attendees: e.attendees.count, description: e.notes) {
                seriesNote[sk] = ManagedNote.render(provenance: "Apple · \(e.sourceTitle) · \(e.calendarTitle)", meetingUrl: e.url,
                                                    location: e.location, organizer: e.organizer,
                                                    attendees: e.attendees.map { ($0.name, $0.status) }, description: e.notes)
            }
            events.append(TimedEvent(id: id, year: y, month: m, day: d, startHour: sh, endHour: max(sh + 0.25, eh), title: e.title, color: Self.nearestEventColor(e.colorHex), anchorTz: DeadlineTZ.concrete("auto")))
        }
        // Refresh each series' managed note at its series key, preserving the user's postfix; a series with
        // no visible occurrence drops the managed block (keeps any user text). Only series that already have
        // an overlay entry, or that carry detail this import, are touched.
        for sk in Set(seriesNote.keys).union(richById.keys.filter { Self.isAppleSeriesKey($0) }) {
            let block = seriesVisible.contains(sk) ? (seriesNote[sk] ?? "") : ""
            if setImportedNote(sk, block) { richChanged = true }
        }
        // Prune imported overlays no longer backed upstream: per-occurrence `hidden` flags whose occurrence
        // is gone; series overlays only when NO live occurrence remains AND they carry no user-authored data.
        let live = Set(events.map(\.id))
        let liveSeries = Set(events.map { Self.appleSeriesKey($0.id) })
        for id in richById.keys where id.hasPrefix("apple-") {
            if Self.isAppleSeriesKey(id) {
                if !liveSeries.contains(id), let rf = richById[id], !hasUserOverlay(rf) { richById[id] = nil; richChanged = true }
            } else if !live.contains(id) {
                richById[id] = nil; richChanged = true
            }
        }
        importedEvents = events
        importedBands = []
        if richChanged { schedulePersist() }   // the hidden flags are stored state (see setImportedHidden)
        editGen &+= 1; deadlineGen &+= 1
        if let s = selectedId, !itemExists(sourceId(of: s)) { selectedId = nil }   // selection's event gone
        onExternalDataChange?()   // an open drawer on a now-removed imported event should close
        wake()
    }

    /// Deep-link that reveals an imported event back in Calendar.app ("Edit original"). The `ical://ekevent/`
    /// scheme opens Calendar.app and selects the event by its EKEvent identifier. Nil if we don't hold the
    /// identifier (older import) — the UI hides the button then. The UI layer opens it (this module has no AppKit).
    public func appleOriginalURL(_ id: String) -> URL? {
        guard let eid = appleEventIds[sourceId(of: id)] else { return nil }
        return URL(string: "ical://ekevent/\(eid)?method=show&options=more")
    }

    /// "Make local copy": clone an imported (read-only) event into our own editable calendar, carrying its
    /// title / time / color / notes / tags, and hide the imported original so the two don't both show. The
    /// dedup pass on the next import would hide it anyway (same title+day+start now lives in our own set) — we
    /// just do it immediately. Returns the new editable event's id so the drawer can re-point at it.
    @discardableResult
    public func makeLocalCopy(_ id: String) -> String? {
        guard isImported(id), let e = importedEvents.first(where: { $0.id == id }) else { return nil }
        beginTxn()
        let newId = "new-\(UUID().uuidString)"
        seedEvents.append(TimedEvent(id: newId, year: e.year, month: e.month, day: e.day,
                                     startHour: e.startHour, endHour: e.endHour, title: e.title, color: importedDisplayColor(e),
                                     anchorTz: DeadlineTZ.concrete("auto")))   // imported events are device-local wall-clock
        // Carry the user overlays — notes (managed block + any typed text), tags, promote lane — into a
        // fresh, manual rich-fields entry. They live at the imported SERIES key; the copy is a normal local
        // event from here on (source defaults to "manual"; the vendor color is baked into the event above).
        if let src = richById[overlayKey(id)] {
            richById[newId] = RichFields(notes: src.notes, tags: src.tags, promoteTrack: src.promoteTrack)
        }
        _ = setImportedHidden(id, true)   // remove the read-only original from view (dedup keeps it hidden after)
        selectedId = newId
        commitTxn()
        return newId
    }

    /// Nearest named palette color to a `#RRGGBB` hex — imported events adopt their calendar's color.
    static func nearestEventColor(_ hex: String) -> String {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = Int(s, radix: 16) else { return "blue" }
        let r = (v >> 16) & 0xFF, g = (v >> 8) & 0xFF, b = v & 0xFF
        let palette: [(String, Int, Int, Int)] = [
            ("blue", 74, 142, 232), ("indigo", 92, 92, 214), ("cyan", 80, 200, 220),
            ("green", 76, 200, 120), ("darkgreen", 40, 120, 70), ("yellow", 230, 200, 70),
            ("orange", 240, 150, 70), ("red", 240, 96, 96), ("purple", 170, 100, 220),
        ]
        var best = "blue"; var bestD = Int.max
        for (name, pr, pg, pb) in palette {
            let dist = (r - pr) * (r - pr) + (g - pg) * (g - pg) + (b - pb) * (b - pb)
            if dist < bestD { bestD = dist; best = name }
        }
        return best
    }

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
        blockMonth = focus; blockDay = c.day ?? 1
        daily = DailyState(dom: c.day ?? 1, frac: 0.45)
        // No placeholder seed events (regular OR recording mode) — a fresh install starts with an empty
        // calendar; the recording scenes seed their own ambient data. Existing users load from the store below.
        seedEvents = []; seedBands = []; seedDeadlines = []
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
        mainTz = UserDefaults.standard.string(forKey: Self.mainTzKey) ?? "auto"   // View ▸ Current Timezone
        altTz = UserDefaults.standard.string(forKey: Self.altTzKey) ?? "none"     // View ▸ Alternative Timezone
        migrateAnchors()   // stamp anchorTz on legacy items (needs mainTz resolved above)
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
            Task { @MainActor in self?.now = Date(); self?.wake() }   // refresh the now-line (a render must run)
        }
        pushChrome()
        enableCloudSyncIfEntitled()
        armSleep()   // an untouched app settles to a paused (idle) render after the initial frame
    }

    /// A fixed anchor for a freshly created item: the current view (main) zone, resolved to a concrete
    /// id so it never drifts with the device (a stored anchor must not be "auto").
    private var anchorNow: String { DeadlineTZ.concrete(mainTz) }

    /// One-time backfill so every timed event and deadline carries an explicit `anchorTz` — the display
    /// pipeline needs it to convert into the current view zone. Legacy items stored their wall-clock in
    /// the main tz, so the anchor IS the (resolved) main tz and the stored hours stay valid untouched.
    /// A deadline that carried a legacy `originTz` is RE-ANCHORED to that origin (its `hour` was the
    /// main-tz equivalent, so we re-express it as the origin wall-clock), preserving both the instant and
    /// the "(AOE 23:59)" label. Idempotent — items that already have an anchor are skipped.
    private func migrateAnchors() {
        let main = DeadlineTZ.concrete(mainTz)
        var changed = false
        for i in seedEvents.indices where seedEvents[i].anchorTz == nil {
            seedEvents[i].anchorTz = main; changed = true
        }
        for i in seedDeadlines.indices where seedDeadlines[i].anchorTz == nil {
            let d = seedDeadlines[i]
            if let origin = d.originTz,
               !DeadlineTZ.sameOffset(origin, mainTz, at: DeadlineTZ.instant(d.year, d.month, d.day, d.hour)) {
                let w = DeadlineTZ.convertWall(d.year, d.month, d.day, d.hour, from: mainTz, to: origin)
                seedDeadlines[i].year = w.year; seedDeadlines[i].month = w.month
                seedDeadlines[i].day = w.day; seedDeadlines[i].hour = w.hour
                seedDeadlines[i].anchorTz = DeadlineTZ.concrete(origin)
            } else {
                seedDeadlines[i].anchorTz = main
            }
            seedDeadlines[i].originTz = nil   // folded into anchorTz; the legacy field is retired
            changed = true
        }
        if changed { persistNow() }
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
        PersistedState(events: seedEvents, bands: seedBands, deadlines: seedDeadlines, monthTrackNames: trackNames, rich: richById, dailyNotes: dailyNotes)
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
        seedEvents.append(contentsOf: events)
        seedBands.append(contentsOf: bands)
        seedDeadlines.append(contentsOf: deadlines)
        for (k, v) in rich { richById[k] = v }
        commitTxn()
    }

    /// Replace the ENTIRE local dataset (restoring a .mdc backup) — ONE undoable step, so an accidental
    /// import can be undone. Bumps the caches + persists, exactly like `restore`.
    public func replaceAll(_ s: PersistedState) {
        commitTxn()
        undoStack.append(editState); if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        wake(); editGen &+= 1; deadlineGen &+= 1
        seedEvents = s.events; seedBands = s.bands; seedDeadlines = s.deadlines
        richById = s.rich ?? [:]
        if let tn = s.monthTrackNames { trackNames = tn }
        dailyNotes = s.dailyNotes ?? [:]
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
        if !deletedIDs.isEmpty { onExternalDataChange?() }   // a remote delete may have removed an open item
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
        guard keyboardActive, selectedId == nil, !drawerOpen else { return nil }
        if let t = trackNameCursor { return Hover(track: t) }   // track-name cursor: highlight its lane
        if bandCursorActive {   // band cursor: the month/week crosshair (lane + day)
            switch level(z) {
            case 0:  return Hover(month: blockMonth, dom: blockDay, track: bandCurTrack)
            case 1, 2: return Hover(dom: blockDay, track: bandCurTrack)
            default: return nil   // day view: ring only
            }
        }
        switch level(z) {
        case 0:  return Hover(month: blockMonth)
        case 1:  return Hover(dom: blockDay)
        case 2, 3:  // day column (soft) + hour cell (strong), matching a mouse hover
            return Hover(dom: level(z) == 2 ? blockDay : daily.dom, hour: Int(blockHour.rounded()))
        default: return nil
        }
    }

    // ── Frame snapshot ──────────────────────────────────────────────────────────
    private func snapshot() -> SceneInput {
        SceneInput(z: z, focus: focus, week: week, vp: viewport, scrollY: scrollY, tlScroll: tlScroll,
                   now: now, year: year, hover: blockHoverOverride() ?? hover, weekHourH: weekHourH, daily: daily,
                   monthAnim: monthAnim, altDeltaHours: altDeltaHours, altLabel: altColumnLabel,
                   yearPull: yearPull, flipFade: flipFade,
                   animating: tween != nil || scrollTween != nil || tlScrollTween != nil || weekTween != nil || dayTween != nil || flipAnim != nil || monthAnim != nil || weekFlip != nil || dayFlip != nil,
                   monthPull: monthPull, monthFlipShift: monthFlipShift, weekPull: weekPull,
                   weekFlipDir: weekFlip?.dir ?? 0, weekFlipFade: weekFlipFade, dayPull: dayPull, mainTz: mainTz)
    }

    /// Read-only current scene input (does NOT advance tweens). For a second view that must render the
    /// same frame the main TimelineView already computed — e.g. the lifted-event copy above the scrim.
    public func snapshotInput() -> SceneInput { snapshot() }

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
        if let tt = tlScrollTween {
            tlScroll = tt.value(at: date); onSetTlScroll?(tlScroll)
            if tt.isComplete(at: date) { tlScroll = tt.to; tlScrollTween = nil; onSetTlScroll?(tlScroll) }
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
        let vp = Viewport(w: size.width - Layout.padLeft - Layout.padRight, h: size.height)
        // No-op guard: AppKit calls CatcherView.layout() (→ setViewport) on EVERY display cycle while the
        // calendar renders, and `sceneInput` already keeps `viewport` current each frame. Waking on a
        // same-size call created a layout→wake→render→layout feedback loop that pinned the CPU and
        // defeated the idle pause. Only act on a real resize (or the first layout).
        if didInitialScroll, vp.w == viewport.w, vp.h == viewport.h { return }
        wake()   // genuine resize / initial layout → re-render the scene
        viewport = vp
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
        wake()
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
        // Breadcrumb "most visible" month/day: once a month page (or day page) is more than halfway in,
        // the crumb shows the incoming one — so it updates mid-animation, not on landing. (A year-edge
        // flip swaps `focus`/`daily.dom` at its own midpoint, so this tracks those too.)
        let df = monthAnim.map { $0.p >= 0.5 ? min(11, max(0, focus + $0.dir)) : focus } ?? focus
        if chrome.displayFocus != df { chrome.displayFocus = df }
        let dd = daily.anim.map { $0.p >= 0.5 ? min(daysInMonth(year, focus), max(1, daily.dom + $0.dir)) : daily.dom } ?? daily.dom
        if chrome.displayDom != dd { chrome.displayDom = dd }
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
        wake()
        if zoomAnchorHour == nil { captureZoomAnchor() }   // fresh for a button/click zoom; kept for a pinch settle
        tween = Tween(from: z, to: clamp(target, 0, 3), start: Date(), duration: dur ?? ZOOM_DUR, ease: easeInOut)
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
    public func setTlScroll(_ y: CGFloat) { wake(); tlScroll = y }

    // ── Year-view scroll: mirror of the native NSScrollView driver ───────────────────
    public var isYearLevel: Bool { level(z) == 0 }

    /// Fingers-down phase begins. Record whether we were already resting at an edge —
    /// a flip is only allowed for a pull that STARTS from the edge (not a fast scroll
    /// from the middle that happens to overshoot into it).
    public func beginYearScrollGesture() {
        wake()
        liveScrolling = true
        let maxY = yearMaxScroll(viewport)
        startedAtTop = scrollY <= 2
        startedAtBottom = scrollY >= maxY - 2
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
    public func beginMonthGesture() { wake(); cancelTween(); liveMonthScrolling = true }

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
    public var weekFlipArmed: Bool { isWeekLevel && (weekPull?.armed ?? false) }
    public var monthFlipArmed: Bool { isMonthLevel && (monthPull?.armed ?? false) }

    /// The pager offset that shows the current `week` (fractional weeks × the 7-day grid width).
    public func weekPagerOffset(dayW: CGFloat) -> CGFloat { week * 7 * dayW }

    public func beginWeekGesture() { wake(); cancelTween(); weekTween = nil; liveWeekScrolling = true }

    public func beginDayGesture() { wake(); cancelTween(); liveDayScrolling = true }

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
        // Only rescue a residual once the gesture is genuinely OVER — never snap while fingers are still
        // on the trackpad (a mid-scroll pause). The catcher now marks `liveDayScrolling` for the whole
        // finger-down phase — direct AND webview-forwarded — and clears it on `.ended` (which also
        // schedules this settle), so this gate cleanly separates "paused mid-scroll" from "done".
        guard isDayLevel, !isDayFlipping, dayTween == nil, !liveDayScrolling else { return }
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
        if let pull, pull.armed, !isDayFlipping, isDayLevel {
            let toDom = pull.dir > 0 ? 1 : daysInMonth(pull.targetYear, pull.targetMonth)
            dayFlip = DayFlip(dir: pull.dir, toYear: pull.targetYear, toFocus: pull.targetMonth,
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
        wake()
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
        wake()
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
    private func beginTxn() { wake(); editGen &+= 1; if pendingUndo == nil { pendingUndo = editState } }
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
        wake()
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
        wake()
        shiftTween = Tween(from: drawerShift, to: drawerShiftTarget(id: id, drawerWidth: D),
                           start: Date(), duration: DRAWER_SHIFT_DUR, ease: easeOut)
    }
    /// Slide the calendar back to rest when the drawer closes.
    public func closeDrawerShift() {
        wake()
        shiftTween = Tween(from: drawerShift, to: 0, start: Date(), duration: DRAWER_SHIFT_DUR, ease: easeOut)
    }
    /// Re-solve the shift immediately (no tween) while the drawer is being resized, so the
    /// canvas tracks the drag frame-for-frame (like the web's `.cc-drawer-resizing`).
    public func updateDrawerShift(id: String, drawerWidth D: CGFloat) {
        wake()
        shiftTween = nil
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
    public func editTimed(_ id: String) {
        let g = snapshot()
        let src = sourceId(of: id)
        guard z >= 1.5, let e = seedEvents.first(where: { $0.id == src }) else { return }
        let tl = timelineInfo(g)
        guard tl.reveal > 0.05, tl.hourH > 0 else { return }
        let sameDay = eventsOn(year, e.month, e.day)
        guard let r = eventRect(e, year, focus, tl, g.vp, layoutDay(sameDay)[src]) else { return }
        let rect = CGRect(x: r.minX, y: tl.tlTop - tl.scroll + r.minY, width: r.width, height: r.height)
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
    private var currentDomain: NavDomain { selectedId != nil ? .event : (bandCursorActive ? .band : .block) }

    /// Tab / ⇧Tab cycle the cursor DOMAIN: block → band → event → block (⇧Tab reverses). Each step
    /// carries the position over (leftmost/earliest anchor) so the cycle round-trips.
    public func tabCursor(_ forward: Bool) {
        enterKeyboardMode()
        // Month view inserts 4 track-name stops between Event and Block (after Event, before wrapping).
        let inMonth = level(z) == 1
        if let t = trackNameCursor {
            if forward { if t < 3 { trackNameCursor = t + 1 } else { trackNameCursor = nil } }   // track 3 → block
            else if t > 0 { trackNameCursor = t - 1 }
            else {   // track 0 → event (⇧Tab); no event in view → skip the empty stop to the band cursor
                trackNameCursor = nil
                if let eid = nearestEventToBlock() { selectedId = eid; scrollToSelected() }
                else { bandCursorActive = true; bandCurTrack = 0 }
            }
            return
        }
        if inMonth {
            if selectedId != nil && forward { deselect(); trackNameCursor = 0; return }   // event → track 0
            if currentDomain == .block && !forward { trackNameCursor = 3; return }         // block ← track 3
        }
        // Day view inserts 2 dashboard stops (TODO, then NOTE) between Event and Block.
        let inDay = level(z) == 3
        if let s = dashStop {
            if forward {
                if s == .todo { dashStop = .note; onDashCommand?(.focus(.note)) }
                else { dashStop = nil; onDashCommand?(.focus(nil)); blockDay = daily.dom }   // note → block (wrap)
            } else {
                if s == .note { dashStop = .todo; onDashCommand?(.focus(.todo)) }
                else {                                                                        // todo → event (back)
                    dashStop = nil; onDashCommand?(.focus(nil))
                    if let eid = dashReturnEvent, isVisibleEvent(eid) { selectedId = eid }
                    else if let eid = nearestEventToBlock() { selectedId = eid }
                    if selectedId != nil { scrollToSelected() }
                    else { bandCursorActive = true; bandCurTrack = 0 }   // no event in view → skip the empty stop to band
                }
            }
            return
        }
        if inDay {
            if selectedId != nil && forward {   // event → TODO stop (remember it for the round-trip)
                dashReturnEvent = selectedId; deselect(); dashStop = .todo; onDashCommand?(.focus(.todo)); return
            }
            if currentDomain == .block && !forward { dashStop = .note; onDashCommand?(.focus(.note)); return }   // block ← NOTE
        }
        let from = currentDomain
        let to: NavDomain = forward
            ? (from == .block ? .band : (from == .band ? .event : .block))
            : (from == .block ? .event : (from == .event ? .band : .block))
        switch (from, to) {
        case (.block, .band), (.band, .block):   // block ⇄ band: same time cell, just add/drop the lane
            bandCursorActive = (to == .band)
            if to == .band { bandCurTrack = 0 }
        case (.band, .event):                     // band → the band under the cell, else the nearest timed/
            bandCursorActive = false              // deadline event (week/day), else skip the empty stop
            if let b = bandForCursor() { selectedId = b.id }
            else if let eid = nearestEventToBlock() { selectedId = eid; tabLink = (blockMonth, blockDay, blockHour, eid) }
            else { skipEventForward() }           // truly no event in view → skip the empty event stop
        case (.event, .band):                     // event → its start cell (band) or (lane 0, its day)
            if let sel = selectedId {
                if let b = displayBands(for: year).first(where: { $0.id == sel }) { blockMonth = b.month; bandCurTrack = b.track; blockDay = b.startDay }
                else if let e = displayEvents(for: year).first(where: { $0.id == sel }) { blockMonth = e.month; bandCurTrack = 0; blockDay = e.day }
                else if let d = displayDeadlines(for: year).first(where: { $0.id == sel }) { blockMonth = d.month; bandCurTrack = 0; blockDay = d.day }
            }
            selectedId = nil; bandCursorActive = true
            if level(z) == 0 { ensureMonthVisible(blockMonth, animated: true) }
        case (.event, .block):                    // event → its earliest anchor (with inverse memory)
            if let sel = selectedId {
                if let link = tabLink, link.eventId == sel { blockMonth = link.month; blockDay = link.day; blockHour = link.hour }
                else { setBlockToEventAnchor(sel) }
                tabLink = (blockMonth, blockDay, blockHour, sel)
            }
            selectedId = nil; bandCursorActive = false
            syncBlockVisible()
        case (.block, .event):                    // block → nearest event (with inverse memory)
            if let link = tabLink, link.month == blockMonth, link.day == blockDay,
               abs(link.hour - blockHour) < 0.01, isVisibleEvent(link.eventId) {
                selectedId = link.eventId
            } else if let eid = nearestEventToBlock() {
                selectedId = eid; tabLink = (blockMonth, blockDay, blockHour, eid)
            }
            if selectedId == nil { bandCursorActive = true; bandCurTrack = 0 }   // no event in view → skip the empty stop to the band cursor
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
        case 1: trackNameCursor = 0
        case 3: dashReturnEvent = nil; dashStop = .todo; onDashCommand?(.focus(.todo))
        default: break
        }
    }

    private func isVisibleEvent(_ id: String) -> Bool {
        viewBands().contains { $0.id == id } || viewEvents().contains { $0.id == id } || viewDeadlines().contains { $0.id == id }
    }

    /// The band the band-cursor cell sits on: the band covering `(month, track, day)`, else the nearest
    /// band in that month. Shared by Tab (band→event) and Enter-to-select.
    private func bandForCursor() -> BandEvent? {
        let m = level(z) == 0 ? blockMonth : focus
        let hit = viewBands().first { $0.month == m && $0.track == bandCurTrack && $0.startDay <= blockDay && $0.endDay >= blockDay }
        return hit ?? viewBands().filter { $0.month == m }
            .min(by: { (bandDayDist($0, blockDay), abs($0.track - bandCurTrack)) < (bandDayDist($1, blockDay), abs($1.track - bandCurTrack)) })
    }

    /// Enter from the band cursor (any view) or the block cursor (week/day) → enter event-cursor mode on
    /// the relevant event: the band under the band cell, else the nearest event to the block cell. Keeps
    /// the one-step Tab memory in sync so a following ⇧Tab round-trips back to the originating cell.
    public func selectFromCursor() {
        enterKeyboardMode()
        if bandCursorActive {
            if let b = bandForCursor() { bandCursorActive = false; selectedId = b.id; scrollToSelected() }
        } else if trackNameCursor == nil, level(z) >= 2 {   // block cursor — week/day only (per spec)
            if let eid = nearestEventToBlock() {
                selectedId = eid; tabLink = (blockMonth, blockDay, blockHour, eid); ensureSelectedEventVisible()
            }
        }
    }

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
    private func clearDashStop() {
        guard dashStop != nil else { return }
        dashStop = nil; dashNoteEditing = false; dashReturnEvent = nil; onDashCommand?(.focus(nil))
    }

    /// Land the block cursor on an event's earliest anchor (band → startDay; timed/deadline → day+hour).
    private func setBlockToEventAnchor(_ id: String) {
        if let b = displayBands(for: year).first(where: { $0.id == id }) {
            blockMonth = b.month; blockDay = min(daysInMonth(b.year, b.month), max(1, b.startDay))
        } else if let e = displayEvents(for: year).first(where: { $0.id == id }) {
            blockMonth = e.month; blockDay = e.day; blockHour = e.startHour
        } else if let d = displayDeadlines(for: year).first(where: { $0.id == id }) {
            blockMonth = d.month; blockDay = d.day; blockHour = d.hour
        }
    }

    /// Carry-over: the nearest event to the block cursor, per view.
    private func nearestEventToBlock() -> String? {
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
    private func bandDayDist(_ b: BandEvent, _ d: Int) -> Int {
        d < b.startDay ? b.startDay - d : (d > b.endDay ? d - b.endDay : 0)
    }
    private func syncBlockVisible() {
        switch level(z) {
        case 0: ensureMonthVisible(blockMonth, animated: true)
        case 2, 3: ensureHourVisible()
        default: break
        }
    }

    /// Plain-arrow navigation between events (event cursor). Day view: ↑/↓ step through the day's events
    /// top-to-bottom (bands first, then timed/deadlines by time). Year/month/week use the 2-D focus
    /// engine — a later increment.
    // One-step directional memory (see the doc): the last event move, so the exact reverse arrow returns.
    private var lastEventMove: (from: String, dx: Int, dy: Int, to: String)?

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
    private func scrollToSelected() {
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
    private func addDays(_ y: Int, _ m0: Int, _ d: Int, _ delta: Int) -> (Int, Int, Int) {
        var c = DateComponents(); c.year = y; c.month = m0 + 1; c.day = d
        let cal = Calendar(identifier: .gregorian)
        guard let base = cal.date(from: c), let nd = cal.date(byAdding: .day, value: delta, to: base) else { return (y, m0, d) }
        let x = cal.dateComponents([.year, .month, .day], from: nd)
        return (x.year ?? y, (x.month ?? 1) - 1, x.day ?? d)
    }

    /// Open the inline title editor for a band, positioned over its rect (geometry space). The click-a-
    /// selected-band gesture and the keyboard "Enter → edit title" (via `editSelectedBand`) both route here.
    public func editBand(_ id: String) {
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

    public func event(_ id: String) -> TimedEvent? { seedEvents.first { $0.id == id } ?? importedEvents.first { $0.id == id } }
    public func band(_ id: String) -> BandEvent? { seedBands.first { $0.id == id } ?? importedBands.first { $0.id == id } }
    public func deadline(_ id: String) -> Deadline? { seedDeadlines.first { $0.id == id } }
    /// Whether a source id still backs a real item — used by the UI to close a drawer whose event just
    /// vanished (e.g. deleted in Apple Calendar, then re-imported; or removed by an iCloud remote change).
    public func itemExists(_ id: String) -> Bool { event(id) != nil || band(id) != nil || deadline(id) != nil }

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
    public func setColorPreview(_ id: String, _ color: String) { wake(); colorPreview = (id, color) }
    /// Clear the preview. If `color` is given, only clears when it's still the active preview — so a
    /// swatch's mouse-leave doesn't wipe a preview a newer swatch just set.
    public func clearColorPreview(_ color: String? = nil) {
        if let color, colorPreview?.color != color { return }
        wake()
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

    /// Bands (base + recurrence/promoted ghosts) in a specific month — O(1) index lookup, with the live
    /// color preview applied like `displayBands`. Used by the band hit-test to skip other months.
    public func bandsInMonth(_ year: Int, _ month: Int) -> [BandEvent] {
        let items = ensureBandCache(year).byMonth[month] ?? []
        return withPreview(items, { $0.id }, { $0.color = $1 })
    }

    /// Provenance/kind markers for a box, from its SOURCE item's rich fields + the box's nature.
    /// Shared by the band and timed-event caches so both show the same glyphs.
    private func itemBadges(_ src: String, recurrent: Bool, promoted: Bool) -> EventBadges {
        var b: EventBadges = []
        if recurrent { b.insert(.recurrent) }
        if promoted { b.insert(.promoted) }
        if isImported(src) { b.insert(.imported) }
        if let rf = richById[src] {
            if rf.createdByAI { b.insert(.ai) }
            if rf.source != "manual" { b.insert(.imported) }
        }
        return b
    }
    /// True for a box that came from an external calendar (Apple, …). Imported ids are minted with an
    /// `apple-` prefix; `sourceId` strips occurrence/promoted suffixes so promoted imported bars match too.
    public func isImported(_ id: String) -> Bool { sourceId(of: id).hasPrefix("apple-") }

    // ── Overlay keying for imported events ─────────────────────────────────────────────────────
    // An imported event's own id is per-occurrence + time-derived: `apple-<uid>-<YYYYMMDD-HHMM>`. The
    // `hidden` dedup flag keys on that full id (it shadows one specific occurrence). But USER-authored
    // overlays — a chosen color, promote-to-band, extra notes/tags — key on the SERIES (`apple-<uid>`,
    // datestamp stripped) so they survive the event being rescheduled in Apple Calendar and apply to the
    // whole series. `sourceId` first, so a promoted/occurrence box resolves back to its imported id.
    static func applePerOccurrenceSuffix(_ id: String) -> Range<String.Index>? {
        id.range(of: "-[0-9]{8}-[0-9]{4}$", options: .regularExpression)
    }
    /// A full per-occurrence imported id → its series key; any other id unchanged.
    static func appleSeriesKey(_ id: String) -> String {
        guard id.hasPrefix("apple-"), let r = applePerOccurrenceSuffix(id) else { return id }
        return String(id[..<r.lowerBound])
    }
    /// True for an imported SERIES key (`apple-<uid>`, no datestamp) — the id user overlays sync under.
    static func isAppleSeriesKey(_ id: String) -> Bool { id.hasPrefix("apple-") && applePerOccurrenceSuffix(id) == nil }
    /// True for an imported PER-OCCURRENCE key (`apple-<uid>-<datestamp>`) — the local-only `hidden` flag.
    static func isApplePerOccurrenceKey(_ id: String) -> Bool { id.hasPrefix("apple-") && applePerOccurrenceSuffix(id) != nil }
    /// The rich-fields storage key for an item's user overlays: an imported box → its series key; else itself.
    private func overlayKey(_ id: String) -> String { Self.appleSeriesKey(sourceId(of: id)) }
    /// True if a rich entry carries USER-authored overlay data (color / promote / tags / a note the user
    /// typed) — as opposed to only an auto-derived managed block. Gates whether a series overlay is kept
    /// after its event disappears upstream, and whether it's worth syncing to iCloud.
    static func hasUserOverlay(_ rf: RichFields) -> Bool {
        rf.colorOverride != nil || rf.promoteTrack != nil || !rf.tags.isEmpty || rf.userHidden
            || !ManagedNote.splitNote(rf.notes).user.isEmpty
    }
    private func hasUserOverlay(_ rf: RichFields) -> Bool { Self.hasUserOverlay(rf) }
    /// An imported event's effective color: the user's series-level override, else the vendor calendar's.
    private func importedDisplayColor(_ e: TimedEvent) -> String {
        richById[Self.appleSeriesKey(e.id)]?.colorOverride ?? e.color
    }

    private func ensureBandCache(_ year: Int) -> (bands: [BandEvent], badges: [String: EventBadges], byMonth: [Int: [BandEvent]]) {
        if let c = bandCache, c.year == year, c.gen == editGen { return (c.bands, c.badges, c.byMonth) }
        func repeatOf(_ id: String) -> Repeat? { Repeat.parse(richById[id]?.repeatJSON) }
        // Markers for a box, from its SOURCE item's rich fields + the box's nature.
        func badges(_ src: String, recurrent: Bool, promoted: Bool) -> EventBadges {
            var b: EventBadges = []
            if recurrent { b.insert(.recurrent) }
            if promoted { b.insert(.promoted) }
            if isImported(src) { b.insert(.imported) }
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
            let total = b.endDay - b.startDay + 1   // inclusive number of days the band covers
            for o in occurrenceDates(YMD(b.year, b.month, b.startDay), r, year) {
                // A shifted occurrence can run past the end of its start month — render one bar PER month
                // it spans (Jan 30–Feb 2 → a Jan 30–31 bar AND a Feb 1–2 bar) instead of clamping it flat
                // at the boundary. All segments share the occurrence's start-date key; tail segments get a
                // distinct box id via SEGMENT_MARKER (ignored by sourceId, stripped by occurrenceKey).
                let key = occKey(b.id, o)
                var y = year, m = o.month, d = o.day, left = total, seg = 0
                while left > 0, y == year {                 // stop at the year edge (this cache is year-scoped)
                    let dim = daysInMonth(y, m)
                    let daysHere = min(left, dim - d + 1)
                    let segId = seg == 0 ? key : "\(key)\(SEGMENT_MARKER)\(seg)"
                    out.append(BandEvent(id: segId, year: year, month: m, track: b.track,
                                         startDay: d, endDay: d + daysHere - 1, title: b.title, color: b.color))
                    badgeMap[segId] = badges(b.id, recurrent: true, promoted: false)
                    left -= daysHere
                    if m == 11 { m = 0; y += 1 } else { m += 1 }
                    d = 1; seg += 1
                }
            }
        }
        func promote(_ id: String, _ y: Int, _ m: Int, _ day: Int, _ title: String, _ color: String) {
            guard let track = richById[overlayKey(id)]?.promoteTrack else { return }
            let r = repeatOf(id)
            if y == year && !baseHidden(occDate(YMD(y, m, day)), r) {
                // A distinct occurrence-key id (not the raw source id) so the promoted bar is its own
                // box: selecting the original timeline event highlights it (same source) without also
                // making it the focused box, and vice-versa. sourceId() maps both back to `id`.
                // `~p` so this promoted bar is a DISTINCT box from the timeline occurrence `id@Y-M-D`.
                let key = occKey(id, YMD(y, m, day)) + PROMOTED_SUFFIX
                out.append(BandEvent(id: key, year: year, month: m, track: track, startDay: day, endDay: day, title: title, color: color))
                badgeMap[key] = badges(id, recurrent: r != nil, promoted: true)
            }
            for o in occurrenceDates(YMD(y, m, day), r, year) {
                let key = occKey(id, o) + PROMOTED_SUFFIX
                out.append(BandEvent(id: key, year: year, month: o.month, track: track,
                                     startDay: o.day, endDay: o.day, title: title, color: color))
                badgeMap[key] = badges(id, recurrent: true, promoted: true)
            }
        }
        for e in seedEvents { promote(e.id, e.year, e.month, e.day, e.title, e.color) }
        for d in seedDeadlines { promote(d.id, d.year, d.month, d.day, d.title, d.color) }
        // Imported events the user promoted (rich.promoteTrack on the series key) → one ghost band per
        // visible occurrence, in its overridden color. Skip hidden (deduped-shadow) occurrences.
        for e in importedEvents where e.year == year && richById[e.id]?.hidden != true {
            promote(e.id, e.year, e.month, e.day, e.title, importedDisplayColor(e))
        }
        for b in importedBands where b.year == year {   // Apple Calendar all-day events (read-only)
            out.append(b)
            badgeMap[b.id] = badges(b.id, recurrent: false, promoted: false)
        }

        var byMonth: [Int: [BandEvent]] = [:]
        for b in out { byMonth[b.month, default: []].append(b) }
        bandCache = (year, editGen, out, badgeMap, byMonth)
        return (out, badgeMap, byMonth)
    }

    // ── Derived timed events for the day / detail timeline ──────────────────────────────
    // Base timed events (a base deleted via exdate / past `until` is dropped) + recurring "ghost"
    // occurrences on their occurrence days (holes = exdates), each a copy with the same hours and a
    // synthetic occKey id. The timeline only draws the focused day's items, so off-day occurrences
    // are culled downstream; the ghosts just make a recurring event appear on every occurrence day.
    // Cached per (year, editGen) — like displayBands.
    // `byDay` indexes the expanded events (base + ghosts) by `month*100+day` so hit-testing and per-day
    // layout packing are O(1) lookups instead of a full-array filter on every hover / rect solve.
    private var eventCache: (year: Int, gen: Int, events: [TimedEvent], badges: [String: EventBadges], byDay: [Int: [TimedEvent]])?
    public func displayEvents(for year: Int) -> [TimedEvent] {
        withPreview(ensureEventCache(year).events, { $0.id }, { $0.color = $1 })
    }
    public func eventBadges(for year: Int) -> [String: EventBadges] { ensureEventCache(year).badges }

    /// Timed events (base + recurrence ghosts) on a specific calendar day — O(1) index lookup, with the
    /// live color preview applied like `displayEvents`. Used by hit-testing + per-day layout packing.
    public func eventsOn(_ year: Int, _ month: Int, _ day: Int) -> [TimedEvent] {
        let items = ensureEventCache(year).byDay[month * 100 + day] ?? []
        return withPreview(items, { $0.id }, { $0.color = $1 })
    }

    /// Re-express a stored (anchor-tz) timed event as a DISPLAY copy in the current main tz: the start
    /// date/time is converted (normalized across midnight, so year/month/day may change), and the end
    /// preserves the original duration — so `endHour` may exceed 24 for a span that now crosses midnight
    /// (the renderer splits it; see cross-midnight handling). A nil anchor (demo/sample data) is treated
    /// as already-in-main-tz → identity. The id and anchorTz are preserved (hit-testing + secondary label).
    func displayEvent(_ e: TimedEvent) -> TimedEvent {
        guard let anchor = e.anchorTz,
              !DeadlineTZ.sameOffset(anchor, mainTz, at: DeadlineTZ.instant(e.year, e.month, e.day, e.startHour))
        else { return e }
        let dur = max(0, e.endHour - e.startHour)
        let w = DeadlineTZ.convertWall(e.year, e.month, e.day, e.startHour, from: anchor, to: mainTz)
        var out = e
        out.year = w.year; out.month = w.month; out.day = w.day
        out.startHour = w.hour; out.endHour = w.hour + dur
        return out
    }
    /// The deadline analog: convert the single moment into the main tz (day/month/year normalized).
    func displayDeadline(_ d: Deadline) -> Deadline {
        guard let anchor = d.anchorTz,
              !DeadlineTZ.sameOffset(anchor, mainTz, at: DeadlineTZ.instant(d.year, d.month, d.day, d.hour))
        else { return d }
        let w = DeadlineTZ.convertWall(d.year, d.month, d.day, d.hour, from: anchor, to: mainTz)
        var out = d
        out.year = w.year; out.month = w.month; out.day = w.day; out.hour = w.hour
        return out
    }
    /// Inverse of `displayEvent`: fold a DISPLAY (main-tz) event back into its stored anchor zone. Mouse
    /// drags work in the on-screen (main-tz) grid, so a moved/resized event is converted back here before
    /// it's written to `seedEvents`. Preserves the anchorTz and the (tz-invariant) duration.
    private func anchorEvent(_ e: TimedEvent) -> TimedEvent {
        guard let anchor = e.anchorTz,
              !DeadlineTZ.sameOffset(anchor, mainTz, at: DeadlineTZ.instant(e.year, e.month, e.day, e.startHour))
        else { return e }
        let dur = max(0, e.endHour - e.startHour)
        let w = DeadlineTZ.convertWall(e.year, e.month, e.day, e.startHour, from: mainTz, to: anchor)
        var out = e
        out.year = w.year; out.month = w.month; out.day = w.day
        out.startHour = w.hour; out.endHour = w.hour + dur
        return out
    }
    private func anchorDeadline(_ d: Deadline) -> Deadline {
        guard let anchor = d.anchorTz,
              !DeadlineTZ.sameOffset(anchor, mainTz, at: DeadlineTZ.instant(d.year, d.month, d.day, d.hour))
        else { return d }
        let w = DeadlineTZ.convertWall(d.year, d.month, d.day, d.hour, from: mainTz, to: anchor)
        var out = d
        out.year = w.year; out.month = w.month; out.day = w.day; out.hour = w.hour
        return out
    }

    private func ensureEventCache(_ year: Int) -> (events: [TimedEvent], badges: [String: EventBadges], byDay: [Int: [TimedEvent]]) {
        if let c = eventCache, c.year == year, c.gen == editGen { return (c.events, c.badges, c.byDay) }
        func repeatOf(_ id: String) -> Repeat? { Repeat.parse(richById[id]?.repeatJSON) }
        var out: [TimedEvent] = []
        var badgeMap: [String: EventBadges] = [:]
        // Anchor→main conversion can push an event across the year boundary (±1 day), so we consider
        // seeds anchored in the neighbor years too and keep those whose DISPLAY date lands in `year`.
        // When an anchor equals the main tz (the common case) conversion is the identity, so a neighbor
        // event just converts back to its own year and is dropped here — same result as the old filter.
        func take(_ e: TimedEvent, _ badge: EventBadges) {
            let d = displayEvent(e)
            guard d.year == year else { return }
            out.append(d); badgeMap[d.id] = badge
        }
        for e in seedEvents where abs(e.year - year) <= 1 {
            if baseHidden(occDate(YMD(e.year, e.month, e.day)), repeatOf(e.id)) { continue }
            take(e, itemBadges(e.id, recurrent: repeatOf(e.id) != nil, promoted: false))
        }
        for e in seedEvents {
            guard let r = repeatOf(e.id) else { continue }
            for yy in (year - 1)...(year + 1) {
                for o in occurrenceDates(YMD(e.year, e.month, e.day), r, yy) {
                    take(TimedEvent(id: occKey(e.id, o), year: yy, month: o.month, day: o.day,
                                    startHour: e.startHour, endHour: e.endHour, title: e.title,
                                    color: e.color, anchorTz: e.anchorTz),
                         itemBadges(e.id, recurrent: true, promoted: false))
                }
            }
        }
        let revealHidden = showHiddenImported
        for e in importedEvents where abs(e.year - year) <= 1 {   // Apple Calendar (read-only, already expanded)
            if richById[e.id]?.hidden == true { continue }   // deduped shadow of the user's own event → not drawn
            let userHidden = richById[Self.appleSeriesKey(e.id)]?.userHidden == true
            if userHidden && !revealHidden { continue }   // user hid this series → hidden unless "Show Hidden" is on
            var ev = e
            ev.color = importedDisplayColor(e)   // apply the user's color override, if any
            var b = itemBadges(e.id, recurrent: false, promoted: false)
            if userHidden { b.insert(.hidden) }   // revealed hidden event → dotted accent bar
            take(ev, b)
        }
        var byDay: [Int: [TimedEvent]] = [:]
        for e in out { byDay[e.month * 100 + e.day, default: []].append(e) }
        eventCache = (year, editGen, out, badgeMap, byDay)
        return (out, badgeMap, byDay)
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
        // Same neighbor-year scan + convert-then-filter as ensureEventCache: a moment near midnight can
        // land in an adjacent display year when the anchor differs from the main tz. Identity otherwise.
        func take(_ d: Deadline) {
            let dd = displayDeadline(d)
            if dd.year == year { out.append(dd) }
        }
        for d in seedDeadlines where abs(d.year - year) <= 1 {
            if baseHidden(occDate(YMD(d.year, d.month, d.day)), repeatOf(d.id)) { continue }
            take(d)
        }
        for d in seedDeadlines {
            guard let r = repeatOf(d.id) else { continue }
            for yy in (year - 1)...(year + 1) {
                for o in occurrenceDates(YMD(d.year, d.month, d.day), r, yy) {
                    take(Deadline(id: occKey(d.id, o), year: yy, month: o.month, day: o.day,
                                  hour: d.hour, title: d.title, color: d.color, anchorTz: d.anchorTz))
                }
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
    // The common case (mid-year focus) has no boundary years, so hand back the cached array directly —
    // `cached + []` would copy it every frame. Only concatenate when a Jan/Dec spillover column exists.
    public func viewEvents() -> [TimedEvent] { let b = boundaryYears; return b.isEmpty ? displayEvents(for: year) : displayEvents(for: year) + b.flatMap { displayEvents(for: $0) } }
    public func viewBands() -> [BandEvent] { let b = boundaryYears; return b.isEmpty ? displayBands(for: year) : displayBands(for: year) + b.flatMap { displayBands(for: $0) } }
    public func viewDeadlines() -> [Deadline] { let b = boundaryYears; return b.isEmpty ? displayDeadlines(for: year) : displayDeadlines(for: year) + b.flatMap { displayDeadlines(for: $0) } }
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

    // ── Rich fields (tags / repeat / promote / color), keyed by the item's OVERLAY id ──────────
    // The drawer opens with the source (base) id, so these read/write the same key. For imported events
    // the overlay id is the series key (see `overlayKey`), so a color/promote/note applies series-wide
    // and survives rescheduling. Not on the undo stack yet (EditState only snapshots the lean arrays);
    // they persist + invalidate the display cache.
    public func richTags(_ id: String) -> [String] { richById[overlayKey(id)]?.tags ?? [] }
    public func notes(_ id: String) -> String { richById[overlayKey(id)]?.notes ?? "" }
    public func setNotes(_ id: String, _ v: String) {
        let key = overlayKey(id)
        var rf = richById[key] ?? RichFields()
        guard rf.notes != v else { return }
        rf.notes = v; richById[key] = rf
        // NOT in the calendar undo stack: notes are edited in the drawer's CodeMirror, which owns its
        // own undo (Cmd+Z while it's focused). Recording here would let its internal undo re-post the
        // note and pollute the calendar stack. Matches the web (notes are a separate lower layer).
        schedulePersist()
    }
    /// The user's chosen color for an imported event (nil = use the vendor calendar's color).
    public func colorOverride(_ id: String) -> String? { richById[overlayKey(id)]?.colorOverride }
    public func setColorOverride(_ id: String, _ color: String?) { mutateRich(overlayKey(id)) { $0.colorOverride = color } }
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

    /// All items carrying notes (with their identity + date) — the assistant's TODO scan walks
    /// these plus the daily notes to reconstruct what the TODO panel shows.
    public func notedItems() -> [(id: String, title: String, kind: ItemKind,
                                  year: Int, month: Int, day: Int, notes: String)] {
        var out: [(String, String, ItemKind, Int, Int, Int, String)] = []
        for (id, rf) in richById {
            guard let notes = rf.notes, !notes.isEmpty else { continue }
            if let e = seedEvents.first(where: { $0.id == id }) {
                out.append((id, e.title, .timed, e.year, e.month, e.day, notes))
            } else if let b = seedBands.first(where: { $0.id == id }) {
                out.append((id, b.title, .band, b.year, b.month, b.startDay, notes))
            } else if let d = seedDeadlines.first(where: { $0.id == id }) {
                out.append((id, d.title, .deadline, d.year, d.month, d.day, notes))
            }
        }
        return out
    }

    /// Every stored daily note, keyed by ISO date "YYYY-MM-DD".
    public func allDailyNotes() -> [String: String] { dailyNotes }

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
        let occKey = occurrenceKey(of: occKey)   // drop the promoted-band marker if present
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
    /// `p` shifted by `n` days (0-based month, crossing month/year boundaries). UTC to avoid DST drift.
    static func addDaysYMD(_ p: YMD, _ n: Int) -> YMD {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        let d = c.date(from: DateComponents(year: p.year, month: p.month + 1, day: p.day)) ?? Date()
        let nd = c.date(byAdding: .day, value: n, to: d) ?? d
        let x = c.dateComponents([.year, .month, .day], from: nd)
        return YMD(x.year ?? p.year, (x.month ?? 1) - 1, x.day ?? p.day)
    }

    // ── Band occurrence dates (for the recurring-band drawer) ──────────────────────────────────
    /// The date range of the occurrence a band BOX currently represents — the shifted occurrence for a
    /// ghost, or the base band's own range. `occKey` is the selected box's occurrence key. Cross-month
    /// spans are honoured (start and end may be in different months). nil if not a band.
    public func bandOccurrenceRange(_ occKey: String) -> (start: YMD, end: YMD)? {
        let src = sourceId(of: occKey)
        guard let base = seedBands.first(where: { $0.id == src }) else { return nil }
        let start = occurrenceYMD(src, occKey) ?? YMD(base.year, base.month, base.startDay)
        return (start, Self.addDaysYMD(start, base.endDay - base.startDay))
    }
    /// A band's base (FIRST) occurrence start date — what the drawer's "Started …" button jumps to.
    public func bandBaseStart(_ id: String) -> YMD? {
        guard let base = seedBands.first(where: { $0.id == sourceId(of: id) }) else { return nil }
        return YMD(base.year, base.month, base.startDay)
    }
    public func repeatConfig(_ id: String) -> Repeat? { Repeat.parse(richById[id]?.repeatJSON) }
    public func promoteTrack(_ id: String) -> Int? { richById[overlayKey(id)]?.promoteTrack }

    private func mutateRich(_ id: String, _ mutate: (inout RichFields) -> Void) {
        beginTxn()             // tags / repeat / promote are structural edits → one undo step each
        var rf = richById[id] ?? RichFields()
        mutate(&rf)
        richById[id] = rf
        editGen &+= 1          // repeat / promote change the expanded display set → invalidate the cache
        scheduleCommit()
        schedulePersist()
    }
    public func setTags(_ id: String, _ tags: [String]) { mutateRich(overlayKey(id)) { $0.tags = tags } }
    public func setPromoteTrack(_ id: String, _ t: Int?) { mutateRich(overlayKey(id)) { $0.promoteTrack = t } }
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

    /// Everything the delete-confirmation dialog needs about the current selection: the source id, the
    /// focused occurrence-box id (so a recurring occurrence can be dropped precisely), whether it recurs
    /// (→ scope choices, or the "make a local copy" note for imported series), and whether it's imported
    /// (→ the Hide flow instead of Delete). Nil only when nothing is selected.
    public struct DeleteTarget: Equatable {
        public let id: String; public let occKey: String; public let recurring: Bool
        public let imported: Bool
        public let alreadyHidden: Bool   // imported + already user-hidden → the "can't delete / already hidden" dialog
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
        return importedEvents.filter { Self.appleSeriesKey($0.id) == key }.count > 1
    }
    /// "Hide" an imported event (or series): a persistent user overlay on the series key that keeps every
    /// occurrence out of the view, surviving re-imports (unlike the dedup `hidden`). Undoable + synced.
    public func hideImportedSeries(_ id: String) {
        mutateRich(Self.appleSeriesKey(sourceId(of: id))) { $0.userHidden = true }
        if let sel = selectedId, isImported(sel) { selectedId = nil }
        deadlineGen &+= 1; wake()
    }
    /// Reverse a hide — clear the series' `userHidden` overlay so it draws normally again.
    public func unhideImportedSeries(_ id: String) {
        mutateRich(Self.appleSeriesKey(sourceId(of: id))) { $0.userHidden = false }
        deadlineGen &+= 1; wake()
    }
    /// Whether an imported box's series is currently user-hidden (drives the drawer's Unhide button).
    public func isUserHidden(_ id: String) -> Bool {
        richById[Self.appleSeriesKey(sourceId(of: id))]?.userHidden == true
    }

    // ── View preferences ───────────────────────────────────────────────────────────────────────
    nonisolated public static let showHiddenImportedKey = "cc.view.showHiddenImported"
    /// View ▸ Current Timezone — the main tz for deadline origin-time labels. "auto" = device zone.
    nonisolated public static let mainTzKey = "cc.view.mainTz"
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
        editGen &+= 1; deadlineGen &+= 1; wake()
    }

    // ── Programmatic CRUD for the AI assistant ─────────────────────────────────────────
    // Parameterized create/update the cursor-driven UI methods (createEventAtBlock etc.) don't
    // offer. Each wraps beginTxn/commitTxn so it's one undo step, invalidates the display cache
    // (beginTxn bumps editGen), and persists (commitTxn → schedulePersist). `byAI` stamps
    // RichFields.createdByAI for provenance. The assistant's create/update tools call these.

    /// The kind an item id resolves to, for the tools' routing + the auditor's context.
    public enum ItemKind: String, Sendable { case timed, band, deadline }
    public func kind(of id: String) -> ItemKind? {
        if seedEvents.contains(where: { $0.id == id }) { return .timed }
        if seedBands.contains(where: { $0.id == id }) { return .band }
        if seedDeadlines.contains(where: { $0.id == id }) { return .deadline }
        return nil
    }

    private func setRich(_ id: String, notes: String?, tags: [String], byAI: Bool,
                         promoteTrack: Int? = nil) {
        guard notes != nil || !tags.isEmpty || byAI || promoteTrack != nil else { return }
        var rf = richById[id] ?? RichFields()
        if let notes { rf.notes = notes }
        if !tags.isEmpty { rf.tags = tags }
        if let promoteTrack { rf.promoteTrack = max(0, min(3, promoteTrack)) }
        if byAI { rf.createdByAI = true }
        richById[id] = rf
    }

    @discardableResult
    public func createTimedEvent(year: Int, month: Int, day: Int, startHour: CGFloat, endHour: CGFloat,
                                 title: String, color: String, notes: String? = nil,
                                 tags: [String] = [], promoteTrack: Int? = nil,
                                 byAI: Bool = false) -> String {
        beginTxn()
        let id = "new-\(UUID().uuidString)"
        seedEvents.append(TimedEvent(id: id, year: year, month: month, day: day,
                                     startHour: startHour, endHour: endHour, title: title, color: color,
                                     anchorTz: anchorNow))
        setRich(id, notes: notes, tags: tags, byAI: byAI, promoteTrack: promoteTrack)
        selectedId = id
        commitTxn()
        return id
    }

    @discardableResult
    public func createBand(year: Int, month: Int, track: Int, startDay: Int, endDay: Int,
                           title: String, color: String, notes: String? = nil,
                           tags: [String] = [], byAI: Bool = false) -> String {
        beginTxn()
        let id = "new-\(UUID().uuidString)"
        seedBands.append(BandEvent(id: id, year: year, month: month, track: max(0, min(3, track)),
                                   startDay: startDay, endDay: max(startDay, endDay),
                                   title: title, color: color))
        setRich(id, notes: notes, tags: tags, byAI: byAI)
        selectedId = id
        commitTxn()
        return id
    }

    @discardableResult
    public func createDeadline(year: Int, month: Int, day: Int, hour: CGFloat, title: String,
                               color: String, originTz: String? = nil, notes: String? = nil,
                               tags: [String] = [], promoteTrack: Int? = nil,
                               byAI: Bool = false) -> String {
        beginTxn()
        let id = "new-\(UUID().uuidString)"
        // If a distinct origin zone is given, the deadline is anchored THERE: the caller passes coords in
        // the main tz, so re-express them as the origin wall-clock and anchor to it. Otherwise anchor to
        // the current view zone. (Replaces the legacy originTz label — anchorTz now drives positioning.)
        var (dy, dm, dd, dh) = (year, month, day, hour)
        let anchor: String
        if let otz = originTz,
           !DeadlineTZ.sameOffset(otz, mainTz, at: DeadlineTZ.instant(year, month, day, hour)) {
            let w = DeadlineTZ.convertWall(year, month, day, hour, from: mainTz, to: otz)
            (dy, dm, dd, dh) = (w.year, w.month, w.day, w.hour); anchor = DeadlineTZ.concrete(otz)
        } else {
            anchor = anchorNow
        }
        seedDeadlines.append(Deadline(id: id, year: dy, month: dm, day: dd, hour: dh,
                                      title: title, color: color, anchorTz: anchor))
        setRich(id, notes: notes, tags: tags, byAI: byAI, promoteTrack: promoteTrack)
        selectedId = id
        commitTxn()
        return id
    }

    /// The one cross-month band segmentation walk (bands are stored per-month, so a range is split
    /// into one BandEvent per month, clamped to each month's days). Shared by createBandSpan and
    /// reshapeBand — must run inside an open txn. `seed` stamps per-segment extras (rich fields).
    private func appendBandSegments(from start: (Int, Int, Int), to end: (Int, Int, Int),
                                    track: Int, title: String, color: String,
                                    seed: (String) -> Void) -> [String] {
        // Order the endpoints so start ≤ end regardless of how they were passed.
        var (sy, sm, sd) = start
        var (ey, em, ed) = end
        if (ey, em, ed) < (sy, sm, sd) { swap(&sy, &ey); swap(&sm, &em); swap(&sd, &ed) }

        var ids: [String] = []
        var (y, m) = (sy, sm)
        while (y, m) <= (ey, em) {
            let segStart = (y == sy && m == sm) ? max(1, sd) : 1
            let segEnd = (y == ey && m == em) ? min(daysInMonth(y, m), ed) : daysInMonth(y, m)
            let id = "new-\(UUID().uuidString)"
            seedBands.append(BandEvent(id: id, year: y, month: m, track: max(0, min(3, track)),
                                       startDay: segStart, endDay: max(segStart, segEnd),
                                       title: title, color: color))
            seed(id)
            ids.append(id)
            m += 1; if m > 11 { m = 0; y += 1 }
        }
        if let last = ids.last { selectedId = last }
        return ids
    }

    /// Create an all-day band that may span multiple months (one segment per month, shared
    /// title/color/lane). Returns the segment ids in chronological order; a single-month range
    /// yields one id (same as `createBand`).
    @discardableResult
    public func createBandSpan(startYear: Int, startMonth: Int, startDay: Int,
                               endYear: Int, endMonth: Int, endDay: Int, track: Int,
                               title: String, color: String, notes: String? = nil,
                               tags: [String] = [], byAI: Bool = false) -> [String] {
        beginTxn()
        let ids = appendBandSegments(from: (startYear, startMonth, startDay),
                                     to: (endYear, endMonth, endDay),
                                     track: track, title: title, color: color) { id in
            setRich(id, notes: notes, tags: tags, byAI: byAI)
        }
        commitTxn()
        return ids
    }

    /// Re-span an existing band to a new (possibly cross-month) range in ONE undo step, preserving
    /// its title/color/track and rich fields (notes/tags/…). The old id is retired; returns the new
    /// segment ids in chronological order. Empty if `id` isn't a band.
    @discardableResult
    public func reshapeBand(id: String, startYear: Int, startMonth: Int, startDay: Int,
                            endYear: Int, endMonth: Int, endDay: Int) -> [String] {
        guard let b = seedBands.first(where: { $0.id == id }) else { return [] }
        let rich = richById[id]
        beginTxn()
        seedBands.removeAll { $0.id == id }
        richById[id] = nil
        if selectedId == id { selectedId = nil }
        let ids = appendBandSegments(from: (startYear, startMonth, startDay),
                                     to: (endYear, endMonth, endDay),
                                     track: b.track, title: b.title, color: b.color) { nid in
            if let rich { richById[nid] = rich }
        }
        commitTxn()
        return ids
    }

    /// Patch an existing item — only the non-nil fields change. Returns false if `id` is unknown.
    /// `byAI` stamps provenance on edited items too (matches the web's `"ai"` actor).
    @discardableResult
    public func updateItem(id: String, title: String? = nil, color: String? = nil,
                           year: Int? = nil, month: Int? = nil, day: Int? = nil,
                           startHour: CGFloat? = nil, endHour: CGFloat? = nil,
                           track: Int? = nil, startDay: Int? = nil, endDay: Int? = nil,
                           hour: CGFloat? = nil, notes: String? = nil, tags: [String]? = nil,
                           promoteTrack: Int? = nil, clearPromote: Bool = false,
                           byAI: Bool = false) -> Bool {
        beginTxn()
        var found = true
        if let i = seedEvents.firstIndex(where: { $0.id == id }) {
            if let title { seedEvents[i].title = title }
            if let color { seedEvents[i].color = color }
            if let year { seedEvents[i].year = year }
            if let month { seedEvents[i].month = month }
            if let day { seedEvents[i].day = day }
            if let startHour { seedEvents[i].startHour = startHour }
            if let endHour { seedEvents[i].endHour = endHour }
        } else if let i = seedBands.firstIndex(where: { $0.id == id }) {
            if let title { seedBands[i].title = title }
            if let color { seedBands[i].color = color }
            if let year { seedBands[i].year = year }
            if let month { seedBands[i].month = month }
            if let track { seedBands[i].track = max(0, min(3, track)) }
            if let startDay { seedBands[i].startDay = startDay }
            if let endDay { seedBands[i].endDay = max(seedBands[i].startDay, endDay) }
        } else if let i = seedDeadlines.firstIndex(where: { $0.id == id }) {
            if let title { seedDeadlines[i].title = title }
            if let color { seedDeadlines[i].color = color }
            if let year { seedDeadlines[i].year = year }
            if let month { seedDeadlines[i].month = month }
            if let day { seedDeadlines[i].day = day }
            if let hour { seedDeadlines[i].hour = hour }
        } else {
            found = false
        }
        if found {
            if notes != nil || tags != nil || byAI || promoteTrack != nil || clearPromote {
                var rf = richById[id] ?? RichFields()
                if let notes { rf.notes = notes }
                if let tags { rf.tags = tags }
                if clearPromote { rf.promoteTrack = nil }
                else if let promoteTrack { rf.promoteTrack = max(0, min(3, promoteTrack)) }
                if byAI { rf.createdByAI = true }
                richById[id] = rf
            }
        }
        commitTxn()
        return found
    }

    /// The (year, month0, day) an item sits on — for the auditor's trusted date context.
    /// Bands report their start day.
    public func dateOf(_ id: String) -> (Int, Int, Int)? {
        if let e = seedEvents.first(where: { $0.id == id }) { return (e.year, e.month, e.day) }
        if let b = seedBands.first(where: { $0.id == id }) { return (b.year, b.month, b.startDay) }
        if let d = seedDeadlines.first(where: { $0.id == id }) { return (d.year, d.month, d.day) }
        return nil
    }

    /// One-line summaries of every item on a date — the auditor's trusted "what's already here".
    public func itemsOn(year: Int, month: Int, day: Int) -> [String] {
        var out: [String] = []
        for e in displayEvents(for: year) where e.month == month && e.day == day {
            out.append("timed: \(e.title) \(String(format: "%.0f", e.startHour))–\(String(format: "%.0f", e.endHour))h")
        }
        for b in displayBands(for: year) where b.month == month && day >= b.startDay && day <= b.endDay {
            out.append("band: \(b.title) (lane \(b.track))")
        }
        for d in displayDeadlines(for: year) where d.month == month && d.day == day {
            out.append("deadline: \(d.title)")
        }
        return out
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
        // Timed events live ONLY in the hour timeline. A scrolled-up event's rect can extend above the
        // timeline top (into the band/track lanes), but the drawn sticker is clipped there — so clip the
        // hit-test too, else hovering/dragging empty track space would grab the off-screen event.
        guard p.y >= tl.tlTop, p.y <= tl.tlBottom else { return nil }
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
        // The column maps to one calendar day (resolveDate handles Dec↔Jan spillover into the neighbor
        // year); the per-day index then returns exactly that day's events (base + ghosts).
        guard let rd = resolveDate(year, focus, relCursor) else { return nil }
        let sameDay = eventsOn(rd.year, rd.month, rd.day)
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

    /// The quick-add "+" affordance for a deadline: when the cursor hovers near a day column's LEFT edge
    /// (hover.nearLeft, within ADD_EDGE_THRESHOLD) in week/day view, offer to create a deadline snapped to
    /// the nearest hour line. Returns its screen point + the target date/hour, or nil when it shouldn't
    /// show (not near-left, off the timeline, or an existing deadline already sits on that day+hour).
    public func deadlineAddSpot(_ g: SceneInput) -> DeadlineAddSpot? {
        guard g.z >= 1.5, hover.nearLeft == true, let dom = hover.dom, let hf = hover.hourFrac else { return nil }
        let hour = min(23, max(0, Int(hf.rounded())))              // snap to the nearest hour line
        guard let r = resolveDate(year, focus, dom) else { return nil }
        if displayDeadlines(for: r.year).contains(where: { $0.month == r.month && $0.day == r.day && abs($0.hour - CGFloat(hour)) < 1e-6 }) {
            return nil   // already a deadline there — don't offer to add
        }
        let tl = timelineInfo(g)
        guard tl.hourH > 0 else { return nil }
        let x = tl.x0 + CGFloat(dom - 1) * tl.colW                 // day column's left edge
        let y = tl.tlTop + CGFloat(hour) * tl.hourH - tl.scroll    // the hour line
        guard y >= tl.tlTop, y <= tl.tlBottom, x >= Layout.labelW - 1, x <= g.vp.w else { return nil }
        let hovering = pointerPos.map { hypot($0.x - x, $0.y - y) <= 10 } ?? false   // cursor over the 15px "+"
        return DeadlineAddSpot(x: x, y: y, year: r.year, month: r.month, day: r.day, hour: hour, hovering: hovering)
    }

    private func applyMove(_ d: Drag, _ p: CGPoint, _ tl: TimelineInfo) {
        guard let orig = d.orig, let idx = seedEvents.firstIndex(where: { $0.id == d.eventId }) else { return }
        beginTxn()
        // The grid is in the main (view) timezone, so compute the move in DISPLAY space against the
        // display-converted original, then fold the result back into the event's anchor zone to store.
        var ev = displayEvent(orig)
        let dur = ev.endHour - ev.startHour
        let ns = max(0, min(24 - dur, snap(ev.startHour + (p.y - d.startPoint.y) / tl.hourH, 15)))
        ev.startHour = ns; ev.endHour = ns + dur
        if let dom = pointToSlot(p.x, p.y, tl).dom, let r = resolveDate(year, focus, dom) { ev.year = r.year; ev.month = r.month; ev.day = r.day }
        seedEvents[idx] = anchorEvent(ev)
    }

    private func applyResize(_ d: Drag, _ p: CGPoint, _ tl: TimelineInfo, top: Bool) {
        guard let idx = seedEvents.firstIndex(where: { $0.id == d.eventId }) else { return }
        beginTxn()
        let hf = pointToSlot(p.x, p.y, tl).hourFrac   // display-space hour under the cursor
        var ev = displayEvent(seedEvents[idx])
        if top { ev.startHour = min(ev.endHour - 0.25, snap(hf, 15)) }
        else { ev.endHour = max(ev.startHour + 0.25, snap(hf, 15)) }
        seedEvents[idx] = anchorEvent(ev)
    }

    private func applyCreate(_ p: CGPoint, _ tl: TimelineInfo) {
        guard var d = drag else { return }
        beginTxn()   // snapshot pre-create so undo removes the new event
        if d.eventId == nil {
            guard let mo = d.createMonth, let dy = d.createDay, let a = d.anchorHour else { return }
            // UUID (not the counter) so ids are globally unique — two devices creating
            // offline must never mint the same recordName. Prefix kept for readability.
            let id = "new-\(UUID().uuidString)"
            seedEvents.append(TimedEvent(id: id, year: d.createYear ?? year, month: mo, day: dy, startHour: a, endHour: min(24, a + 0.25), title: "New event", color: "blue", anchorTz: anchorNow))
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

    /// Months whose band lanes could contain point `p` — a conservative superset that prunes the band
    /// hit-test to a handful of months instead of the whole year. Week/day view (z≥1.5) positions bands
    /// relative to the focus window, so the focus month and its two neighbors can spill in. Year/month
    /// view positions each band in its own month row, so only the row(s) under `p.y` qualify (frameFor is
    /// anim-aware, so a month page-turn's two overlapping rows are both included).
    private func candidateBandMonths(_ p: CGPoint, _ g: SceneInput) -> [Int] {
        if g.z >= 1.5 { return [g.focus - 1, g.focus, g.focus + 1].filter { $0 >= 0 && $0 <= 11 } }
        var months: [Int] = []
        for m in 0..<12 {
            let f = frameFor(m, g, anim: g.monthAnim)
            if f.opacity >= 0.02, p.y >= f.bandY, p.y < f.bandY + 4 * f.trackH { months.append(m) }
        }
        return months
    }

    private func bandAt(_ p: CGPoint, _ g: SceneInput) -> (id: String, zone: PointerKind)? {
        // Return the TOP-most band under the cursor, matching the draw order: selected and
        // hovered are raised to the front; otherwise later start > shorter length > higher id.
        func tier(_ b: BandEvent) -> Int { b.id == selectedId ? 2 : (b.id == hoveredEventId ? 1 : 0) }
        var best: (b: BandEvent, r: BandRect, rect: CGRect)?
        // Only the candidate months' bands can be under the cursor — skip the rest of the year's ghosts.
        for b in candidateBandMonths(p, g).flatMap({ bandsInMonth(year, $0) }) {   // recurrence + promoted ghosts too
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
        let tl = timelineInfo(g)
        guard p.y >= tl.tlTop, p.y <= tl.tlBottom else { return nil }   // clip to the timeline (see eventAt)
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
        // Delta-based, in DISPLAY (main-tz) space: move relative to where the deadline was shown at
        // mouse-down, by the mouse delta — never jump to the absolute pointer (important when dragging the
        // side label, not the line). The result is folded back into the deadline's anchor zone to store.
        var dd = displayDeadline(orig)
        dd.hour = max(0, min(24, snap(dd.hour + (p.y - d.startPoint.y) / tl.hourH, 15)))
        let dayDelta = tl.colW > 0 ? Int(((p.x - d.startPoint.x) / tl.colW).rounded()) : 0
        if dayDelta != 0, let origRd = relDomOf(year, focus, dd.year, dd.month, dd.day),
           let r = resolveDate(year, focus, origRd + dayDelta) {
            dd.year = r.year; dd.month = r.month; dd.day = r.day
        }
        seedDeadlines[idx] = anchorDeadline(dd)
    }

    public func onEscape() {
        cancelTween()
        trackNameCursor = nil   // leaving month view drops the track-name stops
        clearDashStop()         // leaving day view drops the dashboard stops
        let dest = max(0, level(z) - 1)
        tweenZ(to: CGFloat(dest))
        syncBlockToView(dest)   // carry the block cursor to the view we're zooming out to
    }

    /// Land the block cursor on the sensible cell for a view level (used on zoom-out and mouse→keyboard
    /// hand-off): year → the focused month; month → the focused day.
    private func syncBlockToView(_ lvl: Int) {
        switch lvl {
        case 0: blockMonth = focus
        case 1: blockMonth = focus; blockDay = min(daysInMonth(year, focus), max(1, daily.dom))
        case 2: blockDay = min(daysInMonth(year, focus), max(1, daily.dom))   // week: keep the day + hour
        default: break
        }
    }

    /// Step the block cursor's hour (week/day), clamped to the 0…23 grid, gliding the timeline to follow.
    private func stepHour(_ dy: Int) {
        let h = max(0, min(23, Int(blockHour.rounded()) + dy))
        if CGFloat(h) != blockHour { blockHour = CGFloat(h); ensureHourVisible() }
    }

    /// Week view: glide the 7-day focus window (`week`) so day `d` stays visible (shifts a day at the edge).
    private func ensureDayVisibleWeek(_ d: Int) {
        let target = weekTween?.to ?? week
        let startDOM = 1 - CGFloat(firstDOW(year, focus)) + target * 7   // the window's Sunday, in DOM
        var newWeek = target
        if CGFloat(d) < startDOM { newWeek = target - (startDOM - CGFloat(d)) / 7 }
        else if CGFloat(d) > startDOM + 6 { newWeek = target + (CGFloat(d) - (startDOM + 6)) / 7 }
        newWeek = clamp(newWeek, 0, CGFloat(max(0, weeksInMonth(year, focus) - 1)))
        if abs(newWeek - week) < 0.001 { return }
        // Pace-locked: ~0.25s per day-step (a day = 1/7 of a week) so the glide covers the SAME distance
        // per second no matter how many presses are queued — a fixed duration over a growing gap would
        // keep accelerating. ease OUT (not in-out) so a rapid re-press kicks forward at full speed instead
        // of restarting in the slow ease-IN ramp. `week` is already live per-frame, so retargets seamlessly.
        let dur = max(0.12, (0.25 * 7) * Double(abs(newWeek - week)))
        weekTween = Tween(from: week, to: newWeek, start: Date(), duration: dur, ease: easeOut)
    }

    /// Day view: glide to the prev/next day (same hour). Month boundary is deferred (clamped for now).
    private func swipeDay(_ dx: Int) {
        let dim = daysInMonth(year, focus)
        let base = dayTween.map { Int($0.to.rounded()) } ?? daily.dom   // chain rapid presses off the target
        let nd = base + dx
        guard nd >= 1, nd <= dim else { return }
        blockDay = nd
        // Retarget from the LIVE fractional position mid-glide, NOT the last committed integer day: a
        // rapid second press otherwise snaps the viewport back to `daily.dom` before gliding on (a visible
        // jump). One animator continuously chases whatever target the latest press set.
        let current = dayTween?.value(at: Date()) ?? CGFloat(daily.dom)
        // Duration scales with the remaining distance so the PACE stays constant however many presses are
        // queued (a fixed duration over a growing gap would keep speeding up). ease OUT, not in-out: it
        // starts at full speed, so a rapid re-press doesn't restart in the slow ease-IN ramp (which, over
        // the now-longer duration, would crawl) — it kicks forward immediately and eases into the target.
        let dur = max(0.14, 0.3 * Double(abs(CGFloat(nd) - current)))
        dayTween = Tween(from: current, to: CGFloat(nd), start: Date(), duration: dur, ease: easeOut)
    }

    /// Glide the timeline scroll so the SELECTED event is fully on screen (week/day view). A timed event
    /// uses its hour span; a deadline a small window around its moment; a band needs no timeline scroll.
    private func ensureSelectedEventVisible() {
        guard level(z) >= 2, let sel = selectedId else { return }
        let top: CGFloat, bot: CGFloat
        if let e = displayEvents(for: year).first(where: { $0.id == sel }) { top = e.startHour; bot = e.endHour }
        else if let d = displayDeadlines(for: year).first(where: { $0.id == sel }) { top = d.hour - 0.25; bot = d.hour + 0.25 }
        else { return }
        scrollTimelineTo(topHour: top, botHour: bot)
    }

    /// Glide `tlScroll` so the hour range [topHour, botHour] fits in the timeline, preferring to show the
    /// TOP when the range is taller than the viewport. Animated (tlScrollTween) — never teleports.
    private func scrollTimelineTo(topHour: CGFloat, botHour: CGFloat) {
        let tl = timelineInfo(snapshot())
        guard tl.hourH > 0 else { return }
        let cellTop = topHour * tl.hourH, cellBot = botHour * tl.hourH
        let viewH = tl.tlBottom - tl.tlTop
        var s = tlScrollTween?.to ?? tlScroll
        if s < cellBot - viewH { s = cellBot - viewH }   // bring the bottom into view…
        if s > cellTop { s = cellTop }                   // …but prefer the top if the range is tall
        s = clamp(s, 0, tl.maxScroll)
        if abs(s - tlScroll) < 0.5 { return }
        tlScrollTween = Tween(from: tlScroll, to: s, start: Date(), duration: 0.25, ease: easeInOut)
    }

    /// Glide the timeline scroll so the block cursor's hour cell is fully on screen (week/day view).
    private func ensureHourVisible() {
        let g = snapshot()
        let tl = timelineInfo(g)
        guard tl.hourH > 0 else { return }
        let cellTop = blockHour * tl.hourH, cellBot = cellTop + tl.hourH   // content-space (pre-scroll)
        let viewH = tl.tlBottom - tl.tlTop
        var s = tlScrollTween?.to ?? tlScroll                  // head toward the in-flight target if any
        if s > cellTop { s = cellTop }                         // cell would clip above → bring to top
        if s < cellBot - viewH { s = cellBot - viewH }         // cell below the fold → scroll up
        s = clamp(s, 0, tl.maxScroll)
        if abs(s - tlScroll) < 0.5 { return }
        tlScrollTween = Tween(from: tlScroll, to: s, start: Date(), duration: 0.25, ease: easeInOut)
    }

    // ── Keyboard navigation cursor: input mode, movement, geometry, zoom ───────────
    /// True while any view tween/flip is in flight — the cursor ring should follow the geometry each
    /// frame WITHOUT its own spring (avoids lag during zoom/scroll); it springs only for discrete moves.
    public var isAnimating: Bool {
        tween != nil || scrollTween != nil || tlScrollTween != nil || weekTween != nil || dayTween != nil ||
        flipAnim != nil || monthAnim != nil || weekFlip != nil || dayFlip != nil
    }

    /// A mouse move/click hides the keyboard cursor visual (state persists).
    public func enterMouseMode() { if keyboardActive { keyboardActive = false; wake() } }
    /// A dispatched nav/action key shows the keyboard cursor.
    public func enterKeyboardMode() { if !keyboardActive { keyboardActive = true; wake() } }

    /// Move the block cursor by an arrow. `dy`: up = -1, down = +1; `dx`: left = -1, right = +1.
    /// (Year view only for now — up/down step a month, left/right are no-ops.)
    public func blockArrow(dx: Int, dy: Int) {
        enterKeyboardMode()
        switch level(z) {
        case 0:   // year: up/down = month
            let m = max(0, min(11, blockMonth + dy))
            if m != blockMonth { blockMonth = m; ensureMonthVisible(m, animated: true) }
        case 1:   // month: left/right = day (wraps across weeks); up/down = no-op
            let d = max(1, min(daysInMonth(year, focus), blockDay + dx))
            if d != blockDay { blockDay = d }
        case 2:   // week: up/down = hour; left/right = day (+ glide the focus window to follow)
            if dy != 0 { stepHour(dy) }
            if dx != 0 {
                let d = max(1, min(daysInMonth(year, focus), blockDay + dx))
                if d != blockDay { blockDay = d; ensureDayVisibleWeek(d) }
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
        let d = level(z) == 2 ? blockDay : daily.dom
        let h = blockHour
        beginTxn()
        let id = "new-\(UUID().uuidString)"
        seedEvents.append(TimedEvent(id: id, year: year, month: focus, day: d,
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
                let flat = max(0, min(11 * 4 + 3, blockMonth * 4 + bandCurTrack + dy))
                blockMonth = flat / 4; bandCurTrack = flat % 4
                blockDay = min(daysInMonth(year, blockMonth), max(1, blockDay))
                ensureMonthVisible(blockMonth, animated: true)
            } else {
                bandCurTrack = max(0, min(3, bandCurTrack + dy))
            }
        }
        if dx != 0 {
            let m = level(z) == 0 ? blockMonth : focus
            switch level(z) {
            case 0, 1: blockDay = max(1, min(daysInMonth(year, m), blockDay + dx))
            case 2:    let d = max(1, min(daysInMonth(year, focus), blockDay + dx)); if d != blockDay { blockDay = d; ensureDayVisibleWeek(d) }
            default:   swipeDay(dx)   // day view
            }
        }
    }

    /// The band cursor's cell rect (geometry space): one day column × one lane.
    public func bandCursorRect() -> CGRect? {
        guard keyboardActive, !Self.isDemoMode, bandCursorActive, selectedId == nil, !drawerOpen else { return nil }
        let g = snapshot()
        let m = level(z) == 0 ? blockMonth : focus
        let f = frameFor(m, g)
        let day = min(daysInMonth(year, m), max(1, blockDay))
        return CGRect(x: f.x0 + CGFloat(day - 1) * f.dayW, y: f.bandY + CGFloat(bandCurTrack) * f.trackH,
                      width: f.dayW, height: f.trackH)
    }

    /// ⌘N in band-cursor mode — create a 1-day band at the cursor cell, select it, open its title editor.
    public func createBandAtCursor() {
        enterKeyboardMode()
        guard bandCursorActive, selectedId == nil, !drawerOpen else { return }
        let m = level(z) == 0 ? blockMonth : focus
        let day = min(daysInMonth(year, m), max(1, blockDay))
        beginTxn()
        let id = "new-\(UUID().uuidString)"
        seedBands.append(BandEvent(id: id, year: year, month: m, track: bandCurTrack, startDay: day, endDay: day, title: "New event", color: "blue"))
        selectedId = id
        bandCursorActive = false
        commitTxn()
        editBand(id)
    }

    // ── Track-name cursor (month view's extra Tab stops) ───────────────────────────
    /// The focused track-name gutter cell (geometry space), or nil when not on a track name.
    public func trackNameCursorRect() -> CGRect? {
        guard keyboardActive, !Self.isDemoMode, let t = trackNameCursor, selectedId == nil, !drawerOpen, level(z) == 1 else { return nil }
        let g = snapshot()
        let f = frameFor(focus, g)
        let y = f.bandY + CGFloat(t) * f.trackH
        return CGRect(x: Layout.mnameW, y: y, width: Layout.labelW - Layout.mnameW - Layout.rightPad, height: f.trackH)
    }

    /// Enter on a focused track name → open its inline editor (Enter again commits — see TrackNameEditor).
    public func editFocusedTrackName() {
        guard let t = trackNameCursor, let rect = trackNameCursorRect() else { return }
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
        trackNameCursor = nil
        switch level(z) {
        case 0: focus = a.month; blockMonth = a.month; blockDay = a.day; ensureMonthVisible(a.month, animated: false); tweenZ(to: 1)
        case 1: week = CGFloat(weekOfDate(year, focus, a.day)); daily.dom = a.day; blockDay = a.day; blockHour = a.hour; tweenZ(to: 2)
        case 2: daily.dom = a.day; blockHour = a.hour; tweenZ(to: 3)
        default: break   // day is the deepest
        }
    }

    /// ⌘− — zoom OUT one level, keeping the current focus. With an event selected, the higher-level view
    /// lands on the event so it stays visible; otherwise the block cursor carries over (syncBlockToView).
    public func cmdZoomOut() {
        enterKeyboardMode()
        trackNameCursor = nil
        clearDashStop()
        let dest = max(0, level(z) - 1)
        if let a = selectedAnchor() {
            focus = a.month
            week = CGFloat(weekOfDate(year, a.month, a.day)); daily.dom = a.day
            blockMonth = a.month; blockDay = a.day; blockHour = a.hour
        }
        tweenZ(to: CGFloat(dest))
        if selectedId == nil { syncBlockToView(dest) }
    }

    /// Space / ⌘= — zoom IN one level, carrying the block cursor with the placement rules.
    public func blockZoomIn() {
        enterKeyboardMode()
        trackNameCursor = nil   // track names are month-only; zooming leaves them → block cursor
        switch level(z) {
        case 0:   // year → month: focus the cursor's month; land the day on today (if that month) else the 1st.
            focus = blockMonth
            let t = Calendar.current.dateComponents([.year, .month, .day], from: now)
            let isCurMonth = (t.year == year) && ((t.month ?? 0) - 1 == blockMonth)
            blockDay = isCurMonth ? (t.day ?? 1) : 1
            ensureMonthVisible(blockMonth, animated: false)   // instant; the zoom repositions immediately after
            tweenZ(to: 1)
        case 1:   // month → week: focus the cursor's week; land the hour on now (if the week has today) else noon.
            week = CGFloat(weekOfDate(year, focus, blockDay))
            daily.dom = blockDay
            let t = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: now)
            let weekHasToday = (t.year == year) && ((t.month ?? 0) - 1 == focus)
                && weekOfDate(year, focus, t.day ?? 1) == weekOfDate(year, focus, blockDay)
            blockHour = weekHasToday ? CGFloat(t.hour ?? 12) : 12   // land on the hour cell containing now
            tweenZ(to: 2)
        case 2:   // week → day: same hour, on the cursor's day
            daily.dom = min(daysInMonth(year, focus), max(1, blockDay))
            tweenZ(to: 3)
        default:
            break   // day view is the deepest — Space is a no-op
        }
    }

    /// The block cursor's cell rect in geometry space (pre-padLeft), or nil when it shouldn't show
    /// (mouse mode, an event/drawer is active, or a view without a cursor yet).
    public func blockCursorRect() -> CGRect? {
        guard keyboardActive, !Self.isDemoMode, !bandCursorActive, trackNameCursor == nil, selectedId == nil, dashStop == nil, !drawerOpen else { return nil }
        let g = snapshot()
        switch level(z) {
        case 0:
            // Cover the ENTIRE month row — from the left edge (the month-name gutter) to the right.
            let f = yearFrame(blockMonth, g.vp, scrollY)
            return CGRect(x: 0, y: f.bandY, width: g.vp.w, height: 4 * f.trackH)
        case 1:
            // A day COLUMN: the band cell on top + the day's timeline below it.
            let f = frameFor(focus, g)
            let tl = timelineInfo(g)
            let d = max(1, min(daysInMonth(year, focus), blockDay))
            let x = f.x0 + CGFloat(d - 1) * f.dayW
            return CGRect(x: x, y: f.bandY, width: f.dayW, height: max(4 * f.trackH, tl.tlBottom - f.bandY))
        case 2, 3:
            // An HOUR cell: the day column × one hour row. (Day view: the shown day is daily.dom.)
            let tl = timelineInfo(g)
            guard tl.hourH > 0 else { return nil }
            let d = level(z) == 2 ? blockDay : daily.dom
            let x = tl.x0 + CGFloat(d - 1) * tl.colW
            let y = tl.tlTop + blockHour * tl.hourH - tl.scroll
            return CGRect(x: x, y: y, width: tl.colW, height: tl.hourH)
        default:
            return nil
        }
    }

    /// The dashed-ring rect for the SELECTED event box (geometry space, pre-padLeft) — the event-cursor
    /// visual, shown in keyboard mode. Looks up the exact box in the DISPLAY arrays (so a promoted band /
    /// occurrence ghost rings its own box, not the whole series).
    public func selectionRingRect() -> CGRect? {
        guard keyboardActive, let sel = selectedId, !drawerOpen else { return nil }
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
    /// scroll (a `scrollTween`, like jumpToDay) rather than snapping — used when the cursor walks off
    /// the visible region.
    private func ensureMonthVisible(_ m: Int, animated: Bool) {
        let cTop = yearFrame(m, viewport, 0).bandY - Layout.yearTop   // scroll-independent content top
        let h = 4 * Layout.trackH
        let viewTop = Layout.yearTop, viewBottom = viewport.h - Layout.bottomPad
        // On-screen top = viewTop - scrollY + cTop. Keep [top, top+h] within [viewTop, viewBottom].
        let maxScrollForVisible = cTop                                   // any more → top clips above
        let minScrollForVisible = cTop + h - (viewBottom - viewTop)      // any less → bottom clips below
        // Base the clamp on where we're HEADED (an in-flight tween's target) so rapid presses chain.
        var s = scrollTween?.to ?? scrollY
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
            scrollTween = Tween(from: scrollY, to: s, start: Date(), duration: dur, ease: easeOut)
        } else {
            scrollTween = nil; scrollY = s; onSetYearScroll?(scrollY)
        }
    }

    public func onHover(at p: CGPoint) {
        if drawerOpen { onHoverExit(); return }   // drawer open → no calendar hover highlights
        pointerPos = p                            // for the deadline "+" hover glow (pixel-precise)
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
        guard let b = seedBands.first(where: { $0.id == id }), let r = bandEventRect(b, g, anim: g.monthAnim) else { return false }
        return CGRect(x: r.x, y: r.y, width: r.w, height: r.h).contains(p)
    }
    private func timedContains(_ id: String, _ p: CGPoint, _ g: SceneInput) -> Bool {
        guard z >= 1.5, let e = seedEvents.first(where: { $0.id == id }) else { return false }
        let tl = timelineInfo(g)
        guard tl.reveal > 0.05, tl.hourH > 0 else { return false }
        guard p.y >= tl.tlTop, p.y <= tl.tlBottom else { return false }   // clip to the timeline (see eventAt)
        let sameDay = eventsOn(year, e.month, e.day)
        guard let r = eventRect(e, year, focus, tl, g.vp, layoutDay(sameDay)[e.id]) else { return false }
        return CGRect(x: r.minX, y: tl.tlTop - tl.scroll + r.minY, width: r.width, height: r.height).contains(p)
    }

    public func onHoverExit() { if hover != .none || hoveredEventId != nil { wake() }; hover = .none; hoveredEventId = nil; pointerPos = nil }

    /// Clear the current event selection — the same effect as a plain click on empty calendar space.
    /// Used by the daily-dashboard WebView so clicking its empty content deselects too.
    public func deselect() { selectedId = nil; bandCursorActive = false }   // Esc from an event → block cursor (home)

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
    }

    /// Title-substring search over every selectable year's fully-merged event set (seed + recurrence
    /// occurrences + Apple imports; hidden imports are already excluded from the display caches). Results
    /// are de-duplicated to one row per underlying event — the occurrence nearest today — then ranked
    /// prefix-matches-first, then by nearness to today. Capped at `limit`.
    public func searchEvents(_ query: String, limit: Int = 8) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        func dayDist(_ y: Int, _ m: Int, _ d: Int) -> Int {
            guard let date = cal.date(from: DateComponents(year: y, month: m + 1, day: d)) else { return .max }
            return abs(cal.dateComponents([.day], from: today, to: date).day ?? .max)
        }
        struct Cand { let hit: SearchHit; let prefix: Bool; let dist: Int }
        var byBase: [String: Cand] = [:]   // sourceId → best occurrence (collapses recurrences)
        func consider(_ id: String, _ title: String, _ color: String, _ y: Int, _ m: Int, _ d: Int, _ hour: CGFloat?, _ kind: SearchHit.Kind) {
            let lt = title.lowercased()
            guard let r = lt.range(of: q) else { return }
            let isPrefix = r.lowerBound == lt.startIndex
            let dist = dayDist(y, m, d)
            let cand = Cand(hit: SearchHit(id: id, title: title, color: color, year: y, month: m, day: d, hour: hour, kind: kind),
                            prefix: isPrefix, dist: dist)
            let base = sourceId(of: id)
            if let ex = byBase[base] {
                if dist < ex.dist || (dist == ex.dist && isPrefix && !ex.prefix) { byBase[base] = cand }
            } else { byBase[base] = cand }
        }
        for y in yearOptions {
            for e in displayEvents(for: y)    { consider(e.id, e.title, e.color, y, e.month, e.day, e.startHour, .timed) }
            for b in displayBands(for: y)     { consider(b.id, b.title, b.color, y, b.month, b.startDay, nil, .band) }
            for d in displayDeadlines(for: y) { consider(d.id, d.title, d.color, y, d.month, d.day, d.hour, .deadline) }
        }
        return byBase.values
            .sorted { a, b in
                if a.prefix != b.prefix { return a.prefix }          // prefix matches first
                if a.dist != b.dist { return a.dist < b.dist }        // then nearest to today
                return a.hit.title.count < b.hit.title.count          // then the shorter (tighter) title
            }
            .prefix(limit)
            .map(\.hit)
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
