// The AppKit input layer: CatcherView (the transparent NSView that owns every scroll/pinch/
// click/hover/key event and forwards it to the engine), its InputCatcher representable, and
// the invisible NSScrollView drivers that give scrolling native elastic feel.
// Split from CalendarView.swift (file diet).

import AppKit
import CalendarEngine
import CalendarGeometry
import SwiftUI

/// Transparent overlay that captures trackpad/mouse events and forwards them to the
/// engine. isFlipped so its coordinates match the SwiftUI/Canvas top-left origin.
struct InputCatcher: NSViewRepresentable {
    let engine: CalendarEngine
    let monthBridge: MonthPagerBridge
    let weekBridge: WeekPagerBridge
    let dayBridge: DayPagerBridge
    var forwarder: GestureForwarder?
    var onOpenEvent: (String) -> Void = { _ in }
    var onEventMenu: (String, CGRect) -> Void = { _, _ in } // right-click event → context callout
    var onSpaceMenu: (CalendarEngine.EmptySpot, CGRect) -> Void = { _, _ in
    } // right-click empty space → create/paste callout
    var onEditTrack: (TrackEdit) -> Void = { _ in }
    var onKey: (KeyToken) -> Bool = { _ in false } // dispatch a key; returns whether it was consumed
    var onKeyGuide: (Bool) -> Void = { _ in } // Cmd+K held → show/hide the shortcut guide
    var isEditingText: () -> Bool = { false } // a drawer inline editor owns the keyboard (pass keys to it)
    var onSearch: () -> Void = {} // Cmd+F → open the toolbar search field
    var isModalDelete: () -> Bool = { false } // the delete-confirm dialog is up
    var onDeleteDialogKey: (DeleteDialogKey) -> Void = { _ in }
    var onRequestDelete: () -> Void = {} // Delete on a selected event → raise the dialog
    var isTutorialUp: () -> Bool = { false } // the tutorial carousel is up
    var onTutorialKey: (DeleteDialogKey) -> Void = { _ in }
    var isBatchRenaming: () -> Bool = { false } // the batch-rename panel is up (modal-with-typing)
    var onBatchRenameCancel: () -> Void = {} // Esc anywhere → revert the live renames + close
    var onBatchRenameCommit: () -> Void = {} // Enter (field unfocused) → keep the renames + close

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.engine = engine
        v.monthBridge = monthBridge
        v.weekBridge = weekBridge
        v.dayBridge = dayBridge
        v.onOpenEvent = onOpenEvent
        v.onEventMenu = onEventMenu
        v.onSpaceMenu = onSpaceMenu
        v.onEditTrack = onEditTrack
        v.onKey = onKey
        v.onKeyGuide = onKeyGuide
        v.isEditingText = isEditingText
        v.onSearch = onSearch
        v.isModalDelete = isModalDelete
        v.onDeleteDialogKey = onDeleteDialogKey
        v.onRequestDelete = onRequestDelete
        v.isTutorialUp = isTutorialUp
        v.onTutorialKey = onTutorialKey
        v.isBatchRenaming = isBatchRenaming
        v.onBatchRenameCancel = onBatchRenameCancel
        v.onBatchRenameCommit = onBatchRenameCommit
        forwarder?.catcher = v // let the dashboard web view forward horizontal scroll + pinch here
        v.installYearScrollDriver()
        v.installTimelineScrollDriver()
        v.installKeyMonitor()
        return v
    }

    func updateNSView(_ v: CatcherView, context: Context) {
        v.engine = engine; v.monthBridge = monthBridge; v.weekBridge = weekBridge; v.dayBridge = dayBridge
        v.onOpenEvent = onOpenEvent; v.onEventMenu = onEventMenu; v.onSpaceMenu = onSpaceMenu; v
            .onEditTrack = onEditTrack
        v.onKey = onKey; v.onKeyGuide = onKeyGuide; v.isEditingText = isEditingText; v.onSearch = onSearch
        v.isModalDelete = isModalDelete; v.onDeleteDialogKey = onDeleteDialogKey; v.onRequestDelete = onRequestDelete
        v.isTutorialUp = isTutorialUp; v.onTutorialKey = onTutorialKey
        v.isBatchRenaming = isBatchRenaming; v.onBatchRenameCancel = onBatchRenameCancel
        v.onBatchRenameCommit = onBatchRenameCommit
        forwarder?.catcher = v
    }
}

/// Flipped so its scroll origin (0 = top, increasing downward) matches our scrollY.
final class FlippedDocView: NSView { override var isFlipped: Bool {
    true
} }

/// A scroll physics driver. Overriding scrollWheel (a) disables concurrent "responsive
/// scrolling" — which otherwise grabs the gesture and swallows the .ended phase — so we
/// reliably see begin/end, and (b) is the same pattern the macOS pull-to-refresh libraries
/// use. super does the native elastic drag; begin/end are surfaced as closures so the same
/// class drives both the year scroll and the month↕month paging. `suppressSuperOnEnd` lets
/// the month driver run its own release-snap instead of AppKit's deceleration/bounce.
final class DriverScrollView: NSScrollView {
    var onBegan: (() -> Void)?
    var onEnded: (() -> Void)?
    var suppressSuperOnEnd = false
    override func scrollWheel(with e: NSEvent) {
        let ended = e.phase.contains(.ended) || e.phase.contains(.cancelled)
        if e.phase.contains(.began) {
            onBegan?()
        }
        if ended && suppressSuperOnEnd {
            onEnded?(); return
        }
        super.scrollWheel(with: e)
        if ended {
            onEnded?()
        }
    }
}

/// The four keys the delete-confirm dialog reacts to (routed from the key monitor while the dialog is up).
enum DeleteDialogKey { case left, right, confirm, cancel }

final class CatcherView: NSView, NSMenuItemValidation {
    weak var engine: CalendarEngine?
    var onOpenEvent: ((String) -> Void)?
    var onEventMenu: ((String, CGRect) -> Void)? // right-click on an event → context callout (id, view-space box rect)
    var onSpaceMenu: ((CalendarEngine.EmptySpot, CGRect) -> Void)? // right-click on empty space → create/paste callout
    var onEditTrack: ((TrackEdit) -> Void)?
    var onKey: ((KeyToken) -> Bool)?
    var onKeyGuide: ((Bool) -> Void)?
    var isEditingText: (() -> Bool)? // drawer inline editor owns the keyboard → pass keys through
    var onSearch: (() -> Void)? // Cmd+F → open the toolbar search field
    var isModalDelete: (() -> Bool)? // the delete-confirm dialog is up → it owns ALL input
    var onDeleteDialogKey: ((DeleteDialogKey) -> Void)? // route ←/→/Enter/Esc to the dialog while it's up
    var onRequestDelete: (() -> Void)? // Delete on a selected event → raise the confirm dialog (no immediate delete)
    var isTutorialUp: (() -> Bool)? // the tutorial carousel is up → also a blocking modal
    var onTutorialKey: ((DeleteDialogKey) -> Void)? // route ←/→/Enter/Esc to the carousel
    var isBatchRenaming: (() -> Bool)? // the batch-rename panel is up (modal, but typing flows to its field)
    var onBatchRenameCancel: (() -> Void)? // Esc anywhere while renaming → revert + close
    var onBatchRenameCommit: (() -> Void)? // Enter with the field unfocused → keep + close
    /// A blocking modal is up → the canvas ignores every mouse/scroll/pinch event (the modal's backdrop
    /// captures them) and the key monitor swallows every non-modal key.
    private var modalActive: Bool {
        isModalDelete?() == true || isTutorialUp?() == true || isBatchRenaming?() == true
    }

    private var keyGuideShown = false // Cmd+K guide currently displayed (so we hide once on release)
    private var trackingAreaRef: NSTrackingArea?
    // Invisible NSScrollView used purely as a physics driver: AppKit computes the elastic
    // bounce + momentum, and we mirror its offset into the engine (year-view scroll).
    private let yearScroll = DriverScrollView()
    private let docView = FlippedDocView()
    private var syncing = false // true while WE move/resize the driver — ignore its notifications
    // A second physics driver for the hour-timeline vertical scroll (week/day view) — native
    // elastic bounce + momentum, its scrollable range == the timeline's maxScroll.
    private let tlDriver = DriverScrollView()
    private let tlDoc = FlippedDocView()
    private var syncingTL = false
    // Month↕month paging is an invisible SwiftUI ScrollView (native .paging); we forward its
    // scroll events into the ScrollView's backing NSScrollView, handed to us via the bridge.
    weak var monthBridge: MonthPagerBridge?
    weak var weekBridge: WeekPagerBridge?
    weak var dayBridge: DayPagerBridge?
    // A boundary flip is triggered on fingers-up, but a hard fling keeps sending momentum
    // events that outlive the flip — which would then scroll the freshly-flipped month on to
    // the next/next-next. Swallow that trailing momentum until the momentum phase ends.
    private var swallowMonthMomentum = false
    private var swallowWeekMomentum = false // same, for the week-view month-edge flip
    private var swallowDayMomentum = false // same, for the day-view month-edge flip
    // A month boundary flip withholds `.ended` from the pager, so its NSScrollView is left with a stale
    // (pre-flip) offset that a later scrollTo can't override while the gesture stays "open". On the FIRST
    // gesture after a flip, snap the SV back to the new focus before forwarding — else it lunges back
    // toward the old month (Jan → burst toward November).
    private var monthFlipPendingResync = false
    // Week view has TWO scroll axes (horizontal = week window, vertical = hour timeline). Lock to
    // the dominant axis at gesture start so a diagonal drag doesn't do both at once.
    private enum ScrollAxis { case undecided, horizontal, vertical }
    private var weekAxis: ScrollAxis = .undecided
    private var dayAxis: ScrollAxis = .undecided
    // A day-pager gesture is "live" from the first fingers-down delta until `.ended`. Tracked
    // explicitly because a webview-forwarded scroll may skip `.began` (the web view holds it while its
    // axis is undecided), so we can't rely on `.began` alone to mark the gesture live.
    private var dayGestureActive = false
    private var tlPrepared = false // timeline driver sized+synced for the current gesture
    // While a scroll is in flight we suppress mouse-hover recomputation: a moving mouse during a
    // scroll otherwise fires onHover (hit-test + re-render) on every frame on top of the scroll's
    // own work. A short idle timer (reset by each scroll event) spans fingers-down + momentum.
    private var scrolling = false
    private var scrollIdle: DispatchWorkItem?
    private func noteScroll() {
        // Clear the stale highlight, but NOT the pointer/scale-bar proximity — the cursor hasn't
        // moved; a full onHoverExit here made the scale bar vanish the moment you scrolled.
        if !scrolling {
            scrolling = true; engine?.clearHoverHighlight()
        }
        scrollIdle?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.scrolling = false }
        scrollIdle = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    override var isFlipped: Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    /// Return false so a click on an INACTIVE window only activates the app — it isn't also
    /// delivered as a mouseDown (which would zoom into a month / select an event). Once the
    /// window is key, subsequent clicks act normally.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Always be the event target; the scroll-view driver is a physics-only subview
        // that we feed manually (never a hit target for mouse/clicks).
        guard bounds.contains(convert(point, from: superview)) else { return nil }
        // …except over the window toolbar (which floats above the content): fall through so the
        // click drags the window / hits a toolbar button, instead of us starting a band-create.
        if let win = window {
            let wp = superview?.convert(point, to: nil) ?? point // window coords (y grows upward)
            if wp.y > win.contentLayoutRect.maxY {
                return nil
            }
        }
        return self
    }

    /// ── Year-view scroll driver (native elastic bounce via NSScrollView) ─────────────
    func installYearScrollDriver() {
        yearScroll.drawsBackground = false
        yearScroll.hasVerticalScroller = false
        yearScroll.hasHorizontalScroller = false
        yearScroll.verticalScrollElasticity = .allowed
        yearScroll.horizontalScrollElasticity = .none
        yearScroll.autohidesScrollers = true
        // Critical: without this, a toolbar window gives the scroll view a top content
        // inset (toolbar height) — which pushes the content down AND makes the scroll
        // range asymmetric (top hair-trigger, bottom unreachable). We manage insets.
        yearScroll.automaticallyAdjustsContentInsets = false
        yearScroll.contentInsets = NSEdgeInsetsZero
        docView.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        yearScroll.documentView = docView
        yearScroll.contentView.postsBoundsChangedNotifications = true
        addSubview(yearScroll, positioned: .below, relativeTo: nil) // behind; never hit-tested

        yearScroll.onBegan = { [weak engine] in engine?.beginYearScrollGesture() }
        yearScroll.onEnded = { [weak engine] in engine?.endYearScrollGesture() }
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: yearScroll.contentView)
        engine?.onSetYearScroll = { [weak self] y in self?.setDriverOffset(y) }
    }

    private func setDriverOffset(_ y: CGFloat) {
        let prev = syncing; syncing = true
        let cv = yearScroll.contentView
        cv.scroll(to: NSPoint(x: 0, y: y))
        yearScroll.reflectScrolledClipView(cv)
        syncing = prev
    }

    @objc private func clipBoundsChanged() {
        guard let engine, engine.isYearLevel, !engine.isFlipping, !syncing else { return }
        engine.setYearScroll(yearScroll.contentView.bounds.origin.y)
    }

    /// ── Hour-timeline scroll driver (native elastic bounce, week/day view) ─────────────
    func installTimelineScrollDriver() {
        tlDriver.drawsBackground = false
        tlDriver.hasVerticalScroller = false
        tlDriver.hasHorizontalScroller = false
        tlDriver.verticalScrollElasticity = .allowed
        tlDriver.horizontalScrollElasticity = .none
        tlDriver.autohidesScrollers = true
        tlDriver.automaticallyAdjustsContentInsets = false
        tlDriver.contentInsets = NSEdgeInsetsZero
        tlDoc.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        tlDriver.documentView = tlDoc
        tlDriver.contentView.postsBoundsChangedNotifications = true
        addSubview(tlDriver, positioned: .below, relativeTo: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(tlClipChanged),
                                               name: NSView.boundsDidChangeNotification, object: tlDriver.contentView)
        engine?.onSetTlScroll = { [weak self] y in self?.setTlDriverOffset(y) }
        engine?.onSetWeekScroll = { [weak self] x in self?.weekBridge?.scrollTo(x) }
        engine?.onSetMonthPage = { [weak self] m in self?.monthBridge?.scrollToFocus(m) }
    }

    /// Size the driver's scrollable range to the current timeline maxScroll and sync it to the
    /// engine's tlScroll — do this at each vertical gesture's start (maxScroll depends on zoom).
    private func prepareTimelineDriver() {
        guard let engine else { return }
        syncingTL = true
        tlDriver.frame = bounds
        tlDoc.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height + engine.timelineMaxScroll)
        syncingTL = false
        setTlDriverOffset(engine.tlScroll)
    }

    private func setTlDriverOffset(_ y: CGFloat) {
        let prev = syncingTL; syncingTL = true
        let cv = tlDriver.contentView
        cv.scroll(to: NSPoint(x: 0, y: y))
        tlDriver.reflectScrolledClipView(cv)
        syncingTL = prev
    }

    @objc private func tlClipChanged() {
        guard let engine, !syncingTL, engine.isWeekLevel || engine.isDayLevel else { return }
        engine.setTlScroll(tlDriver.contentView.bounds.origin.y)
    }

    deinit {
        NotificationCenter.default
            .removeObserver(self); if let m = keyMonitor {
            NSEvent.removeMonitor(m)
        }; repeatTimer?.invalidate()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Create ONCE. `.inVisibleRect` keeps the area synced to the view automatically, so there's no need to
        // remove+re-add on every layout pass — doing that during the continuous TimelineView redraw churned
        // spurious exit/enter events, and mouseExited resets the cursor to the arrow → the hover cursor
        // flickered (arrow ↔ I-beam) over a selected event. `.cursorUpdate` makes the cursor event-driven.
        if let t = trackingAreaRef, trackingAreas.contains(t) {
            return
        } // already attached → don't churn it
        let t = NSTrackingArea(rect: .zero,
                               options: [
                                   .activeInKeyWindow,
                                   .mouseMoved,
                                   .mouseEnteredAndExited,
                                   .cursorUpdate,
                                   .inVisibleRect,
                               ],
                               owner: self)
        addTrackingArea(t)
        trackingAreaRef = t
    }

    override func layout() {
        super.layout()
        syncing = true // suppress the mirror while resizing the clip/document view
        engine?.setViewport(bounds.size) // idempotent: a no-op size is ignored inside (no wake / re-render)
        // Size the driver so its scrollable range == the engine's yearMaxScroll:
        // docHeight − clipHeight = maxScroll  ⇒  docHeight = clipHeight + maxScroll.
        yearScroll.frame = bounds
        let vp = Viewport(w: bounds.width, h: bounds.height)
        let maxY = yearMaxScroll(vp)
        docView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height + maxY)
        syncing = false
        setDriverOffset(engine?.scrollY ?? 0) // apply AFTER the doc is sized (engine.scrollY = centered)
    }

    private func point(_ e: NSEvent) -> CGPoint {
        // Undo the render's padLeft translation (and the drawer left-shift) so hits land in
        // geometry space.
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: p.x - Layout.padLeft + (engine?.drawerShift ?? 0) + (engine?.gutterShift ?? 0), y: p.y)
    }

    override func scrollWheel(with e: NSEvent) {
        if modalActive {
            return
        } // blocking modal up → no canvas scrolling
        // Year view: hand the event to the NSScrollView driver so AppKit does the elastic
        // physics; its offset is mirrored back via clipBoundsChanged. Deeper levels use
        // the manual timeline/week/day handling.
        guard let engine else { return }
        // Drop leftover momentum from a fling that just flipped the month boundary (a new
        // finger-down gesture cancels the swallow and scrolls normally again).
        if swallowMonthMomentum {
            if e.phase.contains(.began) {
                swallowMonthMomentum = false
            } // a fresh gesture resumes scrolling
            else {
                if e.momentumPhase.contains(.ended) {
                    swallowMonthMomentum = false
                }
                return // eat this trailing momentum event
            }
        }
        if swallowWeekMomentum {
            if e.phase.contains(.began) {
                swallowWeekMomentum = false
            } else {
                if e.momentumPhase.contains(.ended) {
                    swallowWeekMomentum = false
                }
                return
            }
        }
        if swallowDayMomentum {
            if e.phase.contains(.began) {
                swallowDayMomentum = false
            } else {
                if e.momentumPhase.contains(.ended) {
                    swallowDayMomentum = false
                }
                return
            }
        }
        if engine.isFlipping || engine.isMonthFlipping || engine.isWeekFlipping || engine.isDayFlipping || engine
            .trackEditing || engine.bandEditing || engine.timedEditing {
            return
        } // don't fight flip / inline edit
        noteScroll() // suppress hover while this scroll (and its momentum) is live
        if e.phase
            .contains(.began) {
            tlPrepared = false
        } // new gesture → re-prep the timeline driver on first vertical event
        if engine.isYearLevel {
            yearScroll.scrollWheel(with: e) // DriverScrollView does the physics + begin/end
        } else if engine.isMonthLevel, let sv = monthBridge?.scrollView {
            // Recover from a prior boundary flip: the SV kept the old month's offset. Snap it to the new
            // focus on the first touch of the next gesture — BEFORE any event reaches the SV — so the
            // gesture starts from the right month instead of lunging back toward the old one.
            if monthFlipPendingResync, e.phase.contains(.began) || e.phase.contains(.mayBegin) {
                monthFlipPendingResync = false
                monthBridge?.scrollToFocus(engine.focus)
            }
            if e.phase.contains(.began) {
                engine.beginMonthGesture()
            }
            let ended = e.phase.contains(.ended) || e.phase.contains(.cancelled)
            // Always forward — INCLUDING `.ended` on a boundary flip. Withholding it (the old approach)
            // left the SV's gesture stuck OPEN at the overscrolled edge page, so the flip's scrollTo() to
            // the new focus was a no-op and `setMonthProgress` then walked focus from that stale offset —
            // the "gentle scroll bursts through to November" bug. Forwarding `.ended` lets the SV settle
            // (its target is clamped to [0,11], so it can't overshoot the year) and closes the gesture, so
            // the re-sync sticks. `setMonthProgress` is guarded during the flip; the tail is swallowed.
            sv.scrollWheel(with: e) // invisible SwiftUI ScrollView does native .paging
            if ended {
                engine.endMonthGesture()
                if engine
                    .isMonthFlipping {
                    swallowMonthMomentum = true; monthFlipPendingResync =
                        true
                } // eat the fling's tail + reset the SV next gesture
            }
        } else if engine.isWeekLevel, let sv = weekBridge?.scrollView {
            // The finger touching (.mayBegin) must reach the ScrollView so AppKit lets it CAPTURE an
            // in-flight snap animation (grab the decelerating scroll) instead of it running on and
            // then being yanked to a target — that's what made a mid-flight catch feel abrupt.
            if e.phase.contains(.mayBegin) {
                sv.scrollWheel(with: e); return
            }
            let ended = e.phase.contains(.ended) || e.phase.contains(.cancelled)
            // A boundary flip is about to commit → do NOT hand `.ended` to the SV. Otherwise its own
            // ScrollTargetBehavior kicks off a decelerate/snap whose target is computed in the OLD
            // month's content coords; the flip re-anchors focus (new cell count), so when that stale
            // animation later resumes it lands a week or two off. Skipping `.ended` means the snap
            // never starts; the flip drives (and pins) the pager instead, and momentum is swallowed.
            let willFlip = ended && engine.weekFlipArmed
            // Axis-lock: horizontal → the week pager; vertical → the hour-timeline scroll.
            if e.phase.contains(.began) {
                weekAxis = .undecided; engine.beginWeekGesture()
            }
            if weekAxis == .undecided {
                let dx = abs(e.scrollingDeltaX), dy = abs(e.scrollingDeltaY)
                if dx > 1 || dy > 1 {
                    weekAxis = dx > dy ? .horizontal : .vertical
                }
            }
            if weekAxis == .vertical {
                if !tlPrepared {
                    prepareTimelineDriver(); tlPrepared = true
                } // size range + sync, once per gesture
                tlDriver.scrollWheel(with: e) // native elastic bounce → mirrored into tlScroll
                if ended && !willFlip {
                    sv.scrollWheel(with: e)
                } // still let the SV settle the horizontal position
            } else if !willFlip {
                sv.scrollWheel(with: e) // horizontal or still-ambiguous (a pure catch) → the SV
            }
            if ended {
                weekAxis = .undecided
                if engine.endWeekGesture() {
                    swallowWeekMomentum = true
                } // armed pull → flip; eat the fling tail
            }
        } else if engine.isDayLevel, let sv = dayBridge?.scrollView {
            // Day view: horizontal → the invisible day pager (native day-to-day paging); vertical →
            // the hour-timeline scroll. Same axis-lock + catch-capture as the week pager.
            if e.phase.contains(.mayBegin) {
                sv.scrollWheel(with: e); return
            }
            let ended = e.phase.contains(.ended) || e.phase.contains(.cancelled)
            // A boundary flip is about to commit → withhold `.ended` from the SV so its own snap
            // (computed in the old month's coords) can't fight the flip (same as the week pager).
            let willFlip = ended && engine.dayFlipArmed
            // Start the gesture on the FIRST fingers-down delta (phase not ended, no momentum), not on
            // `.began` — a forwarded scroll from the dashboard web view may never deliver `.began` here.
            // This keeps `scroll.liveDayScrolling` true for the whole finger-down phase (incl. pauses), so the
            // settle safety-net can't fire and snap while the user is still scrolling.
            let fingersDown = !ended && e.momentumPhase.isEmpty
            if fingersDown,
               !dayGestureActive {
                dayGestureActive = true; dayAxis = .undecided; engine.beginDayGesture()
            }
            if dayAxis == .undecided {
                let dx = abs(e.scrollingDeltaX), dy = abs(e.scrollingDeltaY)
                if dx > 1 || dy > 1 {
                    dayAxis = dx > dy ? .horizontal : .vertical
                }
            }
            if dayAxis == .vertical {
                if !tlPrepared {
                    prepareTimelineDriver(); tlPrepared = true
                }
                tlDriver.scrollWheel(with: e) // native elastic bounce → mirrored into tlScroll
                if ended && !willFlip {
                    sv.scrollWheel(with: e)
                } // let the SV settle the horizontal position
            } else if !willFlip {
                sv.scrollWheel(with: e) // horizontal or still-ambiguous (a pure catch)
            }
            if ended {
                dayAxis = .undecided
                dayGestureActive = false
                if engine.endDayGesture() {
                    swallowDayMomentum = true
                } // armed pull → flip; eat the fling tail
            }
        } else {
            engine.onWheel(dx: e.scrollingDeltaX, dy: e.scrollingDeltaY)
        }
    }

    override func magnify(with e: NSEvent) {
        if modalActive {
            return
        }
        let began = e.phase.contains(.began)
        let ended = e.phase.contains(.ended) || e.phase.contains(.cancelled)
        engine?.onMagnify(delta: e.magnification, at: point(e), began: began, ended: ended)
    }

    /// ── Right-click (or ctrl-click) on an event → the context callout ──
    override func rightMouseDown(with e: NSEvent) {
        if !openEventMenu(with: e), !openSpaceMenu(with: e) {
            super.rightMouseDown(with: e)
        }
    }

    /// Right-click on EMPTY space: a create/paste callout anchored at the pointer — a timeline
    /// slot offers New Event / New Deadline, a band lane offers New Event (band); paste follows.
    @discardableResult private func openSpaceMenu(with e: NSEvent) -> Bool {
        guard !modalActive, let engine, let onSpaceMenu else { return false }
        let p = point(e)
        guard !engine.inDayDashboard(p), engine.itemId(at: p) == nil,
              let spot = engine.emptySpot(at: p) else { return false }
        let view = convert(e.locationInWindow, from: nil)
        onSpaceMenu(spot, CGRect(x: view.x + 4, y: view.y - 1, width: 1, height: 2))
        return true
    }

    /// Hit-test the click, select the item, and hand its VIEW-space box rect to the SwiftUI layer
    /// (which presents the popover). Returns whether an event was actually under the pointer.
    @discardableResult private func openEventMenu(with e: NSEvent) -> Bool {
        guard !modalActive, let engine, let onEventMenu else { return false }
        let p = point(e)
        guard !engine.inDayDashboard(p), let id = engine.itemId(at: p) else { return false }
        engine.select(id)
        // Anchor: a sliver just off the CENTER of the box's right edge — clamped to the VISIBLE
        // content region (a 10-day band right-clicked in day view anchors at the timeline's edge,
        // not 9 days off-screen). Content right edge = dashboardLeftAnimated (vp.w outside day
        // view). Scene → view = +padLeft − drawerShift. Fall back to a pointer spot rect.
        let view = convert(e.locationInWindow, from: nil)
        let dx = Layout.padLeft - engine.drawerShift - engine.gutterShift
        let g = engine.snapshotInput()
        let anchor = engine.selectedBoxRect()
            .map { (r: CGRect) -> CGRect in
                let visMaxX = min(r.maxX, dashboardLeftAnimated(g))
                return CGRect(x: visMaxX + dx + 5, y: r.midY - 1, width: 1, height: 2)
            }
            ?? CGRect(x: view.x - 2, y: view.y - 2, width: 4, height: 4)
        onEventMenu(id, anchor)
        return true
    }

    override func mouseDown(with e: NSEvent) {
        if modalActive {
            return
        } // blocking modal up → canvas is inert
        if e.modifierFlags.contains(.control),
           openEventMenu(with: e) || openSpaceMenu(with: e) {
            return
        } // ctrl-click = right-click
        engine?.enterMouseMode() // mouse activity hides the keyboard cursor visual
        let p = point(e)
        // Day view: the daily-dashboard panel (and the band strip hidden behind it) owns its own clicks —
        // never start a calendar action (band-create, select, drill) under the panel.
        if engine?.inDayDashboard(p) == true {
            return
        }
        // Track-name edit: a click just commits/dismisses it (swallowed — no zoom).
        if engine?.trackEditing == true {
            window?.makeFirstResponder(self)
            return
        }
        // Band/timed-title edit: commit/dismiss it (blur), then let THIS click act normally —
        // selecting another event, or deselecting on blank (fall through below).
        if engine?.bandEditing == true || engine?.timedEditing == true {
            window?.makeFirstResponder(self)
        }
        // Year view: clicking a track-name gutter slot opens the inline editor.
        if e.clickCount == 1, let hit = engine?.trackNameHit(at: p) {
            onEditTrack?(TrackEdit(month: hit.month, track: hit.track, rect: hit.rect))
            return
        }
        window?.makeFirstResponder(self)
        let shift = e.modifierFlags.contains(.shift)
        let command = e.modifierFlags.contains(.command)
        if e.clickCount == 2, !shift { // double-click any item → open its drawer (Shift = a multi-select gesture)
            // Open the SOURCE event (a ghost/promoted box maps back to its real item); the clicked
            // box stays selected → it gets the focused thick border while the series stays active.
            if let id = engine?.itemId(at: p) {
                onOpenEvent?(sourceId(of: id))
            }
            return
        }
        engine?.onPointerDown(at: p, shift: shift, command: command)
    }

    override func mouseDragged(with e: NSEvent) {
        if modalActive {
            return
        }
        engine?.onPointerDrag(at: point(e)); setCursor(.closedHand)
    }

    override func mouseUp(with e: NSEvent) {
        if modalActive {
            return
        }
        engine?.onPointerUp(at: point(e))
    }

    /// The content extends under the (floating) window toolbar, and our tracking area reaches up
    /// there too — so ignore pointer events whose location is above the content area's top edge.
    private func overToolbar(_ e: NSEvent) -> Bool {
        guard let win = window else { return false }
        return e.locationInWindow.y > win.contentLayoutRect.maxY // window coords: y grows upward
    }

    override func mouseMoved(with e: NSEvent) {
        if modalActive {
            return
        }
        engine?.enterMouseMode() // mouse activity hides the keyboard cursor visual
        if overToolbar(e) {
            engine?.onHoverExit(); setCursor(.arrow); return
        } // don't hover through the toolbar
        if engine?.drawerOpen == true {
            return
        } // drawer open → SwiftUI owns the cursor (title I-beam, handle resize)
        if scrolling {
            return
        } // a scroll is in flight — skip hover recompute (perf)
        let p = point(e)
        // The dashboard web view owns its region AND its cursor (CSS drives pointer/hand over clickable
        // rows). Don't set a cursor here — our tracking area fires even under the overlaying web view, so
        // forcing .arrow would fight the web view's pointer cursor every move → visible flicker.
        if engine?.inDayDashboard(p) == true {
            engine?.onHoverExit(); return
        }

        // The NATIVE pinned panel (cc.nativeDash, week/month) owns its own pointer: its rows set
        // the hand via .pointerStyle, which per-move applyCursor here would stomp. Settle to the
        // arrow ONCE on entry (so a grab hand can't linger in), then leave the cursor alone.
        if let engine, NativeDash.enabled,
           engine.chrome.level == 3 || (engine.dashPinned && (1 ... 2).contains(engine.chrome.level)),
           engine.inDayDashboard(p) {
            if appliedCursor != .arrow { setCursor(.arrow) }
            toolTip = nil
            return
        }
        engine?.onHover(at: p)
        toolTip = engine?.bandWarningTooltip(at: p) // "Fully overlapping events" over the warn sign
        applyCursor(engine?.cursorHint(at: p))
    }

    /// cursorUpdate RE-ASSERTS the last cursor mouseMoved computed — it never recomputes.
    /// Synthesized cursorUpdate events (tracking-area churn during the per-frame renders) can carry
    /// stale/bogus locations; recomputing the hint from those flipped grab→arrow over a hovered
    /// band on alternate events — a visible flicker. mouseMoved (continuous, real coordinates) is
    /// the single source of truth; this handler just keeps AppKit from stomping its choice.
    override func cursorUpdate(with e: NSEvent) {
        if modalActive || engine?.drawerOpen == true {
            NSCursor.arrow.set(); return
        }
        if overToolbar(e) {
            NSCursor.arrow.set(); return
        }
        // Region checks use the LIVE pointer, not the event location: synthesized cursorUpdate
        // events (tracking-area churn, and notably SCROLL-END) carry stale/bogus locations — a
        // pointer genuinely over the panel failed the check and got the arrow stomped over the
        // rows' pointing hand the moment a scroll settled.
        if let w = window {
            let live = convert(w.mouseLocationOutsideOfEventStream, from: nil)
            let gp = CGPoint(x: live.x - Layout.padLeft + (engine?.drawerShift ?? 0)
                                 + (engine?.gutterShift ?? 0), y: live.y)
            if engine?.inDayDashboard(gp) == true {
                return
            } // the dashboard (web view or native panel) owns its own cursor
        }
        appliedCursor.set()
    }

    /// The last cursor WE chose (mouseMoved / drag / exit) — cursorUpdate re-asserts exactly this.
    private var appliedCursor: NSCursor = .arrow

    private func setCursor(_ c: NSCursor) {
        appliedCursor = c
        c.set()
    }

    private func applyCursor(_ hint: CalendarEngine.CursorHint?) {
        switch hint {
        case .grab: setCursor(.openHand)
        case .resizeLR: setCursor(.resizeLeftRight)
        case .resizeV: setCursor(.resizeUpDown) // timed-event top/bottom edge
        case .text: setCursor(.iBeam)
        default: setCursor(.arrow)
        }
    }

    override func mouseExited(with e: NSEvent) {
        engine?.onHoverExit(); setCursor(.arrow)
    }

    // Keyboard is handled by a LOCAL EVENT MONITOR (installed below), NOT keyDown on this view. That's
    // deliberate: when the drawer (a SwiftUI overlay) opens it can pull first-responder off the canvas,
    // which would make view-based keyDown silently stop firing. The monitor sees every key for our
    // window regardless of first responder, so the shortcuts keep working; it only steps aside (returns
    // the event) when a real text input is focused, so typing/native undo still go to the field.
    private var keyMonitor: Any?
    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] e in
            self?.handleKey(e) ?? e
        }
    }

    private func handleKey(_ e: NSEvent) -> NSEvent? {
        guard let w = window, e.window === w else { return e } // only our (key) window's events
        switch e.type {
        case .keyDown:
            // A blocking modal (delete confirm) owns the ENTIRE keyboard. Route only its nav keys — ←/→ move
            // the focused button, Enter confirms, Esc cancels — and swallow EVERYTHING else, INCLUDING
            // ⌘-combos, so ⌘K / ⌘F / ⌘N / etc. are all disabled while it's up. First, so it wins over the
            // command handlers below. (Menu-driven ⌘-shortcuts in the signed app are gated separately.)
            if isModalDelete?() == true {
                if !e.isARepeat, !e.modifierFlags.contains(.command) {
                    switch e.keyCode {
                    case 123: onDeleteDialogKey?(.left)
                    case 124: onDeleteDialogKey?(.right)
                    case 36, 76: onDeleteDialogKey?(.confirm)
                    case 53: onDeleteDialogKey?(.cancel)
                    default: break
                    }
                }
                return nil
            }
            // The batch-rename panel is modal WITH typing: Esc cancels (reverting the live renames)
            // from ANYWHERE — even when its text field isn't focused, where Esc would otherwise
            // zoom the calendar behind the still-open panel. Typing flows to the focused field;
            // Enter with the field unfocused still commits; every other key is swallowed
            // (modalActive already blocks the pointer).
            if isBatchRenaming?() == true {
                if e.keyCode == 53 {
                    onBatchRenameCancel?(); return nil
                }
                if isTextInputFocused() {
                    return e
                }
                if e.keyCode == 36 || e.keyCode == 76 {
                    onBatchRenameCommit?(); return nil
                }
                return nil
            }
            // The tutorial carousel likewise owns the keyboard: ←/→ page, Enter next/done, Esc closes.
            if isTutorialUp?() == true {
                if !e.isARepeat, !e.modifierFlags.contains(.command) {
                    switch e.keyCode {
                    case 123: onTutorialKey?(.left)
                    case 124: onTutorialKey?(.right)
                    case 36, 76: onTutorialKey?(.confirm)
                    case 53: onTutorialKey?(.cancel)
                    default: break
                    }
                }
                return nil
            }
            // Cmd+K → hold-to-show the shortcut guide (ignore auto-repeat; released on keyUp/flagsChanged).
            // Deliberately ABOVE the text-input check: the guide is a transient overlay that types
            // nothing, and while a note editor is focused it's how the editor's own keys are discovered.
            if e.keyCode == 40, e.modifierFlags.contains(.command) {
                if !keyGuideShown {
                    keyGuideShown = true; onKeyGuide?(true)
                }
                return nil
            }
            // A focused field/editor owns every other key: typing, native undo, and the markdown
            // editor's own bindings (Tab/⇧Tab indent, ⌥↑/⌥↓ move line, ⌘←/→ line bounds, ⌘S preview,
            // Esc exit). ALL custom hotkeys below — including ⌘F search — stand down so none of them
            // can hitch the editor.
            if isTextInputFocused() {
                return e
            }
            // Cmd+F → open the toolbar search field (works from any state; the field then owns the keys).
            if e.keyCode == 3, e.modifierFlags.contains(.command), !e.isARepeat {
                onSearch?()
                return nil
            }
            // ⌘Z / ⌘⇧Z are owned SOLELY by the Edit▸Undo/Redo menu command (one focus-aware handler). We
            // must NOT act on them here — doing so alongside the menu shortcut fired undo twice (rename +
            // create both undone on one press) — but we also must not let the catch-all `return nil` below
            // swallow them, or the menu shortcut never sees the key. So pass them straight through.
            if e.keyCode == 6, e.modifierFlags.contains(.command),
               !e.modifierFlags.contains(.option), !e.modifierFlags.contains(.control) {
                return e
            }
            // ⌘C / ⌘X / ⌘V are owned by the Edit menu's Copy/Cut/Paste items, which target this view's
            // copy(_:)/cut(_:)/paste(_:). Like ⌘Z, pass them through so the menu key equivalents fire
            // (the catch-all `return nil` below would otherwise swallow them before the menu sees them).
            if e.modifierFlags.contains(.command), !e.modifierFlags.contains(.option),
               !e.modifierFlags.contains(.control),
               let ch = e.charactersIgnoringModifiers?.lowercased(), ch == "c" || ch == "x" || ch == "v" || ch == "p" {
                return e // ⌘P → File ▸ Print… (the menu key equivalent must see the event)
            }
            // ⌘A select-all-in-viewport / ⌘D deselect-all — calendar-owned (a focused text field kept ⌘A above).
            if e.modifierFlags.contains(.command), !e.modifierFlags.contains(.option),
               !e.modifierFlags.contains(.control), !e.isARepeat,
               let ch = e.charactersIgnoringModifiers?.lowercased() {
                if ch == "a" {
                    engine?.selectAllInViewport(); return nil
                }
                if ch == "d" {
                    engine?.deselectAll(); return nil
                }
            }
            engine?.wake() // calendar-owned key → drive a render (keyboard cursor/nav)
            if let token = Self.token(for: e) {
                // ⌘T → "go to today" from ANY navigation state (not just ones whose bindings include it).
                // Handled here so it's truly global; ignore OS auto-repeat so a held ⌘T flies once.
                if token == .cmdT {
                    if !e.isARepeat {
                        engine?.enterKeyboardMode(); engine?.goToToday()
                    }
                    return nil
                }
                // ⌘L → new deadline, also global: at the block cursor in keyboard mode, else at the
                // mouse pointer's timeline slot (the engine picks; no mode switch here).
                if token == .cmdL {
                    if !e.isARepeat {
                        engine?.createDeadlineViaShortcut()
                    }
                    return nil
                }
                // Repeatable keys (arrows, ⌘/⇧-arrows): we drive the auto-repeat OURSELVES (see the held-key
                // timer below) instead of the OS. macOS only repeats the LAST key pressed and never resumes
                // an earlier still-held key — so holding ← then tapping ↓ would "stick". Ignoring the OS
                // repeat and repeating the most-recently-held key ourselves keeps ← going after ↓ releases.
                if token.repeats {
                    if e.isARepeat {
                        return nil
                    } // OS repeat suppressed; our timer drives it
                    dispatchNav(token) // fire once on the fresh press (reveal-first handled inside)
                    trackHeld(e.keyCode, token)
                    return nil
                }
                // Discrete actions (Enter/Space/Tab/Esc/…): ignore OS auto-repeat (would double-fire).
                if e.isARepeat {
                    return nil
                }
                if onKey?(token) == true {
                    engine?.enterKeyboardMode(); return nil
                } // dispatched → keyboard mode
            }
            switch e.keyCode { // fallbacks for keys the current state didn't bind
            case 53: engine?.enterKeyboardMode(); engine?.onEscape() // Esc → zoom out one level
            case 51, 117: onRequestDelete?() // Delete → raise the confirm dialog
            default: break
            }
            // Swallow any other unhandled key too. With no text field focused, the calendar owns the
            // keyboard; letting a key fall through to the window makes it emit the "funk" beep (e.g.
            // Space while the drawer is open). Command-shortcuts are handled earlier via menu key
            // equivalents, so they're unaffected. This is why we don't need to touch the window.
            return nil
        case .keyUp:
            if e.keyCode == 40, keyGuideShown {
                keyGuideShown = false; onKeyGuide?(false); return nil
            }
            if releaseHeld(e.keyCode) {
                return nil
            } // a held nav key lifted → update the repeat set
            return e
        case .flagsChanged:
            if keyGuideShown, !e.modifierFlags.contains(.command) {
                keyGuideShown = false; onKeyGuide?(false)
            }
            return e
        default: return e
        }
    }

    // ── Custom auto-repeat for held navigation keys ────────────────────────────────────────────────
    // macOS repeats only the most-recently-pressed key and never resumes a still-held earlier one. We
    // track held repeatable keys ourselves and repeat the LAST one still down, so holding ← then tapping
    // ↓ resumes ← after ↓ is released (block & band cursors, event nav, etc.).
    private var heldOrder: [UInt16] = [] // keyCodes, ordered by press (last = most recent)
    private var heldToken: [UInt16: KeyToken] = [:]
    private var repeatTimer: Timer?
    private let repeatDelay: TimeInterval = 0.30
    private let repeatInterval: TimeInterval = 0.045

    /// Dispatch a nav token (with reveal-first): the first arrow after mouse mode only wakes the cursor.
    private func dispatchNav(_ token: KeyToken) {
        if isTextInputFocused() {
            return
        }
        engine?.wake()
        let isArrow = token == .up || token == .down || token == .left || token == .right
        if isArrow, engine?.cursor.keyboardActive == false {
            engine?.enterKeyboardMode(); return
        }
        if onKey?(token) == true {
            engine?.enterKeyboardMode()
        }
    }

    private func trackHeld(_ kc: UInt16, _ token: KeyToken) {
        heldOrder.removeAll { $0 == kc }; heldOrder.append(kc); heldToken[kc] = token
        repeatTimer?.invalidate() // fresh press → restart the delay-then-repeat cycle
        repeatTimer = Timer
            .scheduledTimer(withTimeInterval: repeatDelay, repeats: false) { [weak self] _ in self?.beginRepeating() }
    }

    private func releaseHeld(_ kc: UInt16) -> Bool {
        guard heldToken[kc] != nil else { return false }
        heldOrder.removeAll { $0 == kc }; heldToken[kc] = nil
        if heldOrder.isEmpty {
            stopRepeat()
        } // keep firing the remaining held key(s)
        return true
    }

    private func beginRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: repeatInterval, repeats: true) { [weak self] _ in
            guard let self, self.window?.isKeyWindow == true, let kc = self.heldOrder.last,
                  let token = self.heldToken[kc]
            else { self?.stopRepeat(); return }
            self.dispatchNav(token)
        }
    }

    private func stopRepeat() {
        repeatTimer?.invalidate(); repeatTimer = nil; heldOrder.removeAll(); heldToken.removeAll()
    }

    /// Is a real text-input view the first responder? Then keys belong to it (typing / native undo),
    /// so the shortcut monitor steps aside. Covers the field editor (NSText) and the notes WKWebView.
    private func isTextInputFocused() -> Bool {
        // A drawer inline editor (the date/time NSDatePicker) owns the keyboard even though its focused
        // control isn't an NSText — pass all keys (incl. Tab) to it, don't advance the drawer cycle.
        if isEditingText?() == true {
            return true
        }
        guard let r = window?.firstResponder else { return false }
        if r === self {
            return false
        }
        // If focus lives inside a notes editor, trust ITS click-gate — not the raw responder class.
        // WebKit makes the WKWebView's internal WKContentView first responder on load, so a class-name
        // match would wrongly report "editing" the moment the drawer opens and swallow drawer shortcuts.
        // Walking up to the FocusGatedWebView and reading focusAllowed tells us if the user *clicked in*.
        if let v = r as? NSView {
            var node: NSView? = v
            while let cur = node {
                // Any gated web editor (drawer notes OR the daily-note dashboard) → trust its click-gate.
                if let gated = cur as? FocusGatedControl {
                    return gated.focusAllowed
                }
                node = cur.superview
            }
        }
        if r is NSText {
            return true
        } // a field editor (NSTextField / inline title) owns the keys
        let cls = String(describing: type(of: r))
        return cls.contains("TextView") || cls.contains("TextField")
    }

    /// The canvas swallows raw keyDown (no beep) when it's first responder; the monitor above does the work.
    override func keyDown(with e: NSEvent) {}

    /// Normalize a raw key event into a view-independent `KeyToken` (or nil to leave it to native).
    private static func token(for e: NSEvent) -> KeyToken? {
        if e.modifierFlags.contains(.command) {
            switch e.keyCode { // ⌘+arrows → nudge the selected event
            case 126: return .cmdUp
            case 125: return .cmdDown
            case 123: return .cmdLeft
            case 124: return .cmdRight
            default:
                switch e.charactersIgnoringModifiers?.lowercased() {
                case "s": return .cmdS
                case "n": return .cmdN
                case "t": return .cmdT // ⌘T → go to today (any view)
                case "u": return .cmdU // ⌘U → toggle promote on the selected timed event
                case "l": return .cmdL // ⌘L → new deadline at pointer / block cursor
                case "=", "+": return .cmdEqual // ⌘= / ⌘+ → zoom in
                case "-", "_": return .cmdMinus // ⌘− → zoom out
                default: return nil // other ⌘-combos → menu/native
                }
            }
        }
        let shift = e.modifierFlags.contains(.shift)
        switch e.keyCode {
        case 36, 76: return .enter
        case 49: return .space
        case 53: return .escape
        case 48: return shift ? .backTab : .tab
        case 123: return shift ? .shiftLeft : .left
        case 124: return shift ? .shiftRight : .right
        case 126: return shift ? .shiftUp : .up
        case 125: return shift ? .shiftDown : .down
        case 51, 117: return .delete
        default:
            if let ch = e.charactersIgnoringModifiers?.first, ch.isLetter || ch.isNumber {
                return .char(ch)
            }
            return nil
        }
    }

    /// Standard Undo/Redo actions. These reach the CatcherView ONLY when the calendar canvas is the
    /// first responder — when a text field / editor is focused it's first in the chain and does its own
    /// text undo instead, so ⌘Z layers correctly (text edits vs calendar edits).
    @objc func undo(_ sender: Any?) {
        engine?.undo()
    }

    @objc func redo(_ sender: Any?) {
        engine?.redo()
    }

    /// ── Clipboard: Copy / Cut / Paste / Delete (Edit menu + ⌘C/⌘X/⌘V, targeting the first responder) ──
    private static let clipType = NSPasteboard.PasteboardType("com.libirabu.calendarkit.clip")

    /// Unambiguous entry point for programmatic copy (the context menu): `copy(nil)` from outside
    /// collides with NSObject's `copy()`/`copy(with:)` overloads, this name can't.
    func copySelection() {
        copy(nil as Any?)
    }

    func cutSelection() {
        cut(nil as Any?)
    }

    @objc func copy(_ sender: Any?) {
        guard let engine, let id = engine.selectedId,
              let clip = engine.clipPayload(of: id, full: false) else { NSSound.beep(); return }
        writeClip(clip)
    }

    @objc func cut(_ sender: Any?) {
        guard let engine, let id = engine.selectedId, engine.cutEligible(id),
              let clip = engine.clipPayload(of: id, full: true)
        else { NSSound.beep(); return } // read-only / ghost / promoted → no cut
        writeClip(clip)
        engine.remove(id) // undoable (beginTxn/commitTxn)
    }

    @objc func paste(_ sender: Any?) {
        performPaste()
    }

    /// Unambiguous entry point for programmatic paste (the empty-space context menu).
    func performPaste() {
        guard let engine else { return }
        if importICSFromPasteboard(engine) {
            return
        } // a system .ics file / VCALENDAR text → import
        guard let clip = readClip() else { NSSound.beep(); return }
        if engine.paste(clip) == nil {
            NSSound.beep()
        } // no valid drop target for this kind/view
    }

    @objc func delete(_ sender: Any?) {
        guard engine?.selectedId != nil else { NSSound.beep(); return }
        onRequestDelete?() // raise the confirm dialog (imported → "make invisible", recurring → scope)
    }

    @objc override func selectAll(_ sender: Any?) {
        engine?.selectAllInViewport()
    }

    @objc func deselectAll(_ sender: Any?) {
        engine?.deselectAll()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return engine?.canUndo ?? false
        case #selector(redo(_:)): return engine?.canRedo ?? false
        case #selector(copy(_:)): return engine?.selectedId != nil
        case #selector(delete(_:)): return engine?.selectedId != nil
        case #selector(cut(_:)): if let e = engine, let id = e.selectedId {
                return e.cutEligible(id)
            }; return false
        case #selector(paste(_:)): return pasteboardHasPasteable()
        case #selector(selectAll(_:)): return engine
            .map { !($0.viewEvents().isEmpty && $0.viewBands().isEmpty && $0.viewDeadlines().isEmpty) } ?? false
        case #selector(deselectAll(_:)): return !(engine?.selectedIds.isEmpty ?? true)
        default: return true
        }
    }

    /// ── NSPasteboard plumbing ─────────────────────────────────────────────────────
    private func writeClip(_ clip: CalendarEngine.ClipPayload) {
        guard let data = try? JSONEncoder().encode(clip) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: Self.clipType)
        pb.setString(clip.title, forType: .string) // a plain-text flavor so the title can paste elsewhere
    }

    func readClip() -> CalendarEngine.ClipPayload? { // internal: the context menu checks the kind
        NSPasteboard.general.data(forType: Self.clipType).flatMap { try? JSONDecoder().decode(
            CalendarEngine.ClipPayload.self,
            from: $0
        ) }
    }

    /// If the system clipboard holds a `.ics` file (Finder copy) or raw VCALENDAR text, import it and
    /// return true (⌘V then acts as Import). Otherwise false → fall through to the in-app clipboard.
    private func importICSFromPasteboard(_ engine: CalendarEngine) -> Bool {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let ics = urls.filter { $0.pathExtension.lowercased() == "ics" }
            if !ics.isEmpty {
                let n = ics.reduce(0) { $0 + ((try? engine.importICS(from: $1)) ?? 0) }
                if n == 0 {
                    NSSound.beep()
                }
                return true
            }
        }
        if let s = pb.string(forType: .string), s.contains("BEGIN:VCALENDAR") {
            if ((try? engine.importICS(text: s, provenance: "Clipboard")) ?? 0) == 0 {
                NSSound.beep()
            }
            return true
        }
        return false
    }

    private func pasteboardHasPasteable() -> Bool {
        let pb = NSPasteboard.general
        if pb.data(forType: Self.clipType) != nil {
            return true
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
           urls.contains(where: { $0.pathExtension.lowercased() == "ics" }) {
            return true
        }
        if let s = pb.string(forType: .string), s.contains("BEGIN:VCALENDAR") {
            return true
        }
        return false
    }
}
