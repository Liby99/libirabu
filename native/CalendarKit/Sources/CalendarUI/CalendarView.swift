// The calendar surface: a per-frame Canvas driven by TimelineView(.animation),
// with an AppKit input bridge overlay for scroll-wheel / pinch / click / hover.

import CalendarEngine
import CalendarGeometry
import SwiftUI

public struct CalendarView: View {
    @State private var engine = CalendarEngine()
    @State private var ui = CalendarUIState()
    @State private var drawerWidth: CGFloat = 410
    // The drawer's slide-in is a .move transition; a state-mutating hover inside it (the resize
    // handle sweeping under a stationary mouse) re-renders the transitioning subtree and FREEZES
    // the presentation mid-flight (model already final → snaps at the end). Mouse-transparent
    // until the entrance settles, so no hover can fire during the animation.
    @State private var drawerSettling = false
    @State private var monthBridge = MonthPagerBridge()
    @State private var weekBridge = WeekPagerBridge()
    @State private var dayBridge = DayPagerBridge()
    @State private var dashCarousel = DashboardCarousel()
    @State private var dashAnim = DashCarouselAnim() // per-frame carousel state for the native tabs
    @State private var gestureForwarder = GestureForwarder() // dashboard → catcher (horiz scroll + pinch)
    @State private var dashFrac: CGFloat = 0.45 // mirrors engine.daily.frac; updated live on resize
    @State private var dashTab: DashTab = .todo // dashboard TODO/NOTE tab
    @State private var demo = DemoController() // scripted GIF-recording cursor + scenes (CC_DEMO mode)
    @State private var noteMode: NotesMode = .edit // daily-note edit/preview (native toggle mirrors JS)
    @State private var dashNav = NativeDashNavModel() // native pinned-panel keyboard row cursor
    @State private var dashPinchMag: CGFloat? // in-flight pinch over the native panels (nil = none)
    @State private var search = SearchState() // toolbar event search (⌘F / magnifyingglass)
    @State private var searchAnchor: CGPoint = .zero // content stack's window-space origin (for dropdown alignment)
    @State private var searchCloseWork: DispatchWorkItem? // pending "unmount the bar after it collapses"
    @State private var showTagFilter = false               // View ▸ Filter by Tags popover (toolbar-anchored)
    /// Global Performance Mode: render events as flat tinted fills instead of Liquid Glass
    /// (glass is one GPU pass per sticker). Persisted; defaults on for now.
    @AppStorage("cc.performanceMode") private var perfMode = true
    // Bench override: CC_PERF_OFF=1 forces the Liquid-Glass path on (Performance Mode OFF) so the
    // profiler can measure the GPU-heavy path the throwaway store's default (perfMode on) never hits.
    private static let forcePerfOff = ProcessInfo.processInfo.environment["CC_PERF_OFF"] != nil
    private var effPerfMode: Bool { perfMode && !Self.forcePerfOff }
    // CC_DASH_UNMOUNT=1 → the OLD lazy dashboard mount (WebView created at each month→week crossing),
    // for same-binary A/B against the persistent mount (see the dashboard overlay below).
    private static let dashUnmountKill = ProcessInfo.processInfo.environment["CC_DASH_UNMOUNT"] != nil
    // The View-menu prefs (show-hidden, current/alt timezone) → repaint observers live in ViewPrefObservers
    // (bundled into one modifier to keep the body's modifier chain within the Swift type-checker's budget).
    @AppStorage("cc.tutorial.seen") private var tutorialSeen = false // auto-show the onboarding carousel once
    @AppStorage("cc.fpsHUD") private var fpsHUDPref = false // Settings ▸ Developer ▸ frame-rate HUD
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openWindow) private var openWindow // opens the standalone Calendar AI window
    // The quick-ask callout's OWN assistant session (app-level; independent of the standalone
    // window's session, sharing only the conversation store). nil (dev shell) → window only.
    private let assistant: AssistantState?
    // The standalone window's session — "Open in window" hands the callout's thread to it.
    private let windowAssistant: AssistantState?
    @State private var showAssistantCallout = false

    // Dashboard TODO layering (sources / collections / deadlines per scope) + its callout menu.
    // The menu controller is long-lived state (NSMenuItem.target is weak) and resolves the CURRENT
    // dashboard scope at pop time from the engine's chrome level.
    @State private var todoSettings: DashTodoSettings
    @State private var todoMenu: DashTodoMenuController

    /// Inject a shared engine so another scene (the standalone Calendar AI window) can read the
    /// same live calendar state. Defaults to a fresh engine when hosted standalone.
    @MainActor public init(engine: CalendarEngine? = nil, assistant: AssistantState? = nil,
                           windowAssistant: AssistantState? = nil) {
        let e = engine ?? CalendarEngine()
        _engine = State(initialValue: e)
        let settings = DashTodoSettings()
        _todoSettings = State(initialValue: settings)
        _todoMenu = State(initialValue: DashTodoMenuController(settings: settings, scope: {
            e.chrome.level == 3 ? .day : (e.chrome.level == 2 ? .week : .month)
        }))
        self.assistant = assistant
        self.windowAssistant = windowAssistant
    }

    /// After an inline editor (title / track name) commits, its text field was first responder; return
    /// first-responder to the calendar canvas so keyboard shortcuts keep working (e.g. Enter → edit
    /// title → Enter → back to selected → Enter → edit again). Deferred so it runs after the field is
    /// torn down. `gestureForwarder.catcher` is the live CatcherView (set by the InputCatcher).
    private func refocusCatcher() {
        DispatchQueue.main.async {
            if let c = gestureForwarder.catcher {
                c.window?.makeFirstResponder(c)
            }
        }
    }

    /// Context menu's "Rename": the same inline editor each kind's hotkey uses; deadlines have no
    /// inline editor, so their title is edited in the drawer (opened with the title pre-selected).
    private func renameInline(_ id: String) {
        switch engine.kind(of: id) {
        case .timed: engine.editTimed(id)
        case .band: engine.editBand(id)
        case .deadline: ui.selectTitleOnOpen = true; ui.openEventId = sourceId(of: id)
        default: break
        }
    }

    /// The blocking-modal bundle, built OUTSIDE the body chain: the chain is ONE expression to
    /// the type checker, and adding closure arguments to a call inside it is what pushed solves
    /// into the minutes (bisected 2026-07-18). Constructed here, the closures never enter it.
    private func modalOverlays(theme: Theme) -> ModalOverlays {
        ModalOverlays(ui: ui, engine: engine, theme: theme,
                      onDelete: { performDelete($0) },
                      onRename: { renameInline($0) },
                      onCopy: { (gestureForwarder.catcher as? CatcherView)?.copySelection() },
                      onCut: { (gestureForwarder.catcher as? CatcherView)?.cutSelection() },
                      onPaste: { (gestureForwarder.catcher as? CatcherView)?.performPaste() },
                      readClip: { (gestureForwarder.catcher as? CatcherView)?.readClip() })
    }

    /// The AppKit input bridge, built OUTSIDE the body chain and assignment-style: the chain is
    /// ONE expression to the type checker, and a many-closure call inside it (or anywhere — the
    /// cost is exponential in argument count) is what pushed solves into the minutes (bisected
    /// 2026-07-18). One tiny statement per hook keeps this trivially cheap forever.
    private func inputCatcher() -> InputCatcher {
        var ic = InputCatcher(engine: engine, monthBridge: monthBridge,
                              weekBridge: weekBridge, dayBridge: dayBridge)
        ic.forwarder = gestureForwarder
        ic.onOpenEvent = { ui.openEventId = $0 }
        ic.onEventMenu = { (id: String, anchor: CGRect) in
            ui.eventMenu = CalendarUIState.EventMenuTarget(id: id, anchor: anchor)
        }
        ic.onSpaceMenu = { (spot: CalendarEngine.EmptySpot, anchor: CGRect) in
            ui.spaceMenu = CalendarUIState.SpaceMenuTarget(spot: spot, anchor: anchor)
        }
        ic.onEditTrack = { te in engine.trackEditing = true; ui.editingTrack = te }
        // The keyboard state machine + the Cmd+K guide toggle. `onKey` reads
        // live engine/ui state each press; returns whether it consumed the key.
        ic.onKey = { KeyboardModel(engine: engine, ui: ui).handle($0) }
        ic.onKeyGuide = { ui.showKeyGuide = $0 }
        ic.isEditingText = { ui.drawerFieldEditing }
        ic.onSearch = { openSearch() }
        ic.isModalDelete = {
            ui.pendingDelete != nil || ui.pendingBatchDelete != nil || ui.notice != nil
                || ui.calendarPrompt != nil || ui.pendingCalendarRemove
        }
        ic.onDeleteDialogKey = { handleDeleteDialogKey($0) }
        ic.isBatchRenaming = { ui.batchRenaming }
        ic.onBatchRenameCancel = { cancelBatchRename(ui: ui, engine: engine) }
        ic.onBatchRenameCommit = { commitBatchRename(ui: ui, engine: engine) }
        ic.onRequestDelete = {
            if let t = engine.deleteTargetForSelection() {
                ui.requestDelete(
                    id: t.id,
                    occKey: t.occKey,
                    recurring: t.recurring,
                    imported: t.imported,
                    alreadyHidden: t.alreadyHidden,
                    kind: engine.kind(of: t.id) ?? .timed,
                    viaGhost: t.viaGhost,
                    atBase: t.atBase
                )
            }
        }
        ic.isTutorialUp = { ui.showTutorial }
        ic.onTutorialKey = { handleTutorialKey($0) }
        return ic
    }

    /// ── Delete-confirm dialog ─────────────────────────────────────────────────────
    /// Carry out a chosen scope, then dismiss the dialog (and the drawer, on an actual delete).
    private func performDelete(_ choice: DeleteChoice) {
        guard let pd = ui.pendingDelete else { return }
        switch choice {
        case .cancel: break
        case .thisEvent: engine.deleteOccurrence(pd.id, pd.occKey)
        case .thisAndFuture: engine.deleteFuture(pd.id, pd.occKey)
        case .deleteAll: engine.remove(pd.id)
        case .hide: engine.hideImportedSeries(pd.id) // imported → hide (can't truly delete)
        case .hideOccurrence: engine.hideImportedOccurrence(pd.id) // imported → hide just this one
        case .removeFromLane: engine.unpromote(pd.id) // ghost bar → clear the promotion, keep the item
        case .unhide: engine.unhideImportedSeries(pd.id) // revealed-hidden → bring it back
        }
        ui.pendingDelete = nil
        // Close the drawer only when the item actually left the calendar; lane removal and unhide
        // keep it around (and possibly still open in the drawer).
        if choice.isDestructive {
            ui.openEventId = nil
        }
        refocusCatcher() // keys go back to the calendar
        engine.wake()
    }

    /// The key monitor's ←/→/Enter/Esc while the dialog is up.
    private func handleDeleteDialogKey(_ key: DeleteDialogKey) {
        // Informational notice: any Enter/Esc dismisses.
        if ui.notice != nil {
            if key == .confirm || key == .cancel {
                ui.notice = nil; engine.wake()
            }
            return
        }
        // Batch-delete confirm (multi-selection): Enter deletes, Esc cancels.
        if ui.pendingBatchDelete != nil {
            switch key {
            case .confirm: engine.performBatchDelete(); ui.pendingBatchDelete = nil
            case .cancel: ui.pendingBatchDelete = nil
            case .left, .right: break
            }
            engine.wake(); return
        }
        // Remove-calendar confirm: Enter removes, Esc cancels. (The New/Rename prompt owns its own text
        // field, so its keys never reach here.)
        if ui.pendingCalendarRemove {
            switch key {
            case .confirm: engine.removeCurrentCalendar(); ui.pendingCalendarRemove = false
            case .cancel: ui.pendingCalendarRemove = false
            case .left, .right: break
            }
            engine.wake(); return
        }
        guard let pd = ui.pendingDelete else { return }
        switch key {
        case .left: ui.moveDeleteFocus(-1)
        case .right: ui.moveDeleteFocus(1)
        case .cancel: performDelete(.cancel)
        case .confirm: performDelete(pd.choices[pd.focus ?? pd.primaryIndex])
        }
        engine.wake()
    }

    /// One-time wiring on the calendar's first appearance. Extracted from `body` so the view's long
    /// modifier chain stays within the Swift type-checker's budget.
    private func setupOnAppear(size: CGSize) {
        WindowBeepSilencer.installOnce() // stop the window beeping on keys the calendar leaves unhandled
        if CalendarEngine.isDemoMode {
            demo.openSearchHook = { openSearch() }   // search-demo scene drives the real toolbar search
            demo.eventMenuHook = { id, r in ui.eventMenu = CalendarUIState.EventMenuTarget(id: id, anchor: r) }
            demo.dashTodoFocusHook = { dashCarousel.navFocus(.todo) }
            demo.dashTodoToggleHook = { dashCarousel.navActivate() }
            demo.dashWebCarousel = dashCarousel
            // Native dashboard: pre-build the todo/proj feeds shortly after launch, off any
            // animation — the first cmd+B / month entry then finds warm caches instead of
            // paying the cold parse inside its zoom tween.
            if NativeDash.enabled {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let today = NativeDashPanel.todayIso()
                    _ = engine.todoFeed(today: today)
                    _ = engine.projFeed(today: today)
                }
            }
            demo.closeEventMenuHook = { ui.eventMenu = nil }
            demo.searchState = search
            demo.startIfDemo(engine: engine, size: size)
        } // GIF recording session
        else if !tutorialSeen {
            tutorialSeen = true; ui.tutorialIndex = 0; ui.showTutorial = true
        } // first launch
        engine.setViewport(size)
        dashFrac = engine.daily.frac
        engine.onEditBand = { id, rect in engine.bandEditing = true; ui.editingBand = BandEdit(id: id, rect: rect) }
        engine.onEditTimed = { id, rect in engine.timedEditing = true; ui.editingTimed = TimedEdit(id: id, rect: rect) }
        engine.onEditTrackName = { m, t, rect in engine.trackEditing = true; ui.editingTrack = TrackEdit(
            month: m,
            track: t,
            rect: rect
        ) }
        engine.onRequestOpenDrawer = { id, selectTitle in ui.openEventId = id; ui.selectTitleOnOpen = selectTitle }
        // An external data change removed the item a drawer / delete-dialog / inline editor was showing
        // (e.g. deleted in Apple Calendar, then re-imported on foreground) → dismiss it.
        engine.onExternalDataChange = { [engine] in
            if let id = ui.openEventId, !engine.itemExists(id) {
                ui.openEventId = nil
            }
            if let pd = ui.pendingDelete,
               !engine.itemExists(pd.id) {
                ui.pendingDelete = nil; engine.inputModalUp = false
            }
            if let te = ui.editingTimed,
               !engine.itemExists(sourceId(of: te.id)) {
                ui.editingTimed = nil; engine.timedEditing = false
            }
            if let be = ui.editingBand,
               !engine.itemExists(sourceId(of: be.id)) {
                ui.editingBand = nil; engine.bandEditing = false
            }
        }
        // Day-view dashboard Tab stops (TODO / NOTE): the engine's keyboard system drives the WebView's row
        // cursor + note-editor focus through this bridge, and switches the native TODO/NOTE tab to match.
        engine.onDashCommand = { [carousel = dashCarousel, tabBinding = $dashTab, engine,
                                  dashNav, ui] cmd in
            // Native panels (cc.nativeDash, all scopes incl. DAY): the row cursor lives in
            // the native nav model — same key system, no webview bridge.
            if NativeDash.enabled, (1 ... 3).contains(engine.chrome.level) {
                switch cmd {
                case let .focus(stop):
                    if stop == .todo { tabBinding.wrappedValue = .todo; dashNav.focus() }
                    else { dashNav.blur(); if stop == .note { tabBinding.wrappedValue = .note } }
                case let .move(d):
                    dashNav.move(d)
                case .activate:
                    if let t = dashNav.currentRow { NativeDashPanel.toggleTodo(engine, t) }
                case .open:
                    if let t = dashNav.currentRow {
                        if t.source == "event" { ui.openEventId = sourceId(of: t.eventId) }
                        // Note rows: the fly-to-note flow needs view context — via the panel's
                        // row click for now (Enter parity lands with the editor revamp).
                    }
                case let .fold(open):
                    if let t = dashNav.currentRow {
                        let a = NativeDashPanel.anchor(t)
                        if open { dashNav.collapsedSubs.remove(a) }
                        else { dashNav.collapsedSubs.insert(a) }
                        engine.wake()
                    }
                case .editNote:
                    break // editor focus comes with the editor revamp
                }
                engine.wake()
                return
            }
            switch cmd {
            case let .focus(stop):
                if stop == .todo {
                    tabBinding.wrappedValue = .todo
                } else if stop == .note {
                    tabBinding.wrappedValue = .note
                }
                // TODO focus (or focus leaving the dashboard): the arrows/keys belong to the
                // CALENDAR's key system — if the web view holds first responder (e.g. the note
                // editor was just being edited when ⌘B fired), keys would never reach it.
                if stop != .note {
                    carousel.regateWebFocus()
                }
                carousel.navFocus(stop)
            case let .move(d): carousel.navMove(d)
            case .activate: // Space/Enter: note → focus the editor; todo → toggle the row
                if engine.cursor.dashStop == .note {
                    carousel.focusNoteEditor()
                } else {
                    carousel.navActivate()
                }
            case .open: carousel.navOpen()
            case let .fold(open): carousel.navFold(open)
            case let .editNote(ring): carousel.focusNoteEditor(ring: ring)
            }
            engine.wake()
        }
    }

    /// The key monitor's ←/→/Enter/Esc while the tutorial carousel is up.
    private func handleTutorialKey(_ key: DeleteDialogKey) {
        let last = TutorialView.slides.count - 1
        switch key {
        case .left: ui.tutorialIndex = max(0, ui.tutorialIndex - 1)
        case .right: ui.tutorialIndex = min(last, ui.tutorialIndex + 1)
        case .confirm: if ui.tutorialIndex >= last {
                ui.showTutorial = false
            } else {
                ui.tutorialIndex += 1
            }
        case .cancel: ui.showTutorial = false
        }
        engine.wake()
    }

    /// ── Toolbar search ───────────────────────────────────────────────────────────────
    private func openSearch() {
        engine.wake()
        searchCloseWork?.cancel(); searchCloseWork = nil // cancel a pending collapse (re-open mid-close)
        if search.open {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { search.expanded = true } // re-expand
        } else {
            search.open = true // mounts the bar; its onAppear animates the expand from the button
        }
    }

    /// Animate the bar collapsing back to the button, THEN unmount it (swap in the round button). Clearing
    /// the query first drops the dropdown; the delayed work is cancellable so a quick re-open aborts it.
    private func closeSearch() {
        search.query = ""; search.results = []; search.sel = 0
        withAnimation(.easeOut(duration: 0.24)) { search.expanded = false }
        searchCloseWork?.cancel()
        let work = DispatchWorkItem { search.open = false; refocusCatcher() }
        searchCloseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: work)
    }

    private func commitSearch() {
        guard search.results.indices.contains(search.sel) else { return }
        engine.revealAndSelect(id: search.results[search.sel].id)
        closeSearch()
    }

    /// The calendar scene for one frame's `input`. Rendered inside a `TimelineView(.animation)` while
    /// awake (per-frame), and as a plain static view while idle — NOT via `TimelineView(paused:)`, which
    /// keeps a display-cycle observer alive that re-lays-out the NSHostingView (and re-runs these Canvas
    /// draws) 60×/sec even when paused. Dropping the TimelineView from the tree entirely is what actually
    /// stops the idle redraw.
    private func calendarScene(_ input: SceneInput, vp: Viewport, theme: Theme) -> some View {
        // Rest-year layer cache (see YearLayerCache.swift): non-nil at z==0 with no page-turn/flip.
        let g0 = yearCacheInput(input)
        // Gutter hide: the scene lays out gutterShift wider (input.vp is inflated) and every
        // layer TRANSLATES left by the same amount — pure draw-transform motion, no view resize
        // (resizing the hosted WKWebView/NSScrollViews per frame is what tanks the framerate).
        let sceneDX = Layout.padLeft - engine.gutterShift
        return ZStack {
            // 1. scene below events — clipped to the content area. At rest-year the scroll-RIGID
            // slice records once at full year height and CA translates it; only the hover
            // highlights re-draw per frame. Elsewhere: the classic single per-frame canvas.
            if let g0 {
                Color.clear.overlay(alignment: .top) {
                    YearRigidBelow(g0: g0, theme: theme)
                        .equatable()
                        .frame(height: g0.vp.h)
                        .offset(y: -input.scrollY)
                }
                Canvas { ctx, _ in
                    var c = ctx
                    c.translateBy(x: sceneDX, y: 0)
                    RenderProf.measure("drawBelow", "1_drawBelow") {
                        SceneRenderer.drawBelow(input: input, filter: .hoverOnly, in: &c, theme: theme)
                    }
                }
            } else {
                Canvas { ctx, _ in
                    var c = ctx
                    c.translateBy(x: sceneDX, y: 0)
                    RenderProf.measure("drawBelow", "1_drawBelow") {
                        SceneRenderer.drawBelow(input: input, in: &c, theme: theme)
                    }
                }
            }
            // 2. events (bands + timed), Liquid Glass stickers
            EventsOverlay(input: input, events: engine.viewEvents(), bands: engine.viewBands(),
                          bandBadges: engine.viewBandBadges(), eventBadges: engine.viewEventBadges(),
                          selected: engine.selectedId, selectedIds: engine.selectedIds, hovered: engine.hoveredEventId,
                          drawerOpen: ui.openEventId != nil, editingId: ui.editingBand?.id ?? ui.editingTimed?.id,
                          editingRect: ui.editingTimed?.rect, // hide the title only on the segment being edited
                          draggingId: engine.activeTimedDragId,
                          perfMode: effPerfMode, monthLive: engine.monthGestureActive, editGen: engine.displayGen,
                          hideBox: ui.openEventId != nil ? engine.selectedId : nil, // lifted sharp above
                          yearG0: g0,
                          theme: theme)
                .offset(x: sceneDX)
            // 3. deadlines: the moment line + dots are drawn in the Canvas… When the drawer is open the
            // SELECTED deadline is HIDDEN here (drawn sharp in the lift below, like band/timed events).
            let liftDdl = ui.openEventId != nil ? engine.selectedId : nil
            Canvas { ctx, _ in
                var c = ctx
                c.translateBy(x: sceneDX, y: 0)
                RenderProf.measure("drawMid", "3_drawMid") {
                    SceneRenderer.drawMid(
                        input: input,
                        deadlines: engine.viewDeadlines(),
                        selected: engine.selectedId,
                        drawerOpen: ui.openEventId != nil,
                        hovered: engine.hoveredEventId,
                        hide: liftDdl,
                        in: &c,
                        theme: theme
                    )
                }
            }
            // …and the labels are SwiftUI glass pills (activation styling), above the line.
            DeadlinesOverlay(input: input, deadlines: engine.viewDeadlines(),
                             sides: engine.deadlineSides(),
                             selected: engine.selectedId, selectedIds: engine.selectedIds,
                             hovered: engine.hoveredEventId,
                             drawerOpen: ui.openEventId != nil, hide: liftDdl, theme: theme)
                .offset(x: sceneDX)
            // 4. chrome on top of the glass: gutter labels/borders, track names, now-line/cursor, dashboard title.
            // Rest-year: the gutter (month names + track names + borders) is scroll-rigid → cached layer;
            // the per-frame pass keeps only the gutter hover strip + foreground + pull hints.
            if let g0 {
                Color.clear.overlay(alignment: .top) {
                    YearRigidAbove(g0: g0, tracks: engine.items.trackNames,
                                   hideTrack: ui.editingTrack.map { ($0.month, $0.track) }, theme: theme)
                        .equatable()
                        .frame(height: g0.vp.h)
                        .offset(y: -input.scrollY)
                }
                Canvas { ctx, _ in
                    var c = ctx
                    c.translateBy(x: sceneDX, y: 0)
                    RenderProf.measure("drawAbove", "5_drawAbove") {
                        SceneRenderer.drawAbove(input: input, tracks: engine.items.trackNames,
                                                hideTrack: ui.editingTrack.map { ($0.month, $0.track) },
                                                filter: .hoverOnly, in: &c, theme: theme)
                    }
                }
            } else {
                Canvas { ctx, _ in
                    var c = ctx
                    c.translateBy(x: sceneDX, y: 0)
                    RenderProf.measure("drawAbove", "5_drawAbove") {
                        SceneRenderer.drawAbove(input: input, tracks: engine.items.trackNames,
                                                hideTrack: ui.editingTrack.map { ($0.month, $0.track) }, in: &c, theme: theme)
                    }
                }
            }
            // 4b. time tags ABOVE the chrome: the CURRENT TIME pill + cursor time tag render over the
            // gutter hour labels/borders, so their frosted glass blurs the labels instead of the
            // labels drawing crisp across the tag (the day-view left-gutter collision).
            TimeTagsOverlay(input: input, theme: theme)
                .offset(x: sceneDX)
            // Keyboard-navigation cursor (dashed sliding ring).
            CursorRing(rect: engine.blockCursorRect(), theme: theme, cornerRadius: 6,
                       geometryAnimating: engine.isAnimating)
                .offset(x: sceneDX)
            // Band cursor: a dashed cell over one lane × one day.
            CursorRing(rect: engine.bandCursorRect(), theme: theme, cornerRadius: 4,
                       geometryAnimating: engine.isAnimating)
                .offset(x: sceneDX)
            // Track-name cursor (month view's extra Tab stops): a dashed cell over the gutter name slot.
            CursorRing(rect: engine.trackNameCursorRect(), theme: theme, cornerRadius: 4,
                       geometryAnimating: engine.isAnimating)
                .offset(x: sceneDX)
            // Event cursor: dashed ring around the SELECTED event box (keyboard mode).
            CursorRing(rect: engine.selectionRingRect().map { $0.insetBy(dx: -2, dy: -2) },
                       theme: theme, cornerRadius: 8, geometryAnimating: engine.isAnimating)
                .offset(x: sceneDX)
            // Marquee selection box: dashed border + shaded fill. Positive select = red; negative = gray.
            if let m = engine.marqueeRect {
                let c = engine.marqueeNegative ? Color.secondary : theme.eventBorder("red")
                RoundedRectangle(cornerRadius: 2)
                    .fill(c.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(
                        c,
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    ))
                    .frame(width: m.width, height: m.height)
                    .position(x: m.midX, y: m.midY)
                    .offset(x: sceneDX)
                    .allowsHitTesting(false)
            }
            // Deadline quick-add "+" — a small circle on the hovered day column's left edge at the nearest
            // hour line (week/day view). Visual only (the whole scene is non-hit-testing); the click is
            // caught by the InputCatcher → onPointerDown → deadlineAddSpot. Hidden while the drawer is open.
            if ui.openEventId == nil, let spot = engine.deadlineAddSpot(input) {
                DeadlineAddButton(theme: theme, hovering: spot.hovering)
                    .position(x: spot.x, y: spot.y)
                    .offset(x: sceneDX)
            }
            // Per-frame day-carousel driver for the dashboard WebView (invisible). Carries {from,to,dir,p}
            // for day paging and `reveal` for the panel's slide-in-from-right + fade. Week level up.
            if input.z > 1.5 || input.dashPin > 0.01 {
                let c = engine.dashboardCarousel()
                // The webview frame sits at the DAY split in day view, at the narrower PINNED edge
                // at month/week — normalize the CSS slide against whichever frame is in use.
                // Gutter hide: geometry below must match the SceneInput's (possibly inflated) width.
                let vpw = input.vp.w
                let dayLOpen = Layout.labelW + dashFrac * max(1, vpw - Layout.labelW)
                let pinLOpen = engine.chrome.level <= 1
                    ? vpw - dashMonthPanelW(Viewport(w: vpw - engine.gutterShift, h: input.vp.h),
                                            frac: engine.chrome.dashMonthFrac)
                    : vpw - engine.chrome.dashWeekFrac * (vpw - engine.gutterShift - Layout.labelW)
                // dashPresented (not dashPinned): stays true through the ⌘B retract tween, so the
                // slide normalizes against the PINNED edge while the content rides off with it.
                let lOpen = (engine.chrome.level < 3 && engine.chrome.dashPresented) ? pinLOpen : dayLOpen
                let wvW = max(1, vpw - lOpen)
                let slide = min(1, max(0, Double((dashboardLeftAnimated(input) - lOpen) / wvW)))
                // Zoom-scope carousel: pure function of z (mirrors SceneRenderer's scopePair) —
                // the finer scope enters from the LEFT zooming in, returns from the RIGHT out.
                let (sA, sB, sT): (String, String, Double) = input.z >= 2
                    ? ("week", "day", Double(easeInOut(clamp(input.z - 2, 0, 1))))
                    : (input.z >= 1
                        ? ("month", "week", Double(easeInOut(clamp(input.z - 1, 0, 1))))
                        : ("month", "month", 0))
                // Header anchor: the focused band's animated frame (accordion + page-turns) keeps
                // the Canvas header, native tabs, and webview content vertically in lock-step.
                let fHeader = frameFor(input.focus, input, anim: input.monthAnim)
                // The INCOMING month's band frame during a page-turn (tabs ride both headers).
                let fHeader2 = input.monthAnim.map { a in
                    frameFor(input.focus + a.dir, input, anim: input.monthAnim)
                } ?? fHeader
                // The webview's own vertical shift excludes page-turns (its month LAYER carousels
                // those internally) — so compute the accordion-only frame.
                let fRest = frameFor(input.focus, input)
                let (mFrom, mTo, mDir, mP): (String, String, Int, Double) = {
                    guard let a = input.monthAnim else { return (MONTH_LONG[input.focus], "", 0, 0) }
                    let toM = input.focus + a.dir
                    return (MONTH_LONG[input.focus],
                            (0 ... 11).contains(toM) ? MONTH_LONG[toM] : "",
                            a.dir, Double(a.p))
                }()
                // Machine keys for the monthly-note store + content filters ("YYYY-MM").
                let mKeyA = String(format: "%04d-%02d", input.year, input.focus + 1)
                let mKeyB: String = {
                    guard let a = input.monthAnim, (0 ... 11).contains(input.focus + a.dir)
                    else { return "" }
                    return String(format: "%04d-%02d", input.year, input.focus + a.dir + 1)
                }()
                // Week-to-week carousel (weekly dashboard): driven by the continuous week
                // scroll — the SAME function the Canvas week header draws with.
                let wt = weekDashTurn(input)
                // Per-panel geometry from the SAME function the Canvas header draws with
                // (dashScopePanels) — mask + each panel's own (left, width, opacity), converted to
                // the webview's frame-local coordinates (the frame spans the full content region,
                // left edge at labelW, and never moves — no level-boundary snap).
                let scopeGeom = dashScopePanels(input)
                // Native dashboard (webview retirement, cc.nativeDash): ALL tabs of the pinned
                // week/month panel render NATIVELY as REAL carousel members — the flat sub-panel
                // list (dashBodyPanels: scope cross-fades × week-turn slides × month band rides)
                // comes from the geometry layer, the SAME brain the Canvas header draws from, and
                // is applied here as plain frame/offset/opacity. No motion is derived in the view
                // layer, so header and body cannot drift. A DAY panel in the transition pair
                // (week↔day zoom) falls back to the webview wholesale: the day dashboard isn't
                // native yet, and a half-native cross-fade would double-render one side.
                // Native dashboard (cc.nativeDash): the BODY lives in its own hit-testable
                // overlay above the input catcher (nativeDashOverlay — the whole scene here is
                // allowsHitTesting(false)); this scope only decides the webview blanking below.
                let nativeTodo = NativeDash.enabled && scopeGeom != nil
                CarouselDriver(carousel: dashCarousel, anim: dashAnim, from: c.from, to: c.to,
                               dir: c.dir, p: c.p, reveal: c.reveal, slide: slide,
                               scopeA: sA, scopeB: sB, scopeT: sT,
                               headerTopY: Double(fHeader.bandY),
                               headerTopY2: Double(fHeader2.bandY),
                               panelLeft: Double(dashboardLeftAnimated(input) - engine.gutterShift),
                               webDy: Double(fRest.bandY - Layout.topPad),
                               mFrom: mFrom, mTo: mTo, mDir: mDir, mP: mP,
                               // Month-turn PIXEL offsets for the webview sub-panels, relative to the
                               // resting frame (the root already carries the accordion dy): each
                               // sub-panel rides its band's frame EXACTLY — same staggered easing,
                               // same asymmetric travel as the Canvas header. Native is the standard.
                               mDy0: Double(fHeader.bandY - fRest.bandY),
                               mDy1: Double(fHeader2.bandY - fRest.bandY),
                               mKeyA: mKeyA, mKeyB: mKeyB,
                               wFrom: wt.from, wTo: wt.to, wP: Double(wt.p),
                               wKeyA: wt.fromKey, wKeyB: wt.toKey,
                               maskX: Double((scopeGeom?.mask ?? vpw) - Layout.labelW - engine.gutterShift),
                               maskW: Double(vpw - (scopeGeom?.mask ?? vpw)),
                               aName: scopeGeom?.a.name ?? "",
                               aX: Double((scopeGeom?.a.x ?? 0) - Layout.labelW - engine.gutterShift),
                               aW: Double(scopeGeom?.a.w ?? 0),
                               aOp: Double(scopeGeom?.a.op ?? 0),
                               bName: scopeGeom?.b?.name ?? "",
                               bX: Double((scopeGeom?.b?.x ?? 0) - Layout.labelW - engine.gutterShift),
                               bW: Double(scopeGeom?.b?.w ?? 0),
                               bOp: Double(scopeGeom?.b?.op ?? 0),
                               // Drawer canvas-shift (week/month; 0 at day): the webview content rides
                               // the same slide the scene gets via .offset(-drawerShift), so the pinned
                               // panel moves WITH the canvas instead of sitting still under the drawer.
                               shiftX: Double(engine.drawerShift),
                               gutterShiftX: Double(engine.gutterShift),
                               // Month/week level (where ⌘B can present) or presented → keep the
                               // webview technically visible EVEN RETRACTED, so the pin slide
                               // never pays WebKit's unhide full-document repaint mid-animation
                               // (measured 26-35ms web frames at slide start on a todo-heavy
                               // month). Year keeps true hidden (the hover-flicker case); the
                               // hit gate (interactiveLeftX) still keeps clicks off the webview.
                               keepLive: engine.chrome.dashPresented
                                   || engine.chrome.level == 1 || engine.chrome.level == 2,
                               // Blank the WEBVIEW ONLY while the native panels own these tabs;
                               // the native tabs/chrome keep reading the real values via `anim`.
                               webBlank: nativeTodo)
                    .frame(width: 0, height: 0)
            }
        }
        .opacity(input.flipFade) // whole-calendar fade during a year flip
        .blur(radius: ui.openEventId != nil ? 5 : 0) // drawer open → soft-blur behind the scrim
        .offset(x: -engine.drawerShift) // slide left so the drawer item is revealed/centered
    }

    /// A note storage key ("YYYY-MM-DD" / "week:<sunday>" / "month:<YYYY-MM>") → fly to its view
    /// and land on the NOTE tab — the native version of the webview's onJumpDay flow (line focus
    /// inside the editor arrives with the editor's selectLine later).
    private func jumpToNoteKey(_ date: String) {
        if date.hasPrefix("week:") {
            let c = date.dropFirst(5).split(separator: "-").compactMap { Int($0) }
            guard c.count == 3 else { return }
            engine.jumpToWeek(c[0], c[1] - 1, c[2], onLand: { dashTab = .note })
            engine.pinDashboard()
        } else if date.hasPrefix("month:") {
            let c = date.dropFirst(6).split(separator: "-").compactMap { Int($0) }
            guard c.count == 2 else { return }
            engine.jumpToMonth(c[0], c[1] - 1, onLand: { dashTab = .note })
            engine.pinDashboard()
        } else {
            let c = date.split(separator: "-").compactMap { Int($0) }
            guard c.count == 3 else { return }
            engine.jumpToDay(c[0], c[1] - 1, c[2], onLand: { dashTab = .note })
        }
    }

    /// The native dashboard BODY panels for this frame (cc.nativeDash): ONE container framed to
    /// the mask region (scope.mask → right edge) and clipped — the header's clipRect — with each
    /// sub-panel from dashBodyPanels placed by the header's OWN inset math (drawPanelChrome):
    /// content left = panelLeft + 25, right = panelLeft + width − 18, top = the header's bottom
    /// bar (topY + Layout.monthH, dy-anchored to the band frame) + the overlay's 14px gap.
    @ViewBuilder
    private func nativeDashOverlay(theme: Theme) -> some View {
        let input = engine.snapshotInput()
        let bodyPanels = dashBodyPanels(input)
        let c = engine.dashboardCarousel()
        let sg = dashScopePanels(input)
        let liveIds = Set(bodyPanels.map(\.panelId))
        let _ = {
            NativeDash.parkPanels(bodyPanels)
            NativeDash.trimNavRows(dashNav, liveIds: liveIds)
            if let settled = bodyPanels.first(where: { $0.op >= 0.999 && abs($0.dx) < 0.5 }) {
                dashNav.activePanel = settled.panelId // plain per-frame assignment
                // At rest: pre-mount ONE not-yet-parked neighbor per frame (staggered
                // so a landing never pays two mounts in one frame). Invisible (op 0).
                let parkedIds = Set(NativeDash.parkedPanels.map(\.panelId))
                if bodyPanels.count == 1,
                   let n = NativeDash.neighborPanels(of: settled)
                   .first(where: { !parkedIds.contains($0.panelId) }) {
                    NativeDash.parkPanels([n])
                }
            }
            // YEAR level, pinned: no scope panels exist yet, so nothing above pre-builds —
            // and the whole month-panel mount landed INSIDE the year→month zoom (the ~230ms
            // frame at real window sizes). Pre-build the FOCUSED month while resting at year.
            if sg == nil, input.dashPin > 0.5, engine.chrome.level == 0 {
                let key = String(format: "%04d-%02d", input.year, input.focus + 1)
                if !NativeDash.parkedPanels.contains(where: { $0.panelId == "month|" + key }) {
                    NativeDash.parkPanels([DashBodyPanel(
                        scope: "month", key: key, x: input.vp.w,
                        w: dashMonthPanelW(input.vp, frac: input.dashMonthFrac),
                        dx: 0, dy: 0, op: 0)])
                }
            }
        }()
        // STABLE order (sorted by id): the parking LRU re-appends per frame, and a
        // reordered ForEach makes SwiftUI re-layout moved children every frame.
        let parked = NativeDash.parkedPanels.filter { !liveIds.contains($0.panelId) }
            .sorted { $0.panelId < $1.panelId }
        if !bodyPanels.isEmpty || !parked.isEmpty {
            let mask = sg?.mask ?? input.vp.w
            let maskW = max(1, input.vp.w - mask)
            ZStack(alignment: .topLeading) {
                // Identity = scope|key (state never bleeds between keys sharing a list slot);
                // built panels that LEFT the carousel stay mounted, parked at opacity 0
                // (isLive false) — unmounting made every revisit re-pay the full mount (row
                // creation + text layout) on a gesture frame. Every mounted panel renders its
                // REAL content at all times; nothing is ever blanked.
                ForEach(bodyPanels + parked, id: \.panelId) { panel in
                    let isLive = liveIds.contains(panel.panelId)
                    let bx = panel.x + panel.dx + 25 - mask
                    let pw = max(1, panel.w - 25 - 18)
                    let top = Layout.topPad + panel.dy + Layout.monthH + 14
                    let ph = max(1, input.vp.h - top - Layout.bottomPad)
                    NativePanelHost(engine: engine, scope: panel.scope, key: panel.key,
                                    tab: dashTab, theme: theme,
                                    dataStamp: engine.todoDataStamp,
                                    settings: todoSettings,
                                    nav: dashNav, noteMode: $noteMode,
                                    // Event rows open the DRAWER (the web's data-open path);
                                    // note rows fly to their note, landing on the NOTE tab.
                                    onOpen: { id in
                                        guard !NativeDash.tapsSuppressed else { return }
                                        ui.openEventId = sourceId(of: id)
                                    },
                                    onJump: { key in
                                        guard !NativeDash.tapsSuppressed else { return }
                                        jumpToNoteKey(key)
                                    })
                        .equatable() // per-frame re-eval stops HERE; only frame/opacity move
                        .frame(width: pw, height: ph)
                        .position(x: bx + pw / 2, y: top + ph / 2)
                        .opacity(isLive ? Double(panel.op) * Double(c.reveal) : 0)
                        .allowsHitTesting(isLive)
                }
            }
            .frame(width: maskW, height: input.vp.h)
            .clipped()
            .position(x: mask + maskW / 2, y: input.vp.h / 2)
            .offset(x: Layout.padLeft - engine.gutterShift)
        }
    }

    /// The clicked event lifted sharp above the drawer scrim (a second render of just that box).
    @ViewBuilder
    private func liftedBox(sel: String, theme: Theme) -> some View {
        let input = engine.snapshotInput()
        EventsOverlay(input: input, events: engine.viewEvents(), bands: engine.viewBands(),
                      bandBadges: engine.viewBandBadges(), eventBadges: engine.viewEventBadges(),
                      selected: sel, hovered: nil, drawerOpen: true, editingId: nil,
                      draggingId: nil, perfMode: effPerfMode,
                      // The REAL edit generation, like the base overlay — the default (0) froze the
                      // lifted copy on a stale cached layout, so events created after the first
                      // drawer-open of a session never appeared in the lift (they "disappeared"
                      // behind the scrim while the base layer hid them as "drawn by the lift").
                      editGen: engine.displayGen,
                      onlyBox: sel, theme: theme)
            .offset(x: Layout.padLeft - engine.drawerShift - engine.gutterShift)
    }

    /// The clicked DEADLINE lifted sharp above the drawer scrim — its moment line + end dots (Canvas)
    /// and its label pill (SwiftUI), only that one deadline. Same idea as `liftedBox` for band/timed.
    @ViewBuilder
    private func liftedDeadline(sel: String, theme: Theme) -> some View {
        let input = engine.snapshotInput()
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                var c = ctx
                c.translateBy(x: Layout.padLeft - engine.drawerShift - engine.gutterShift, y: 0)
                SceneRenderer.drawMid(input: input, deadlines: engine.viewDeadlines(), selected: sel,
                                      drawerOpen: true, hovered: nil, only: sel, in: &c, theme: theme)
            }
            DeadlinesOverlay(input: input, deadlines: engine.viewDeadlines(), sides: engine.deadlineSides(),
                             selected: sel, hovered: nil, drawerOpen: true, only: sel, theme: theme)
                .offset(x: Layout.padLeft - engine.drawerShift - engine.gutterShift)
        }
    }

    /// One stable `TimelineView`: `paused` just toggles whether it ticks per-frame. The view TYPE is the
    /// same whether awake or idle, so the tree (and the stateful pagers / key monitor hung off it) is
    /// NEVER rebuilt — only the frame schedule stops. Idle-CPU relief comes from breaking the
    /// layout→setViewport→wake feedback loop (see setViewport), not from swapping the view out.
    private func calendarSurface(awake: Bool, vp: Viewport, theme: Theme) -> some View {
        TimelineView(.animation(paused: !awake)) { tl in
            // One evaluation = one rendered frame → the benchmark's frame counter (no-op outside CC_DEMO
            // bench scenes; reads only @ObservationIgnored state, so it can't invalidate the view).
            let _ = demo.benchTick(tl.date)
            calendarScene(engine.sceneInput(at: tl.date, viewport: vp), vp: vp, theme: theme)
        }
    }

    public var body: some View {
        let theme = Theme(dark: scheme == .dark)
        ZStack(alignment: .top) {
            GeometryReader { geo in
                let vp = Viewport(w: geo.size.width - Layout.padLeft - Layout.padRight, h: geo.size.height)
                // Pause the per-frame render loop when idle: reading `awake` (an @Observable bit the engine
                // wakes on any input/animation/edit) here makes SwiftUI re-evaluate and unpause the instant
                // activity resumes. When nothing's moving, the whole-scene 60fps redraw simply stops.
                // Awake → drive the scene per-frame with a TimelineView. Idle → render ONE static frame with
                // no TimelineView at all (see calendarSurface / calendarScene): that's what stops the
                // display-cycle redraw and takes idle CPU to ~0.
                let awake = engine.renderClock.awake
                // Gutter hide (narrow window + pinned week/month dashboard): the SCENE lays out
                // gShift wider and translates left internally (see calendarScene/sceneDX + the
                // CarouselDriver's compensated panel geometry — CSS motion in a fixed webview
                // frame). NOTHING here changes frame per frame; gShift (mirrored through the
                // per-frame observable dashAnim) only feeds the split handle's x.
                let gShift = CGFloat(dashAnim.gutterShift)
                let vpX = Viewport(w: vp.w + gShift, h: vp.h)
                calendarSurface(awake: awake, vp: vp, theme: theme)
                    // The visual layers are purely presentational — never let them intercept
                    // mouse events (the Canvas layers are hit-testable and re-render every
                    // frame, which otherwise steals clicks/drags from the input catcher).
                    // No opaque background: the window is translucent (see CalendarApp),
                    // so the desktop tint shows through.
                    .allowsHitTesting(false)
                    // Invisible month-paging driver, behind everything: an NSScrollView-backed SwiftUI
                    // ScrollView doing native .paging; the catcher forwards month-view scroll into it.
                    .background { MonthPager(engine: engine, bridge: monthBridge) }
                    .background { WeekPager(engine: engine, bridge: weekBridge) }
                    .background { DayPager(engine: engine, bridge: dayBridge) }
                    .overlay(inputCatcher())
                    // Day-view daily dashboard: the TODO list + upcoming deadlines, in a transparent
                    // WebView (reuses the web's tokenizer + sectioning). Sits in the dashboard content
                    // region; shown at day level with the drawer closed (it snaps in — WKWebView doesn't
                    // animate with SwiftUI transitions — so it's gated on level like the split handle).
                    // ALWAYS MOUNTED: the level-≥2 mount gate made every month↔week zoom crossing create
                    // (and destroy) the WKWebView — the pinch-zoom trace attributed ~55ms of each ~90ms
                    // mid-gesture hitch to WebPageProxy creation, right as the week arrival storm lands.
                    // Persistent, the WebView is created ONCE at launch (off any gesture) and just stays
                    // slid out + faded below week level (its CSS slide is already 1 when the driver stops
                    // ticking at z≤1.5, so nothing shows). Hit-testing was already day-level-only.
                    // CC_DASH_UNMOUNT=1 restores the old lazy mount for same-binary A/B benchmarking.
                    // It stays mounted while the drawer is open too — instead of popping out, it fades
                    // aside in CSS (the driver keeps ticking `drawer`). Interactive only at day level
                    // with the drawer closed.
                    .overlay {
                        // Phase 4a step 1: under the native dashboard (the default), the
                        // webview overlay is NOT MOUNTED AT ALL — no web process, no per-frame
                        // CK.tick IPC, no dashboardDataJSON evaluation. The whole branch
                        // survives only for the cc.nativeDashOff fallback.
                        if !NativeDash.enabled, !Self.dashUnmountKill || engine.chrome.level >= 2 {
                            DailyDashboardOverlay(engine: engine, carousel: dashCarousel,
                                                  forwarder: gestureForwarder,
                                                  tab: $dashTab, noteMode: $noteMode,
                                                  // Drawer open → in-page scrim (SwiftUI blur can't reach the
                                                  // WKWebView layer): day view AND the pinned week/month panels.
                                                  inactive: ui.openEventId != nil && (engine.chrome.level == 3
                                                      || (engine.chrome.dashPinned && (1 ... 2).contains(engine.chrome.level))),
                                                  frac: dashFrac, vp: vp,
                                                  containerWidth: geo.size.width, height: geo.size.height, theme: theme,
                                                  onOpen: { ui.openEventId = sourceId(of: $0) },
                                                  onCloseDrawer: { ui.openEventId = nil },
                                                  onNoteExit: { engine.dashNoteExit() },
                                                  onNavTab: { fwd in engine.tabCursor(fwd) },
                                                  todoSettings: todoSettings,
                                                  todoMenu: todoMenu)
                                // Stay hit-testable while the drawer is open so the in-page scrim can intercept +
                                // close (the WKWebView layer ignores the SwiftUI scrim/allowsHitTesting anyway).
                                .allowsHitTesting(engine.chrome.level == 3
                                    || (engine.chrome.dashPinned && (1 ... 2).contains(engine.chrome.level)))
                        }
                    }
                    // Native dashboard BODY (cc.nativeDash): its own overlay ABOVE the input
                    // catcher so scroll/click interactions are real (the scene subtree is
                    // allowsHitTesting(false) wholesale). A second TimelineView on the same
                    // clock reading snapshotInput() — the frame the main loop already computed —
                    // so tweens never double-advance and the body stays in per-frame lockstep
                    // with the Canvas header.
                    .overlay {
                        if NativeDash.enabled {
                            TimelineView(.animation(minimumInterval: nil,
                                                    paused: !engine.renderClock.awake)) { _ in
                                nativeDashOverlay(theme: theme)
                                    // Drawer open: the panels are part of the calendar surface —
                                    // they ride the SAME slide + soft-blur the scene gets (the
                                    // webview rode along via shiftX). INSIDE the per-frame pass:
                                    // drawerShift is an engine tween, so reading it out here
                                    // would sample once per body eval and TELEPORT into place.
                                    .blur(radius: ui.openEventId != nil ? 5 : 0)
                                    .offset(x: -engine.drawerShift)
                            }
                            // Pinch over the native panels must still zoom the CALENDAR (the
                            // webview forwarded magnify to the input catcher; a hit-testable
                            // SwiftUI overlay would swallow it). Feed the exact same engine
                            // call, with the same geometry-space conversion point(e) does.
                            .simultaneousGesture(
                                MagnifyGesture()
                                    .onChanged { v in
                                        let pt = CGPoint(
                                            x: v.startLocation.x - Layout.padLeft
                                                + engine.drawerShift + engine.gutterShift,
                                            y: v.startLocation.y
                                        )
                                        let delta = v.magnification - (dashPinchMag ?? 1)
                                        engine.onMagnify(delta: delta, at: pt,
                                                         began: dashPinchMag == nil, ended: false)
                                        dashPinchMag = v.magnification
                                        NativeDash.lastPinch = Date() // suppress row taps
                                    }
                                    .onEnded { v in
                                        let pt = CGPoint(
                                            x: v.startLocation.x - Layout.padLeft
                                                + engine.drawerShift + engine.gutterShift,
                                            y: v.startLocation.y
                                        )
                                        engine.onMagnify(delta: 0, at: pt, began: false, ended: true)
                                        dashPinchMag = nil
                                        NativeDash.lastPinch = Date() // lift-off click grace
                                    }
                            )
                            .allowsHitTesting(ui.openEventId == nil
                                && (engine.chrome.level == 3
                                    || (engine.chrome.dashPinned
                                        && (1 ... 2).contains(engine.chrome.level))))
                        }
                    }
                    // TODO/NOTE tabs + note edit/preview toggle — SEPARATE overlays ABOVE the WebView so the
                    // hosted WKWebView NSView can't hit-test over the native controls. Tabs carousel via dashAnim.
                    .overlay {
                        if ui.openEventId == nil {
                            DashTabsOverlay(engine: engine, anim: dashAnim, tab: $dashTab, frac: dashFrac, vp: vp,
                                            containerWidth: geo.size.width, theme: theme)
                        }
                    }
                    .overlay {
                        if ui.openEventId == nil {
                            NoteModeToggleOverlay(engine: engine, anim: dashAnim, tab: dashTab, noteMode: $noteMode,
                                                  containerWidth: geo.size.width, height: geo.size.height, theme: theme)
                        }
                    }
                    // TODO layering cog (bottom-right on the TODO tab) → the native callout menu.
                    .overlay {
                        if ui.openEventId == nil {
                            TodoCogOverlay(engine: engine, anim: dashAnim, tab: dashTab, controller: todoMenu,
                                           containerWidth: geo.size.width, height: geo.size.height, theme: theme)
                        }
                    }
                    // Day-view split handle: drag the timeline↔dashboard boundary to resize. Above the catcher
                    // so it grabs the mouse in its narrow zone (the rest passes through). Shown in day view;
                    // reads chrome.level (@Observable) so it appears/disappears as you zoom.
                    .overlay {
                        if engine.chrome.level == 3
                            || (engine.chrome.dashPinned && (1 ... 2).contains(engine.chrome.level)),
                            ui.openEventId == nil {
                            DashboardSplitHandle(engine: engine, vp: vpX, gutterShift: gShift,
                                                 height: geo.size.height, theme: theme,
                                                 onFrac: { dashFrac = $0 })
                        }
                    }
                    // Timeline scale bar (week + day views): the video-editor thumb on the leftmost day's
                    // left border — drag the body to scroll, drag an end circle to rescale the hour height.
                    // Wrapped in the per-frame TimelineView (like liftedBox): tlScroll/hourH are hot,
                    // observation-ignored fields, so the thumb must re-read geometry every frame to track
                    // scrolling and its own drags.
                    .overlay {
                        if engine.chrome.level >= 2, ui.openEventId == nil {
                            TimelineView(.animation(paused: !awake)) { ctx in
                                // ctx.date passes through as `tick` so the bar's body re-evaluates every
                                // frame (equal inputs would be diff-skipped, freezing the thumb).
                                TimelineScaleBar(engine: engine, theme: theme, tick: ctx.date)
                            }
                        }
                    }
                    // inline track-name editor
                    .overlay {
                        if let te = ui.editingTrack {
                            TrackNameEditor(engine: engine, target: te, theme: theme,
                                            onDone: {
                                                ui.editingTrack = nil; engine.trackEditing = false; refocusCatcher()
                                            })
                        }
                    }
                    // inline band-title editor
                    .overlay {
                        if let be = ui.editingBand {
                            BandTitleEditor(engine: engine, target: be, theme: theme,
                                            onDone: {
                                                ui.editingBand = nil; engine.bandEditing = false; refocusCatcher()
                                            })
                        }
                    }
                    // inline timed-event-title editor (keyboard "Enter → edit title", or click-a-selected-event)
                    .overlay {
                        if let te = ui.editingTimed {
                            TimedTitleEditor(engine: engine, target: te, theme: theme,
                                             onDone: {
                                                 ui.editingTimed = nil; engine.timedEditing = false; refocusCatcher()
                                             })
                        }
                    }
                    // 4a. scrim — blocks the canvas + closes on outside-click (fades). Light dim; the blur behind
                    // it carries most of the "inactive" cue.
                    .overlay {
                        if ui.openEventId != nil {
                            Rectangle()
                                .fill(.black.opacity(0.12))
                                .contentShape(Rectangle())
                                .onTapGesture { ui.openEventId = nil }
                                .transition(.opacity)
                        }
                    }
                    // 4a′. the clicked event, LIFTED sharp above the scrim so the user sees what they're focused
                    // on. A second render of the events with `onlyBox` = the selected box: everything packs as
                    // usual (exact position) but only that box draws, un-blurred. Reads the same frame the main
                    // TimelineView computed (snapshotInput — no double tween-advance) + the live drawer shift.
                    .overlay {
                        if ui.openEventId != nil, let sel = engine.selectedId {
                            TimelineView(.animation(paused: !awake)) { _ in liftedBox(sel: sel, theme: theme) }
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                    // 4a″. …and the lifted DEADLINE (moment line + dots + tag), sharp above the scrim too.
                    .overlay {
                        if ui.openEventId != nil, let sel = engine.selectedId {
                            TimelineView(.animation(paused: !awake)) { _ in liftedDeadline(sel: sel, theme: theme) }
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                    // 4b. the drawer panel — slides in from the trailing edge
                    .overlay(alignment: .trailing) {
                        if let id = ui.openEventId {
                            EventDrawer(
                                engine: engine,
                                id: id,
                                width: $drawerWidth,
                                containerWidth: geo.size.width,
                                theme: theme,
                                onClose: { ui.openEventId = nil },
                                ui: ui,
                                refocus: { refocusCatcher() },
                                demoNoteFeed: demo.noteFeed,
                                demoNotePreview: demo.notePreview,
                                demoConfigOpen: demo.configPulse,
                                demoRepeatFeed: demo.repeatFeed
                            )
                            .allowsHitTesting(!drawerSettling) // see drawerSettling
                            .transition(.move(edge: .trailing))
                        }
                    }
                    .animation(.easeOut(duration: 0.26), value: ui.openEventId)
                    // Cmd+K shortcut guide — held-open overlay showing the current state's keys (fades in/out).
                    // Also opened (latched) by Help → Keyboard Shortcuts; a tap anywhere dismisses it (the ⌘K
                    // hold path releases on keyUp as before, so the tap layer is only the exit for the latched case).
                    .overlay {
                        if ui.showKeyGuide {
                            ZStack {
                                Color.black.opacity(0.001).contentShape(Rectangle())
                                    .onTapGesture { ui.showKeyGuide = false; engine.wake() }
                                KeyGuideOverlay(model: KeyboardModel(engine: engine, ui: ui), theme: theme)
                            }
                            .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.15), value: ui.showKeyGuide)
                    .onReceive(NotificationCenter.default.publisher(for: .showKeyboardShortcuts)) { _ in
                        ui.showKeyGuide = true; engine.wake()
                    }
                    // Blocking-modal overlays (delete-confirm dialog + onboarding tutorial) bundled into one
                    // modifier so the body's modifier chain stays within the type-checker's budget.
                    .modifier(modalOverlays(theme: theme))
                    // ai-assistant recording scene: a staged, offline chat panel in the main window (the real
                    // assistant is a separate window the recorder can't frame). No-op outside that scene.
                    .overlay(alignment: .topTrailing) {
                        if demo.showAssistantPanel, let a = demo.assistant {
                            AssistantCalloutView(state: a, onOpenWindow: {})
                                .background(
                                    .regularMaterial,
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(.white.opacity(0.12)))
                                .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                                .padding(.top, 48)
                                .padding(.trailing, 14) // clear the toolbar (full-size content window)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        if !demo.cursorPanelUp { DemoCursorOverlay(demo: demo) }
                    } // synthetic pointer during a GIF recording (panel-hosted when possible; no-op otherwise)
                    // Live frame-rate HUD (Settings ▸ Developer, or CC_FPS_HUD=1) — measures THIS run,
                    // whatever it is: Xcode-attached, standalone, or the signed app. Reads the render
                    // loop's own tick. @AppStorage so the Settings toggle applies live.
                    .overlay(alignment: .bottomLeading) {
                        if fpsHUDPref || DemoController.hudEnabled {
                            FPSHUD(demo: demo)
                        }
                    }
                    .onAppear { setupOnAppear(size: geo.size) }
                    .onChange(of: geo.size) { _, s in engine.setViewport(s) }
                    .onChange(of: ui.openEventId) { old, v in
                        engine.drawerOpen = v != nil
                        engine.chrome.drawerOpen = v != nil
                        if v != nil, old == nil { // opening: let the slide-in own the mouse
                            drawerSettling = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { drawerSettling = false }
                        }
                        if let id = v {
                            engine.onHoverExit() // clear any lingering highlight now
                            engine.openDrawerShift(id: id, drawerWidth: drawerWidth)
                            NSCursor.arrow.set() // reset a stale hover cursor; SwiftUI takes over while open
                            // Keep the canvas as first responder while the drawer is open (no field focused), so its
                            // keys work — e.g. Space to close. (The notes WebView no longer steals focus; this covers
                            // any other control the appearing overlay might grab.)
                            if ui.drawerFocus == nil {
                                refocusCatcher()
                            }
                        } else {
                            ui.drawerFocus = nil
                            engine.closeDrawerShift()
                            refocusCatcher() // drawer closed → canvas keeps the keys (so Space re-opens it)
                        }
                    }
                    .onChange(of: drawerWidth) { _, w in
                        if let id = ui.openEventId {
                            engine.updateDrawerShift(id: id, drawerWidth: w)
                        }
                    }
                    // WEBVIEW FALLBACK only: leaving day view snapped the dashboard back to the
                    // TODO tab (the zoom-out reveal was driven by the TODO WebView). Native
                    // panels keep the active tab CONSISTENT across level changes — week PROJ
                    // zooms out to month PROJ, and so on for every tab/zoom/slide; note-jumps
                    // still flip to NOTE via their onLand, after the navigation animation.
                    .onChange(of: engine.chrome.level) {
                        _, lvl in if lvl != 3, !NativeDash.enabled {
                            dashTab = .todo
                        }
                    }
                    // The dashboard tab/mode toggles are SwiftUI overlays (not routed through the engine), and
                    // their transition animates via the timeline's CarouselDriver — so wake the render loop when
                    // they change, else the switch would freeze while the calendar is idle.
                    .onChange(of: dashTab) { _, _ in engine.wake() }
                    .onChange(of: noteMode) { _, _ in engine.wake() }
                    // Apple Calendar import: pull on first appearance, whenever the app returns to the foreground
                    // (auto-refresh), and when the Settings window changes the connection.
                    .onAppear {
                        engine.icsFeedURLs = { ICSFeeds.list() } // engine-triggered refreshes (Sync Now)
                        engine.importAppleCalendar()
                        engine.importICSFeeds(urls: ICSFeeds.list())
                    }
                    .onReceive(NotificationCenter.default
                        .publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                            engine.importAppleCalendar()
                            engine.importICSFeeds(urls: ICSFeeds.list())
                            engine.syncNow() // also pull/push iCloud on foreground (was never wired before)
                    }
                    // Settings changed the ICS feed list (add/remove) → re-import right away.
                    .onReceive(NotificationCenter.default.publisher(for: .icsFeedsChanged)) { _ in
                        engine.importICSFeeds(urls: ICSFeeds.list())
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .appleCalendarSettingsChanged)) { _ in
                        engine.importAppleCalendar()
                    }
                    // View-menu prefs (show-hidden / timezone pickers), the prefs-changed notification, and
                    // the tag-filter toggle — bundled into one modifier (see the type-check note above).
                    .modifier(ViewPrefObservers(engine: engine, showTagFilter: $showTagFilter,
                                                ui: ui, dashTab: $dashTab, carousel: dashCarousel))
            }
            .ignoresSafeArea()
            // Search overlays — siblings inside the ZStack, so they respect the toolbar safe-area inset
            // (the dropdown lands just BELOW the toolbar) while the calendar above stays full-bleed. The
            // dropdown is right-aligned under the (trailing) search field and styled like the drawer.
            if search.open {
                Color.black.opacity(0.001).contentShape(Rectangle()) // click-outside closes search
                    .onTapGesture { closeSearch() }
            }
            if search.open, !search.query.isEmpty {
                // Pin the dropdown's top-left to the search bar's bottom-left. Both frames are measured in
                // the window's content-view space (WindowRectReader), so subtracting this stack's origin
                // gives the local offset — aligning across the toolbar↔content hierarchy boundary.
                Color.clear
                    .background(WindowRectReader { searchAnchor = $0.origin })
                    .overlay(alignment: .topLeading) {
                        SearchDropdown(search: search, theme: theme, onPick: { search.sel = $0; commitSearch() })
                            .fixedSize(horizontal: false, vertical: true)
                            .offset(x: search.fieldFrame.minX - searchAnchor.x,
                                    y: search.fieldFrame.maxY - searchAnchor.y + 3)
                    }
                    .transition(.opacity)
            }
        } // ZStack
        .animation(.easeOut(duration: 0.12), value: search.query.isEmpty)
        .toolbar { mainToolbar }
        // Let the translucent window material show through the toolbar (native tint).
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // Full screen: hide the toolbar entirely (full-bleed calendar); it slides in with the
        // menu bar when the mouse reaches the top, Safari-style.
        .windowToolbarFullScreenVisibility(.onHover)
        // …and re-assert transparency across fullscreen transitions, where AppKit re-applies its
        // own toolbar backdrop that the SwiftUI modifier doesn't reach (see TransparentTitlebar).
        .background(TransparentTitlebar())
        // Publish the quick-ask callout binding for the app's ⌘I command: calendar window key →
        // ⌘I toggles the callout; no calendar window → the command falls back to the full window.
        .focusedSceneValue(\.assistantCallout, $showAssistantCallout)
    }

    /// The window toolbar. Extracted to a builder so the type-checker doesn't choke on the whole body,
    /// and so the search field can swap in for the magnifyingglass button (expanding from it) when open.
    @ToolbarContentBuilder
    private var mainToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) { Breadcrumb(engine: engine) }
        ToolbarSpacer(.flexible)
        ToolbarItem(placement: .primaryAction) {
            if search.open {
                SearchBar(engine: engine, search: search,
                          onCommit: { commitSearch() }, onClose: { closeSearch() })
            } else {
                Button { openSearch() } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.glass).buttonBorderShape(.circle).help("Search (⌘F)")
            }
        }
        ToolbarSpacer(.fixed)
        ToolbarItem(placement: .primaryAction) {
            // With a shared assistant: a quick-ask CALLOUT anchored to this button (an NSPopover —
            // caret + glass, may extend beyond the window). Without one (dev shell): the window.
            Button {
                if assistant != nil {
                    showAssistantCallout.toggle()
                } else {
                    openWindow(id: "assistant")
                }
            } label: { Image(systemName: "sparkles") }
                .buttonStyle(.glass).buttonBorderShape(.circle).help("MagiCal AI (⌘I)")
                .popover(isPresented: $showAssistantCallout, arrowEdge: .bottom) {
                    if let assistant {
                        AssistantCalloutView(state: assistant) {
                            // Hand the callout's thread to the window: flush it to the store,
                            // point the window's session at it, close the callout, open the window.
                            showAssistantCallout = false
                            assistant.persistNow()
                            if let id = assistant.currentId {
                                windowAssistant?.selectConversation(id)
                            }
                            openWindow(id: "assistant")
                        }
                        // Publish from INSIDE the popover too, so ⌘I still toggles (closes) while
                        // the popover itself holds keyboard focus.
                        .focusedSceneValue(\.assistantCallout, $showAssistantCallout)
                    }
                }
        }
        ToolbarSpacer(.fixed)
        ToolbarItem(placement: .primaryAction) {
            // View ▸ Filter by Tags lives here as a stay-open checklist popover (a menu can't stay open
            // while multi-toggling). The View-menu item in both shells toggles it via .toggleTagFilter.
            Button { showTagFilter.toggle() } label: { Image(systemName: "tag") }
                .buttonStyle(.glass).buttonBorderShape(.circle).help("Filter by Tags (⌘G)")
                .popover(isPresented: $showTagFilter, arrowEdge: .bottom) {
                    TagFilterPopover(engine: engine)
                }
        }
        ToolbarSpacer(.fixed)
        ToolbarItem(placement: .primaryAction) {
            Button { engine.goToToday() } label: { Text("Today") }
                .buttonStyle(.glass).buttonBorderShape(.capsule)
                .help("Go to today (⌘T)")
        }
    }
}

/// The View-menu preference observers, bundled so CalendarView's body modifier chain stays within the
/// Swift type-checker's budget (see swift-typecheck-cliff). Each @AppStorage mirrors the UserDefaults key
/// its menu control writes; the notifications catch the AppKit dev-shell menu's direct writes.
private struct ViewPrefObservers: ViewModifier {
    let engine: CalendarEngine
    @Binding var showTagFilter: Bool
    var ui: CalendarUIState
    @Binding var dashTab: DashTab
    var carousel: DashboardCarousel
    @AppStorage(PrefKeys.showHiddenImported) private var showHidden = false
    @AppStorage(PrefKeys.mainTz) private var mainTz = "auto"
    @AppStorage(PrefKeys.altTz) private var altTz = "none"
    func body(content: Content) -> some View {
        content
            .onChange(of: showHidden) { _, _ in engine.viewPrefsChanged() }   // Show Hidden Imported Events
            .onChange(of: mainTz) { _, _ in engine.viewPrefsChanged() }        // Current Timezone picker
            .onChange(of: altTz) { _, _ in engine.viewPrefsChanged() }         // Alternative Timezone picker
            .onReceive(NotificationCenter.default.publisher(for: .calendarViewPrefsChanged)) { _ in
                engine.viewPrefsChanged()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleTagFilter)) { _ in
                showTagFilter.toggle()   // View ▸ Filter by Tags (menu item, either shell)
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusDashTodo)) { _ in
                dashHotkey(.todo)        // View ▸ TODO List (⌘B)
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusDashNote)) { _ in
                dashHotkey(.note)        // View ▸ Note Editor (⌘E)
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusDashProj)) { _ in
                dashHotkey(.proj)        // View ▸ Projects (⌘J)
            }
    }

    /// ⌘B / ⌘E / ⌘J — faces of one coin: focus the dashboard's TODO / NOTE / PROJ tab.
    /// Day view: switch + keyboard-focus the tab (⌘E lands in the markdown editor; PROJ has no
    /// keyboard stop yet, so ⌘J drops any TODO/NOTE ring and hands keys to the calendar).
    /// Month/week: closed → open the panel on that tab; open on another tab → flip to it;
    /// already open on that tab → retract the panel. No-op at year or under the drawer.
    private func dashHotkey(_ stop: DashTab) {
        guard ui.openEventId == nil else { return }
        switch engine.chrome.level {
        case 3:
            dashTab = stop
            switch stop {
            case .todo: engine.dashFocusEntry(.todo)
            case .note: engine.dashFocusEntry(.note)
            case .proj:
                engine.dashExitFocus()
                carousel.regateWebFocus()
            }
        case 1, 2:
            if !engine.dashPinned {
                engine.toggleDashPin()
                dashTab = stop
                focusWeekMonthTab(stop)
                if stop == .todo, NativeDash.enabled { engine.dashFocusEntry(.todo) }
            } else if dashTab != stop {
                dashTab = stop
                focusWeekMonthTab(stop)
                if stop == .todo, NativeDash.enabled { engine.dashFocusEntry(.todo) }
                engine.wake()
            } else {
                engine.toggleDashPin() // already on that tab → retract
                if NativeDash.enabled { engine.dashExitFocus() }
                carousel.regateWebFocus()
            }
        default:
            break
        }
    }

    /// Week/month landing focus: ⌘E puts the caret in the live note editor (CK.noteEdit retries
    /// until the overlay is revealed, so this works through the opening tween); ⌘B hands key
    /// focus back to the calendar (the web view must not keep eating keys).
    private func focusWeekMonthTab(_ stop: DashTab) {
        if stop == .note {
            carousel.focusNoteEditor()
        } else {
            carousel.regateWebFocus()
        }
    }
}
