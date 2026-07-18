// The calendar surface: a per-frame Canvas driven by TimelineView(.animation),
// with an AppKit input bridge overlay for scroll-wheel / pinch / click / hover.

import SwiftUI
import CalendarGeometry
import CalendarEngine

public struct CalendarView: View {
    @State private var engine = CalendarEngine()
    @State private var ui = CalendarUIState()
    @State private var drawerWidth: CGFloat = 410
    @State private var monthBridge = MonthPagerBridge()
    @State private var weekBridge = WeekPagerBridge()
    @State private var dayBridge = DayPagerBridge()
    @State private var dashCarousel = DashboardCarousel()
    @State private var dashAnim = DashCarouselAnim()           // per-frame carousel state for the native tabs
    @State private var gestureForwarder = GestureForwarder()   // dashboard → catcher (horiz scroll + pinch)
    @State private var dashFrac: CGFloat = 0.45   // mirrors engine.daily.frac; updated live on resize
    @State private var dashTab: DashTab = .todo   // dashboard TODO/NOTE tab
    @State private var demo = DemoController()    // scripted GIF-recording cursor + scenes (CC_DEMO mode)
    @State private var noteMode: NotesMode = .edit // daily-note edit/preview (native toggle mirrors JS)
    @State private var search = SearchState()      // toolbar event search (⌘F / magnifyingglass)
    @State private var searchAnchor: CGPoint = .zero   // content stack's window-space origin (for dropdown alignment)
    @State private var searchCloseWork: DispatchWorkItem?   // pending "unmount the bar after it collapses"
    // Global Performance Mode: render events as flat tinted fills instead of Liquid Glass
    // (glass is one GPU pass per sticker). Persisted; defaults on for now.
    @AppStorage("cc.performanceMode") private var perfMode = true
    // View ▸ Show Hidden Imported Events. @AppStorage tracks the same UserDefaults key the menu toggles;
    // the onChange below repaints the calendar when it flips (from either app target's menu).
    @AppStorage(CalendarEngine.showHiddenImportedKey) private var showHiddenImported = false
    @AppStorage(CalendarEngine.mainTzKey) private var mainTzPref = "auto"   // View ▸ Current Timezone
    @AppStorage(CalendarEngine.altTzKey) private var altTzPref = "none"     // View ▸ Alternative Timezone
    @AppStorage("cc.tutorial.seen") private var tutorialSeen = false   // auto-show the onboarding carousel once
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openWindow) private var openWindow    // opens the standalone Calendar AI window
    // The quick-ask callout's OWN assistant session (app-level; independent of the standalone
    // window's session, sharing only the conversation store). nil (dev shell) → window only.
    private let assistant: AssistantState?
    // The standalone window's session — "Open in window" hands the callout's thread to it.
    private let windowAssistant: AssistantState?
    @State private var showAssistantCallout = false

    /// Inject a shared engine so another scene (the standalone Calendar AI window) can read the
    /// same live calendar state. Defaults to a fresh engine when hosted standalone.
    @MainActor public init(engine: CalendarEngine? = nil, assistant: AssistantState? = nil,
                           windowAssistant: AssistantState? = nil) {
        _engine = State(initialValue: engine ?? CalendarEngine())
        self.assistant = assistant
        self.windowAssistant = windowAssistant
    }

    /// After an inline editor (title / track name) commits, its text field was first responder; return
    /// first-responder to the calendar canvas so keyboard shortcuts keep working (e.g. Enter → edit
    /// title → Enter → back to selected → Enter → edit again). Deferred so it runs after the field is
    /// torn down. `gestureForwarder.catcher` is the live CatcherView (set by the InputCatcher).
    private func refocusCatcher() {
        DispatchQueue.main.async {
            if let c = gestureForwarder.catcher { c.window?.makeFirstResponder(c) }
        }
    }

    // ── Delete-confirm dialog ─────────────────────────────────────────────────────
    /// Carry out a chosen scope, then dismiss the dialog (and the drawer, on an actual delete).
    private func performDelete(_ choice: DeleteChoice) {
        guard let pd = ui.pendingDelete else { return }
        switch choice {
        case .cancel:        break
        case .thisEvent:     engine.deleteOccurrence(pd.id, pd.occKey)
        case .thisAndFuture: engine.deleteFuture(pd.id, pd.occKey)
        case .deleteAll:     engine.remove(pd.id)
        case .hide:          engine.hideImportedSeries(pd.id)   // imported → hide (can't truly delete)
        }
        ui.pendingDelete = nil
        if !choice.isCancel { ui.openEventId = nil }   // event gone → close its drawer if open
        refocusCatcher()                               // keys go back to the calendar
        engine.wake()
    }
    /// The key monitor's ←/→/Enter/Esc while the dialog is up.
    private func handleDeleteDialogKey(_ key: DeleteDialogKey) {
        guard let pd = ui.pendingDelete else { return }
        switch key {
        case .left:    ui.moveDeleteFocus(-1)
        case .right:   ui.moveDeleteFocus(1)
        case .cancel:  performDelete(.cancel)
        case .confirm: performDelete(pd.choices[pd.focus ?? pd.primaryIndex])
        }
        engine.wake()
    }
    /// One-time wiring on the calendar's first appearance. Extracted from `body` so the view's long
    /// modifier chain stays within the Swift type-checker's budget.
    private func setupOnAppear(size: CGSize) {
        WindowBeepSilencer.installOnce()   // stop the window beeping on keys the calendar leaves unhandled
        if CalendarEngine.isDemoMode { demo.startIfDemo(engine: engine, size: size) }   // GIF recording session
        else if !tutorialSeen { tutorialSeen = true; ui.tutorialIndex = 0; ui.showTutorial = true }   // first launch
        engine.setViewport(size)
        dashFrac = engine.daily.frac
        engine.onEditBand = { id, rect in engine.bandEditing = true; ui.editingBand = BandEdit(id: id, rect: rect) }
        engine.onEditTimed = { id, rect in engine.timedEditing = true; ui.editingTimed = TimedEdit(id: id, rect: rect) }
        engine.onEditTrackName = { m, t, rect in engine.trackEditing = true; ui.editingTrack = TrackEdit(month: m, track: t, rect: rect) }
        engine.onRequestOpenDrawer = { id, selectTitle in ui.openEventId = id; ui.selectTitleOnOpen = selectTitle }
        // An external data change removed the item a drawer / delete-dialog / inline editor was showing
        // (e.g. deleted in Apple Calendar, then re-imported on foreground) → dismiss it.
        engine.onExternalDataChange = { [engine] in
            if let id = ui.openEventId, !engine.itemExists(id) { ui.openEventId = nil }
            if let pd = ui.pendingDelete, !engine.itemExists(pd.id) { ui.pendingDelete = nil; engine.inputModalUp = false }
            if let te = ui.editingTimed, !engine.itemExists(sourceId(of: te.id)) { ui.editingTimed = nil; engine.timedEditing = false }
            if let be = ui.editingBand, !engine.itemExists(sourceId(of: be.id)) { ui.editingBand = nil; engine.bandEditing = false }
        }
        // Day-view dashboard Tab stops (TODO / NOTE): the engine's keyboard system drives the WebView's row
        // cursor + note-editor focus through this bridge, and switches the native TODO/NOTE tab to match.
        engine.onDashCommand = { [carousel = dashCarousel, tabBinding = $dashTab, engine] cmd in
            switch cmd {
            case .focus(let stop):
                if stop == .todo { tabBinding.wrappedValue = .todo }
                else if stop == .note { tabBinding.wrappedValue = .note }
                carousel.navFocus(stop)
            case .move(let d): carousel.navMove(d)
            case .activate:   // Space/Enter: note → focus the editor; todo → toggle the row
                if engine.dashStop == .note { carousel.focusNoteEditor() } else { carousel.navActivate() }
            case .open: carousel.navOpen()
            }
            engine.wake()
        }
    }

    /// The key monitor's ←/→/Enter/Esc while the tutorial carousel is up.
    private func handleTutorialKey(_ key: DeleteDialogKey) {
        let last = TutorialView.slides.count - 1
        switch key {
        case .left:    ui.tutorialIndex = max(0, ui.tutorialIndex - 1)
        case .right:   ui.tutorialIndex = min(last, ui.tutorialIndex + 1)
        case .confirm: if ui.tutorialIndex >= last { ui.showTutorial = false } else { ui.tutorialIndex += 1 }
        case .cancel:  ui.showTutorial = false
        }
        engine.wake()
    }

    // ── Toolbar search ───────────────────────────────────────────────────────────────
    private func openSearch() {
        engine.wake()
        searchCloseWork?.cancel(); searchCloseWork = nil   // cancel a pending collapse (re-open mid-close)
        if search.open {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { search.expanded = true }   // re-expand
        } else {
            search.open = true   // mounts the bar; its onAppear animates the expand from the button
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
    @ViewBuilder
    private func calendarScene(_ input: SceneInput, vp: Viewport, theme: Theme) -> some View {
        ZStack {
            // 1. scene below events — clipped to the content area
            Canvas { ctx, size in
                var c = ctx
                c.translateBy(x: Layout.padLeft, y: 0)
                SceneRenderer.drawBelow(input: input, in: &c, theme: theme)
            }
            // 2. events (bands + timed), Liquid Glass stickers
            EventsOverlay(input: input, events: engine.viewEvents(), bands: engine.viewBands(),
                          bandBadges: engine.viewBandBadges(), eventBadges: engine.viewEventBadges(),
                          selected: engine.selectedId, hovered: engine.hoveredEventId,
                          drawerOpen: ui.openEventId != nil, editingId: ui.editingBand?.id ?? ui.editingTimed?.id,
                          draggingId: engine.activeTimedDragId,
                          perfMode: perfMode,
                          hideBox: ui.openEventId != nil ? engine.selectedId : nil,  // lifted sharp above
                          theme: theme)
                .offset(x: Layout.padLeft)
            // 3. deadlines: the moment line + dots are drawn in the Canvas… When the drawer is open the
            // SELECTED deadline is HIDDEN here (drawn sharp in the lift below, like band/timed events).
            let liftDdl = ui.openEventId != nil ? engine.selectedId : nil
            Canvas { ctx, size in
                var c = ctx
                c.translateBy(x: Layout.padLeft, y: 0)
                SceneRenderer.drawMid(input: input, deadlines: engine.viewDeadlines(), selected: engine.selectedId, drawerOpen: ui.openEventId != nil, hovered: engine.hoveredEventId, hide: liftDdl, in: &c, theme: theme)
            }
            // …and the labels are SwiftUI glass pills (activation styling), above the line.
            DeadlinesOverlay(input: input, deadlines: engine.viewDeadlines(),
                             sides: engine.deadlineSides(),
                             selected: engine.selectedId, hovered: engine.hoveredEventId,
                             drawerOpen: ui.openEventId != nil, hide: liftDdl, theme: theme)
                .offset(x: Layout.padLeft)
            // 4. chrome on top of the glass: gutter labels/borders, track names, now-line/cursor, dashboard title
            Canvas { ctx, size in
                var c = ctx
                c.translateBy(x: Layout.padLeft, y: 0)
                SceneRenderer.drawAbove(input: input, tracks: engine.trackNames,
                                        hideTrack: ui.editingTrack.map { ($0.month, $0.track) }, in: &c, theme: theme)
            }
            // Keyboard-navigation cursor (dashed sliding ring).
            CursorRing(rect: engine.blockCursorRect(), theme: theme, cornerRadius: 6,
                       geometryAnimating: engine.isAnimating)
                .offset(x: Layout.padLeft)
            // Band cursor: a dashed cell over one lane × one day.
            CursorRing(rect: engine.bandCursorRect(), theme: theme, cornerRadius: 4,
                       geometryAnimating: engine.isAnimating)
                .offset(x: Layout.padLeft)
            // Track-name cursor (month view's extra Tab stops): a dashed cell over the gutter name slot.
            CursorRing(rect: engine.trackNameCursorRect(), theme: theme, cornerRadius: 4,
                       geometryAnimating: engine.isAnimating)
                .offset(x: Layout.padLeft)
            // Event cursor: dashed ring around the SELECTED event box (keyboard mode).
            CursorRing(rect: engine.selectionRingRect().map { $0.insetBy(dx: -2, dy: -2) },
                       theme: theme, cornerRadius: 8, geometryAnimating: engine.isAnimating)
                .offset(x: Layout.padLeft)
            // Deadline quick-add "+" — a small circle on the hovered day column's left edge at the nearest
            // hour line (week/day view). Visual only (the whole scene is non-hit-testing); the click is
            // caught by the InputCatcher → onPointerDown → deadlineAddSpot. Hidden while the drawer is open.
            if ui.openEventId == nil, let spot = engine.deadlineAddSpot(input) {
                DeadlineAddButton(theme: theme, hovering: spot.hovering)
                    .position(x: spot.x, y: spot.y)
                    .offset(x: Layout.padLeft)
            }
            // Per-frame day-carousel driver for the dashboard WebView (invisible). Carries {from,to,dir,p}
            // for day paging and `reveal` for the panel's slide-in-from-right + fade. Week level up.
            if input.z > 1.5 {
                let c = engine.dashboardCarousel()
                let lOpen = Layout.labelW + dashFrac * max(1, vp.w - Layout.labelW)
                let wvW = max(1, vp.w - lOpen)
                let slide = min(1, max(0, Double((dashboardLeftAnimated(input) - lOpen) / wvW)))
                CarouselDriver(carousel: dashCarousel, anim: dashAnim, from: c.from, to: c.to,
                               dir: c.dir, p: c.p, reveal: c.reveal, slide: slide)
                    .frame(width: 0, height: 0)
            }
        }
        .opacity(input.flipFade)   // whole-calendar fade during a year flip
        .blur(radius: ui.openEventId != nil ? 5 : 0)   // drawer open → soft-blur behind the scrim
        .offset(x: -engine.drawerShift)   // slide left so the drawer item is revealed/centered
    }

    /// The clicked event lifted sharp above the drawer scrim (a second render of just that box).
    @ViewBuilder
    private func liftedBox(sel: String, theme: Theme) -> some View {
        let input = engine.snapshotInput()
        EventsOverlay(input: input, events: engine.viewEvents(), bands: engine.viewBands(),
                      bandBadges: engine.viewBandBadges(), eventBadges: engine.viewEventBadges(),
                      selected: sel, hovered: nil, drawerOpen: true, editingId: nil,
                      draggingId: nil, perfMode: perfMode, onlyBox: sel, theme: theme)
            .offset(x: Layout.padLeft - engine.drawerShift)
    }

    /// The clicked DEADLINE lifted sharp above the drawer scrim — its moment line + end dots (Canvas)
    /// and its label pill (SwiftUI), only that one deadline. Same idea as `liftedBox` for band/timed.
    @ViewBuilder
    private func liftedDeadline(sel: String, theme: Theme) -> some View {
        let input = engine.snapshotInput()
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                var c = ctx
                c.translateBy(x: Layout.padLeft - engine.drawerShift, y: 0)
                SceneRenderer.drawMid(input: input, deadlines: engine.viewDeadlines(), selected: sel,
                                      drawerOpen: true, hovered: nil, only: sel, in: &c, theme: theme)
            }
            DeadlinesOverlay(input: input, deadlines: engine.viewDeadlines(), sides: engine.deadlineSides(),
                             selected: sel, hovered: nil, drawerOpen: true, only: sel, theme: theme)
                .offset(x: Layout.padLeft - engine.drawerShift)
        }
    }

    /// One stable `TimelineView`: `paused` just toggles whether it ticks per-frame. The view TYPE is the
    /// same whether awake or idle, so the tree (and the stateful pagers / key monitor hung off it) is
    /// NEVER rebuilt — only the frame schedule stops. Idle-CPU relief comes from breaking the
    /// layout→setViewport→wake feedback loop (see setViewport), not from swapping the view out.
    @ViewBuilder
    private func calendarSurface(awake: Bool, vp: Viewport, theme: Theme) -> some View {
        TimelineView(.animation(paused: !awake)) { tl in
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
            .overlay(InputCatcher(engine: engine, monthBridge: monthBridge, weekBridge: weekBridge, dayBridge: dayBridge,
                                  forwarder: gestureForwarder,
                                  onOpenEvent: { ui.openEventId = $0 },
                                  onEditTrack: { te in engine.trackEditing = true; ui.editingTrack = te },
                                  // The keyboard state machine + the Cmd+K guide toggle. `onKey` reads
                                  // live engine/ui state each press; returns whether it consumed the key.
                                  onKey: { KeyboardModel(engine: engine, ui: ui).handle($0) },
                                  onKeyGuide: { ui.showKeyGuide = $0 },
                                  isEditingText: { ui.drawerFieldEditing },
                                  onSearch: { openSearch() },
                                  isModalDelete: { ui.pendingDelete != nil },
                                  onDeleteDialogKey: { handleDeleteDialogKey($0) },
                                  onRequestDelete: {
                                      if let t = engine.deleteTargetForSelection() {
                                          ui.requestDelete(id: t.id, occKey: t.occKey, recurring: t.recurring, imported: t.imported, alreadyHidden: t.alreadyHidden, kind: engine.kind(of: t.id) ?? .timed)
                                      }
                                  },
                                  isTutorialUp: { ui.showTutorial },
                                  onTutorialKey: { handleTutorialKey($0) }))
            // Day-view daily dashboard: the TODO list + upcoming deadlines, in a transparent
            // WebView (reuses the web's tokenizer + sectioning). Sits in the dashboard content
            // region; shown at day level with the drawer closed (it snaps in — WKWebView doesn't
            // animate with SwiftUI transitions — so it's gated on level like the split handle).
            // Mounted from week level up (level ≥ 2) so the zoom reveal (slide-in-from-right + fade,
            // driven per-frame) animates the whole way; at week level it's fully slid out + faded. It
            // stays mounted while the drawer is open too — instead of popping out, it fades aside in CSS
            // (the driver keeps ticking `drawer`). Interactive only at day level with the drawer closed.
            .overlay {
                if engine.chrome.level >= 2 {
                    DailyDashboardOverlay(engine: engine, carousel: dashCarousel,
                                          forwarder: gestureForwarder,
                                          tab: $dashTab, noteMode: $noteMode,
                                          inactive: ui.openEventId != nil && engine.chrome.level == 3,
                                          frac: dashFrac, vp: vp,
                                          containerWidth: geo.size.width, height: geo.size.height, theme: theme,
                                          onOpen: { ui.openEventId = sourceId(of: $0) },
                                          onCloseDrawer: { ui.openEventId = nil },
                                          onNoteExit: { engine.dashNoteExit() },
                                          onNavTab: { fwd in engine.tabCursor(fwd) })
                        // Stay hit-testable while the drawer is open so the in-page scrim can intercept +
                        // close (the WKWebView layer ignores the SwiftUI scrim/allowsHitTesting anyway).
                        .allowsHitTesting(engine.chrome.level == 3)
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
            // Day-view split handle: drag the timeline↔dashboard boundary to resize. Above the catcher
            // so it grabs the mouse in its narrow zone (the rest passes through). Shown in day view;
            // reads chrome.level (@Observable) so it appears/disappears as you zoom.
            .overlay {
                if engine.chrome.level == 3, ui.openEventId == nil {
                    DashboardSplitHandle(engine: engine, vp: vp, height: geo.size.height, theme: theme,
                                         onFrac: { dashFrac = $0 })
                }
            }
            // inline track-name editor
            .overlay {
                if let te = ui.editingTrack {
                    TrackNameEditor(engine: engine, target: te, theme: theme,
                                    onDone: { ui.editingTrack = nil; engine.trackEditing = false; refocusCatcher() })
                }
            }
            // inline band-title editor
            .overlay {
                if let be = ui.editingBand {
                    BandTitleEditor(engine: engine, target: be, theme: theme,
                                    onDone: { ui.editingBand = nil; engine.bandEditing = false; refocusCatcher() })
                }
            }
            // inline timed-event-title editor (keyboard "Enter → edit title", or click-a-selected-event)
            .overlay {
                if let te = ui.editingTimed {
                    TimedTitleEditor(engine: engine, target: te, theme: theme,
                                     onDone: { ui.editingTimed = nil; engine.timedEditing = false; refocusCatcher() })
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
                    EventDrawer(engine: engine, id: id, width: $drawerWidth, containerWidth: geo.size.width, theme: theme, onClose: { ui.openEventId = nil }, ui: ui, refocus: { refocusCatcher() },
                                demoNoteFeed: demo.noteFeed, demoNotePreview: demo.notePreview)
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
            .modifier(ModalOverlays(ui: ui, engine: engine, theme: theme, onDelete: { performDelete($0) }))
            // ai-assistant recording scene: a staged, offline chat panel in the main window (the real
            // assistant is a separate window the recorder can't frame). No-op outside that scene.
            .overlay(alignment: .topTrailing) {
                if demo.showAssistantPanel, let a = demo.assistant {
                    AssistantCalloutView(state: a, onOpenWindow: {})
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
                        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                        .padding(.top, 48).padding(.trailing, 14)   // clear the toolbar (full-size content window)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .overlay { DemoCursorOverlay(demo: demo) }   // synthetic pointer during a GIF recording (no-op otherwise)
            .onAppear { setupOnAppear(size: geo.size) }
            .onChange(of: geo.size) { _, s in engine.setViewport(s) }
            .onChange(of: ui.openEventId) { _, v in
                engine.drawerOpen = v != nil
                if let id = v {
                    engine.onHoverExit()   // clear any lingering highlight now
                    engine.openDrawerShift(id: id, drawerWidth: drawerWidth)
                    NSCursor.arrow.set()   // reset a stale hover cursor; SwiftUI takes over while open
                    // Keep the canvas as first responder while the drawer is open (no field focused), so its
                    // keys work — e.g. Space to close. (The notes WebView no longer steals focus; this covers
                    // any other control the appearing overlay might grab.)
                    if ui.drawerFocus == nil { refocusCatcher() }
                } else {
                    ui.drawerFocus = nil
                    engine.closeDrawerShift()
                    refocusCatcher()   // drawer closed → canvas keeps the keys (so Space re-opens it)
                }
            }
            .onChange(of: drawerWidth) { _, w in
                if let id = ui.openEventId { engine.updateDrawerShift(id: id, drawerWidth: w) }
            }
            // Leaving day view → snap the dashboard back to the TODO tab (the NOTE editor is a
            // day-level-only surface; this keeps the zoom-out reveal driven by the TODO WebView).
            .onChange(of: engine.chrome.level) { _, lvl in if lvl != 3 { dashTab = .todo } }
            // The dashboard tab/mode toggles are SwiftUI overlays (not routed through the engine), and
            // their transition animates via the timeline's CarouselDriver — so wake the render loop when
            // they change, else the switch would freeze while the calendar is idle.
            .onChange(of: dashTab) { _, _ in engine.wake() }
            .onChange(of: noteMode) { _, _ in engine.wake() }
            // Apple Calendar import: pull on first appearance, whenever the app returns to the foreground
            // (auto-refresh), and when the Settings window changes the connection.
            .onAppear { engine.importAppleCalendar() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                engine.importAppleCalendar()
                engine.syncNow()   // also pull/push iCloud on foreground (was never wired before)
            }
            .onReceive(NotificationCenter.default.publisher(for: .appleCalendarSettingsChanged)) { _ in engine.importAppleCalendar() }
            // "Show Hidden Imported Events" flipped → repaint. onChange catches the SwiftUI menu's @AppStorage
            // write; the notification catches the AppKit (dev-build) menu's direct UserDefaults write.
            .onChange(of: showHiddenImported) { _, _ in engine.viewPrefsChanged() }
            .onChange(of: mainTzPref) { _, _ in engine.viewPrefsChanged() }   // Current Timezone picker → repaint
            .onChange(of: altTzPref) { _, _ in engine.viewPrefsChanged() }    // Alternative Timezone picker → repaint
            .onReceive(NotificationCenter.default.publisher(for: .calendarViewPrefsChanged)) { _ in engine.viewPrefsChanged() }
        }
        .ignoresSafeArea()
            // Search overlays — siblings inside the ZStack, so they respect the toolbar safe-area inset
            // (the dropdown lands just BELOW the toolbar) while the calendar above stays full-bleed. The
            // dropdown is right-aligned under the (trailing) search field and styled like the drawer.
            if search.open {
                Color.black.opacity(0.001).contentShape(Rectangle())   // click-outside closes search
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
        }   // ZStack
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
                    .buttonStyle(.glass).buttonBorderShape(.circle).help("Search")
            }
        }
        ToolbarSpacer(.fixed)
        ToolbarItem(placement: .primaryAction) {
            // With a shared assistant: a quick-ask CALLOUT anchored to this button (an NSPopover —
            // caret + glass, may extend beyond the window). Without one (dev shell): the window.
            Button {
                if assistant != nil { showAssistantCallout.toggle() }
                else { openWindow(id: "assistant") }
            } label: { Image(systemName: "sparkles") }
                .buttonStyle(.glass).buttonBorderShape(.circle).help("Madocal AI (⌘I)")
                .popover(isPresented: $showAssistantCallout, arrowEdge: .bottom) {
                    if let assistant {
                        AssistantCalloutView(state: assistant) {
                            // Hand the callout's thread to the window: flush it to the store,
                            // point the window's session at it, close the callout, open the window.
                            showAssistantCallout = false
                            assistant.persistNow()
                            if let id = assistant.currentId { windowAssistant?.selectConversation(id) }
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
            Button { engine.goToToday() } label: { Text("Today") }
                .buttonStyle(.glass).buttonBorderShape(.capsule)
        }
    }
}

/// Draggable handle on the timeline↔dashboard boundary in day view. Mirrors the drawer's resize
/// handle: a slim capsule that surfaces on hover, with a resize cursor; dragging it adjusts the
/// split (`daily.frac`). Positioned from `engine.daily.frac` each render — during a drag its own
/// `dragFrac` state drives both the position and the engine update, so the handle tracks the cursor
/// even though the engine isn't `@Observable`.
/// The deadline quick-add "+" affordance: a small circle with a plus, matching the calendar's cursor
/// accent. Purely visual (positioned by CalendarView); the click is handled by the InputCatcher.
private struct DeadlineAddButton: View {
    let theme: Theme
    var hovering: Bool = false
    var body: some View {
        // Neutral cursor-colored ring at rest; on hover the edge + glyph brighten to full label color,
        // with a faint fill and glow (mirrors the web's .cc-ddl-add:hover feedback).
        Image(systemName: "plus")
            .font(.system(size: 8, weight: hovering ? .heavy : .bold))
            .foregroundStyle(hovering ? theme.text : theme.text.opacity(0.75))
            .frame(width: 15, height: 15)
            .background(Circle().fill(hovering ? theme.text.opacity(0.14) : theme.bg))
            .overlay(Circle().strokeBorder(hovering ? theme.text : theme.cursor, lineWidth: hovering ? 2 : 1.5))
            .shadow(color: theme.text.opacity(hovering ? 0.35 : 0), radius: hovering ? 4 : 0)
            .shadow(color: .black.opacity(0.3), radius: 2.5)
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct DashboardSplitHandle: View {
    let engine: CalendarEngine
    let vp: Viewport
    let height: CGFloat
    let theme: Theme
    var onFrac: (CGFloat) -> Void = { _ in }   // report the live split so the dashboard re-lays-out
    @State private var inGap = false      // mouse anywhere in the timeline↔dashboard gap
    @State private var onGrip = false     // mouse on the capsule itself (→ brighter + resize cursor)
    @State private var dragFrac: CGFloat?
    @State private var startFrac: CGFloat = 0.45

    private let minFrac: CGFloat = 0.22, maxFrac: CGFloat = 0.82   // must match engine.setDailyFrac
    // The dashboard content is inset ~25px from the boundary (see drawDashboardChrome's barX); the
    // capsule sits centered in that empty gap, which is also the zone that reveals it on hover.
    private let gapInset: CGFloat = 25

    var body: some View {
        let contentW = max(1, vp.w - Layout.labelW)
        let frac = dragFrac ?? engine.daily.frac
        // Timeline edge (gap's left) shifted by the layers' padLeft; the capsule centers in the gap.
        let gapLeftX = Layout.padLeft + Layout.labelW + frac * contentW
        let centerX = gapLeftX + gapInset / 2
        let active = onGrip || dragFrac != nil
        // Two states: faint in the gap, lighter on the grip; invisible otherwise.
        let opacity: Double = active ? 0.6 : (inGap ? 0.28 : 0.0)
        Capsule()
            .fill(theme.text.opacity(opacity))
            .frame(width: 4, height: 48)
            .frame(width: 12, height: 56)                 // grip zone: brighten + resize cursor + drag
            .contentShape(Rectangle())
            .onHover { h in onGrip = h; if h { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() } }
            .gesture(
                // GLOBAL space: the handle repositions itself as `frac` changes, so a `.local`
                // translation would be measured against a moving origin → feedback twitch.
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { v in
                        if dragFrac == nil { startFrac = engine.daily.frac }
                        let nf = min(maxFrac, max(minFrac, startFrac + v.translation.width / contentW))
                        dragFrac = nf
                        engine.setDailyFrac(nf)
                        onFrac(nf)
                    }
                    .onEnded { _ in dragFrac = nil }
            )
            .frame(width: gapInset, height: height)       // gap zone: reveals the capsule (faint)
            .contentShape(Rectangle())
            .onHover { inGap = $0 }
            .position(x: centerX, y: height / 2)
            .animation(.easeOut(duration: 0.12), value: opacity)
    }
}

/// Inline editor for a track (lane) name, placed over the clicked gutter slot. Updates
/// the shared name live across all months; commits/dismisses on Return, Esc, or blur.
private struct TrackNameEditor: View {
    let engine: CalendarEngine
    let target: TrackEdit
    let theme: Theme
    var onDone: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let r = target.rect
        TextField("Track", text: $text)
            .textFieldStyle(.plain)
            .font(.custom("Comic Sans MS", size: 13))
            .foregroundStyle(theme.text)
            .focused($focused)
            .padding(.leading, 10)
            .frame(width: r.width, height: max(18, r.height - 6), alignment: .leading)
            .position(x: r.midX + Layout.padLeft, y: r.midY)
            .onAppear {
                let names = target.month < engine.trackNames.count ? engine.trackNames[target.month] : []
                text = target.track < names.count ? names[target.track] : ""
                focused = true
            }
            .onChange(of: text) { _, v in engine.setTrackName(target.month, target.track, v) }
            .onChange(of: focused) { _, f in if !f { onDone() } }
            .onSubmit { onDone() }
            .onExitCommand { onDone() }
    }
}

/// Inline editor for a band's title, placed over the band. Its leading matches the
/// selected band's title (bar inset + selected bar width + gap). Commits live.
private struct BandTitleEditor: View {
    let engine: CalendarEngine
    let target: BandEdit
    let theme: Theme
    var onDone: () -> Void
    @State private var text = ""
    @State private var original = ""       // title before editing — restored if the field is left empty
    @FocusState private var focused: Bool

    // Commit: strip whitespace; a title that's empty after stripping reverts to the pre-edit title
    // (an event may never have a blank title).
    private func commit() {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        engine.setBandTitle(target.id, s.isEmpty ? original : s)
        onDone()
    }

    var body: some View {
        let r = target.rect
        TextField("Event", text: $text)
            .textFieldStyle(.plain)
            .font(.custom("Comic Sans MS", size: BandStyle.titleSize))
            .foregroundStyle(theme.text)
            .focused($focused)
            .padding(.leading, BandStyle.accentInset + BandStyle.accentWidthSelected + BandStyle.barTextGap)
            .padding(.trailing, BandStyle.titleTrailing)
            .frame(width: r.width, height: r.height, alignment: .leading)
            .position(x: r.midX + Layout.padLeft, y: r.midY)
            .onAppear { let t = engine.band(target.id)?.title ?? ""; text = t; original = t; focused = true }
            .onChange(of: text) { _, v in engine.setBandTitle(target.id, v) }   // live (as typed)
            .onChange(of: focused) { _, f in if !f { commit() } }
            .onSubmit { commit() }
            .onExitCommand { commit() }   // strip; revert to original if blank
    }
}

/// Inline title editor for a TIMED event — the sibling of BandTitleEditor. Opened by the keyboard
/// "Enter → edit title" (see KeyboardModel) or by clicking an already-selected event's body. Writes
/// the title live through the engine (coalesced into one undo step); commits on Return / blur / Esc.
private struct TimedTitleEditor: View {
    let engine: CalendarEngine
    let target: TimedEdit
    let theme: Theme
    var onDone: () -> Void
    @State private var text = ""
    @State private var original = ""       // title before editing — restored if the field is left empty
    @FocusState private var focused: Bool

    private func commit() {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        engine.update(target.id) { $0.title = s.isEmpty ? original : s }
        onDone()
    }

    var body: some View {
        let r = target.rect
        TextField("Event", text: $text)
            .textFieldStyle(.plain)
            .font(.custom("Comic Sans MS", size: 13))   // matches EventSticker's title font
            .foregroundStyle(theme.text)
            .focused($focused)
            .padding(.leading, BandStyle.accentInset + BandStyle.accentWidthSelected + BandStyle.barTextGap)
            .padding(.trailing, BandStyle.titleTrailing)
            .padding(.top, 3)   // match EventSticker's .padding(.vertical, 3) so the field sits on the title
            .frame(width: r.width, height: r.height, alignment: .topLeading)
            .position(x: r.midX + Layout.padLeft, y: r.midY)
            .onAppear { let t = engine.event(target.id)?.title ?? ""; text = t; original = t; focused = true }
            .onChange(of: text) { _, v in engine.update(target.id) { $0.title = v } }   // live (as typed)
            .onChange(of: focused) { _, f in if !f { commit() } }
            .onSubmit { commit() }
            .onExitCommand { commit() }   // strip; revert to original if blank
    }
}

/// Year › Month › Week › Day breadcrumb, progressive by zoom level (matches the web).
/// The Year crumb is a menu that jumps between selectable years.
private struct Breadcrumb: View {
    let engine: CalendarEngine
    private var chrome: CalendarChrome { engine.chrome }

    var body: some View {
        let atYear = chrome.level == 0
        HStack(spacing: 5) {
            // At the yearly view the "Year" crumb is a native Menu (system dropdown) whose
            // label includes our own caret — so clicking the text OR the caret opens it.
            // Deeper in, it's a plain button that zooms back out to the year.
            if atYear {
                Menu {
                    Picker("Year", selection: Binding(get: { chrome.year }, set: { engine.selectYear($0) })) {
                        ForEach(engine.yearOptions, id: \.self) { y in Text(verbatim: "\(y)").tag(y) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    yearLabel(atYear: true)
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                Button { engine.zoomToYear() } label: { yearLabel(atYear: false) }
                    .buttonStyle(.plain)
            }
            if chrome.level >= 1 {
                sep; crumbButton(MONTH_LONG[chrome.displayFocus], active: chrome.level == 1) { engine.zoomToMonth() }
            }
            if chrome.level >= 2 {
                sep; crumbButton("Week \(Int(chrome.week.rounded()) + 1)", active: chrome.level == 2) { engine.zoomToWeek() }
            }
            if chrome.level >= 3, let r = resolveDate(chrome.year, chrome.displayFocus, chrome.displayDom) {
                sep; crumb("\(WD_LONG[dayOfWeek(r.year, r.month, r.day)]), \(r.day)\(ordinal(r.day))", active: true)
            }
        }
        .padding(.horizontal, 18)
    }

    @ViewBuilder private func yearLabel(atYear: Bool) -> some View {
        HStack(spacing: 0) {
            crumb("Year \(chrome.year)", active: atYear).fixedSize()
            if atYear {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 5)
            }
        }
    }

    private var sep: some View {
        Text("›").font(.system(size: 12)).foregroundStyle(.tertiary)
            .padding(.horizontal, 3)   // a little more breathing room around the "›"
    }
    private func crumb(_ text: String, active: Bool) -> some View {
        Text(text)
            .font(.system(size: 13, weight: active ? .semibold : .regular))
            .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
    }
    /// A crumb that navigates when clicked (Month / Week). Kept clickable even when it's the active
    /// level — clicking then just re-settles that view.
    private func crumbButton(_ text: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { crumb(text, active: active) }
            .buttonStyle(.plain)
    }
    private func ordinal(_ n: Int) -> String {
        if (n % 100) / 10 == 1 { return "th" }
        switch n % 10 { case 1: return "st"; case 2: return "nd"; case 3: return "rd"; default: return "th" }
    }
}

#if os(macOS)
import AppKit

/// Transparent overlay that captures trackpad/mouse events and forwards them to the
/// engine. isFlipped so its coordinates match the SwiftUI/Canvas top-left origin.
struct InputCatcher: NSViewRepresentable {
    let engine: CalendarEngine
    let monthBridge: MonthPagerBridge
    let weekBridge: WeekPagerBridge
    let dayBridge: DayPagerBridge
    var forwarder: GestureForwarder? = nil
    var onOpenEvent: (String) -> Void = { _ in }
    var onEditTrack: (TrackEdit) -> Void = { _ in }
    var onKey: (KeyToken) -> Bool = { _ in false }   // dispatch a key; returns whether it was consumed
    var onKeyGuide: (Bool) -> Void = { _ in }        // Cmd+K held → show/hide the shortcut guide
    var isEditingText: () -> Bool = { false }         // a drawer inline editor owns the keyboard (pass keys to it)
    var onSearch: () -> Void = { }                    // Cmd+F → open the toolbar search field
    var isModalDelete: () -> Bool = { false }         // the delete-confirm dialog is up
    var onDeleteDialogKey: (DeleteDialogKey) -> Void = { _ in }
    var onRequestDelete: () -> Void = { }             // Delete on a selected event → raise the dialog
    var isTutorialUp: () -> Bool = { false }          // the tutorial carousel is up
    var onTutorialKey: (DeleteDialogKey) -> Void = { _ in }

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.engine = engine
        v.monthBridge = monthBridge
        v.weekBridge = weekBridge
        v.dayBridge = dayBridge
        v.onOpenEvent = onOpenEvent
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
        forwarder?.catcher = v   // let the dashboard web view forward horizontal scroll + pinch here
        v.installYearScrollDriver()
        v.installTimelineScrollDriver()
        v.installKeyMonitor()
        return v
    }
    func updateNSView(_ v: CatcherView, context: Context) {
        v.engine = engine; v.monthBridge = monthBridge; v.weekBridge = weekBridge; v.dayBridge = dayBridge
        v.onOpenEvent = onOpenEvent; v.onEditTrack = onEditTrack
        v.onKey = onKey; v.onKeyGuide = onKeyGuide; v.isEditingText = isEditingText; v.onSearch = onSearch
        v.isModalDelete = isModalDelete; v.onDeleteDialogKey = onDeleteDialogKey; v.onRequestDelete = onRequestDelete
        v.isTutorialUp = isTutorialUp; v.onTutorialKey = onTutorialKey
        forwarder?.catcher = v
    }
}

/// The custom delete-confirmation modal. A dimmed backdrop + a centered card with the question and a
/// horizontal row of buttons. Keyboard focus (the dashed ring) is driven by `pending.focus` via the key
/// monitor; every button is also mouse-clickable. Esc → Cancel is handled by the monitor; clicking the
/// backdrop cancels too.
struct DeleteConfirmDialog: View {
    let pending: PendingDelete
    let theme: Theme
    var onChoose: (DeleteChoice) -> Void

    var body: some View {
        ZStack {
            // Full-window scrim: a light dim that (with the CatcherView's modal guards) swallows all mouse
            // to the canvas. The subtle blur itself is applied to the calendar content, not here. Tap cancels.
            Color.black.opacity(0.1).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onChoose(.cancel) }
            // The glass card — same frosted-glass + border + shadow treatment as the ⌘K shortcut guide.
            VStack(spacing: 14) {
                Text(pending.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text)
                if let note = pending.note {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textMuted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                        // Take the FULL wrapped height for that width — without this, the card's outer
                        // `.fixedSize()` measures the note as one line and clips the buttons below it.
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    ForEach(Array(pending.choices.enumerated()), id: \.offset) { idx, choice in
                        DeleteDialogButton(label: choice.label(recurring: pending.recurring),
                                           destructive: !choice.isCancel,
                                           focused: pending.focus == idx,   // nil focus → no ring shown yet
                                           theme: theme) { onChoose(choice) }
                    }
                }
            }
            .padding(.horizontal, 40).padding(.vertical, 26)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(theme.sep.opacity(0.5), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
            .fixedSize()
        }
    }
}

/// One button in the delete dialog: a rounded pill that shows a dashed ring (matching the app's keyboard
/// focus style) when it's the focused choice, red text for destructive actions.
private struct DeleteDialogButton: View {
    let label: String
    let destructive: Bool
    let focused: Bool
    let theme: Theme
    var action: () -> Void
    @State private var hover = false

    private var accent: Color { destructive ? theme.eventBorder("red") : theme.text }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(accent)
                .padding(.horizontal, 18).padding(.vertical, 9)
                .frame(minWidth: 76)
        }
        .buttonStyle(.plain)
        .background(Capsule(style: .continuous).fill(theme.text.opacity(hover ? 0.14 : 0.07)))
        // Focus ring: a dashed capsule, offset slightly outward, shown only for the arrow-focused button.
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(focused ? accent : .clear,
                              style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .padding(-3)
        )
        .onHover { hover = $0; if $0 { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() } }
    }
}

/// The blocking-modal overlays: the delete-confirm dialog (with its blur + modal-flag plumbing) and the
/// onboarding tutorial carousel. Bundled into a ViewModifier so CalendarView's `body` chain stays short
/// enough for the Swift type-checker.
private struct ModalOverlays: ViewModifier {
    let ui: CalendarUIState
    let engine: CalendarEngine
    let theme: Theme
    var onDelete: (DeleteChoice) -> Void

    func body(content: Content) -> some View {
        content
            // Gentle blur on the calendar while the delete dialog is up (before the dialog overlay, so the
            // dialog stays sharp).
            .blur(radius: ui.pendingDelete != nil ? 2.5 : 0)
            .overlay {
                if let pd = ui.pendingDelete {
                    DeleteConfirmDialog(pending: pd, theme: theme, onChoose: onDelete)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: ui.pendingDelete)
            .onChange(of: ui.pendingDelete == nil) { _, gone in engine.inputModalUp = !gone }
            .overlay {   // tutorial carousel — topmost
                if ui.showTutorial {
                    TutorialView(theme: theme, ui: ui, onClose: { ui.showTutorial = false })
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: ui.showTutorial)
            .onReceive(NotificationCenter.default.publisher(for: .showTutorial)) { _ in
                ui.tutorialIndex = 0; ui.showTutorial = true; engine.wake()
            }
    }
}

/// Flipped so its scroll origin (0 = top, increasing downward) matches our scrollY.
final class FlippedDocView: NSView { override var isFlipped: Bool { true } }

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
        if e.phase.contains(.began) { onBegan?() }
        if ended && suppressSuperOnEnd { onEnded?(); return }
        super.scrollWheel(with: e)
        if ended { onEnded?() }
    }
}

/// The four keys the delete-confirm dialog reacts to (routed from the key monitor while the dialog is up).
enum DeleteDialogKey { case left, right, confirm, cancel }

final class CatcherView: NSView, NSMenuItemValidation {
    weak var engine: CalendarEngine?
    var onOpenEvent: ((String) -> Void)?
    var onEditTrack: ((TrackEdit) -> Void)?
    var onKey: ((KeyToken) -> Bool)?
    var onKeyGuide: ((Bool) -> Void)?
    var isEditingText: (() -> Bool)?    // drawer inline editor owns the keyboard → pass keys through
    var onSearch: (() -> Void)?         // Cmd+F → open the toolbar search field
    var isModalDelete: (() -> Bool)?    // the delete-confirm dialog is up → it owns ALL input
    var onDeleteDialogKey: ((DeleteDialogKey) -> Void)?   // route ←/→/Enter/Esc to the dialog while it's up
    var onRequestDelete: (() -> Void)?  // Delete on a selected event → raise the confirm dialog (no immediate delete)
    var isTutorialUp: (() -> Bool)?     // the tutorial carousel is up → also a blocking modal
    var onTutorialKey: ((DeleteDialogKey) -> Void)?   // route ←/→/Enter/Esc to the carousel
    /// A blocking modal is up → the canvas ignores every mouse/scroll/pinch event (the modal's backdrop
    /// captures them) and the key monitor swallows every non-modal key.
    private var modalActive: Bool { isModalDelete?() == true || isTutorialUp?() == true }
    private var keyGuideShown = false   // Cmd+K guide currently displayed (so we hide once on release)
    private var trackingAreaRef: NSTrackingArea?
    // Invisible NSScrollView used purely as a physics driver: AppKit computes the elastic
    // bounce + momentum, and we mirror its offset into the engine (year-view scroll).
    private let yearScroll = DriverScrollView()
    private let docView = FlippedDocView()
    private var syncing = false   // true while WE move/resize the driver — ignore its notifications
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
    private var swallowWeekMomentum = false   // same, for the week-view month-edge flip
    private var swallowDayMomentum = false    // same, for the day-view month-edge flip
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
    private var tlPrepared = false   // timeline driver sized+synced for the current gesture
    // While a scroll is in flight we suppress mouse-hover recomputation: a moving mouse during a
    // scroll otherwise fires onHover (hit-test + re-render) on every frame on top of the scroll's
    // own work. A short idle timer (reset by each scroll event) spans fingers-down + momentum.
    private var scrolling = false
    private var scrollIdle: DispatchWorkItem?
    private func noteScroll() {
        if !scrolling { scrolling = true; engine?.onHoverExit() }   // clear any stale highlight now
        scrollIdle?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.scrolling = false }
        scrollIdle = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    // Return false so a click on an INACTIVE window only activates the app — it isn't also
    // delivered as a mouseDown (which would zoom into a month / select an event). Once the
    // window is key, subsequent clicks act normally.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Always be the event target; the scroll-view driver is a physics-only subview
        // that we feed manually (never a hit target for mouse/clicks).
        guard bounds.contains(convert(point, from: superview)) else { return nil }
        // …except over the window toolbar (which floats above the content): fall through so the
        // click drags the window / hits a toolbar button, instead of us starting a band-create.
        if let win = window {
            let wp = superview?.convert(point, to: nil) ?? point   // window coords (y grows upward)
            if wp.y > win.contentLayoutRect.maxY { return nil }
        }
        return self
    }

    // ── Year-view scroll driver (native elastic bounce via NSScrollView) ─────────────
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
        addSubview(yearScroll, positioned: .below, relativeTo: nil)  // behind; never hit-tested

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

    // ── Hour-timeline scroll driver (native elastic bounce, week/day view) ─────────────
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

    deinit { NotificationCenter.default.removeObserver(self); if let m = keyMonitor { NSEvent.removeMonitor(m) }; repeatTimer?.invalidate() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(t)
        trackingAreaRef = t
    }

    override func layout() {
        super.layout()
        syncing = true   // suppress the mirror while resizing the clip/document view
        engine?.setViewport(bounds.size)   // idempotent: a no-op size is ignored inside (no wake / re-render)
        // Size the driver so its scrollable range == the engine's yearMaxScroll:
        // docHeight − clipHeight = maxScroll  ⇒  docHeight = clipHeight + maxScroll.
        yearScroll.frame = bounds
        let vp = Viewport(w: bounds.width, h: bounds.height)
        let maxY = yearMaxScroll(vp)
        docView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height + maxY)
        syncing = false
        setDriverOffset(engine?.scrollY ?? 0)   // apply AFTER the doc is sized (engine.scrollY = centered)
    }

    private func point(_ e: NSEvent) -> CGPoint {
        // Undo the render's padLeft translation (and the drawer left-shift) so hits land in
        // geometry space.
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: p.x - Layout.padLeft + (engine?.drawerShift ?? 0), y: p.y)
    }

    override func scrollWheel(with e: NSEvent) {
        if modalActive { return }   // blocking modal up → no canvas scrolling
        // Year view: hand the event to the NSScrollView driver so AppKit does the elastic
        // physics; its offset is mirrored back via clipBoundsChanged. Deeper levels use
        // the manual timeline/week/day handling.
        guard let engine else { return }
        // Drop leftover momentum from a fling that just flipped the month boundary (a new
        // finger-down gesture cancels the swallow and scrolls normally again).
        if swallowMonthMomentum {
            if e.phase.contains(.began) { swallowMonthMomentum = false }   // a fresh gesture resumes scrolling
            else {
                if e.momentumPhase.contains(.ended) { swallowMonthMomentum = false }
                return   // eat this trailing momentum event
            }
        }
        if swallowWeekMomentum {
            if e.phase.contains(.began) { swallowWeekMomentum = false }
            else {
                if e.momentumPhase.contains(.ended) { swallowWeekMomentum = false }
                return
            }
        }
        if swallowDayMomentum {
            if e.phase.contains(.began) { swallowDayMomentum = false }
            else {
                if e.momentumPhase.contains(.ended) { swallowDayMomentum = false }
                return
            }
        }
        if engine.isFlipping || engine.isMonthFlipping || engine.isWeekFlipping || engine.isDayFlipping || engine.trackEditing || engine.bandEditing || engine.timedEditing { return }   // don't fight flip / inline edit
        noteScroll()   // suppress hover while this scroll (and its momentum) is live
        if e.phase.contains(.began) { tlPrepared = false }   // new gesture → re-prep the timeline driver on first vertical event
        if engine.isYearLevel {
            yearScroll.scrollWheel(with: e)   // DriverScrollView does the physics + begin/end
        } else if engine.isMonthLevel, let sv = monthBridge?.scrollView {
            // Recover from a prior boundary flip: the SV kept the old month's offset. Snap it to the new
            // focus on the first touch of the next gesture — BEFORE any event reaches the SV — so the
            // gesture starts from the right month instead of lunging back toward the old one.
            if monthFlipPendingResync, e.phase.contains(.began) || e.phase.contains(.mayBegin) {
                monthFlipPendingResync = false
                monthBridge?.scrollToFocus(engine.focus)
            }
            if e.phase.contains(.began) { engine.beginMonthGesture() }
            let ended = e.phase.contains(.ended) || e.phase.contains(.cancelled)
            // Always forward — INCLUDING `.ended` on a boundary flip. Withholding it (the old approach)
            // left the SV's gesture stuck OPEN at the overscrolled edge page, so the flip's scrollTo() to
            // the new focus was a no-op and `setMonthProgress` then walked focus from that stale offset —
            // the "gentle scroll bursts through to November" bug. Forwarding `.ended` lets the SV settle
            // (its target is clamped to [0,11], so it can't overshoot the year) and closes the gesture, so
            // the re-sync sticks. `setMonthProgress` is guarded during the flip; the tail is swallowed.
            sv.scrollWheel(with: e)   // invisible SwiftUI ScrollView does native .paging
            if ended {
                engine.endMonthGesture()
                if engine.isMonthFlipping { swallowMonthMomentum = true; monthFlipPendingResync = true }   // eat the fling's tail + reset the SV next gesture
            }
        } else if engine.isWeekLevel, let sv = weekBridge?.scrollView {
            // The finger touching (.mayBegin) must reach the ScrollView so AppKit lets it CAPTURE an
            // in-flight snap animation (grab the decelerating scroll) instead of it running on and
            // then being yanked to a target — that's what made a mid-flight catch feel abrupt.
            if e.phase.contains(.mayBegin) { sv.scrollWheel(with: e); return }
            let ended = e.phase.contains(.ended) || e.phase.contains(.cancelled)
            // A boundary flip is about to commit → do NOT hand `.ended` to the SV. Otherwise its own
            // ScrollTargetBehavior kicks off a decelerate/snap whose target is computed in the OLD
            // month's content coords; the flip re-anchors focus (new cell count), so when that stale
            // animation later resumes it lands a week or two off. Skipping `.ended` means the snap
            // never starts; the flip drives (and pins) the pager instead, and momentum is swallowed.
            let willFlip = ended && engine.weekFlipArmed
            // Axis-lock: horizontal → the week pager; vertical → the hour-timeline scroll.
            if e.phase.contains(.began) { weekAxis = .undecided; engine.beginWeekGesture() }
            if weekAxis == .undecided {
                let dx = abs(e.scrollingDeltaX), dy = abs(e.scrollingDeltaY)
                if dx > 1 || dy > 1 { weekAxis = dx > dy ? .horizontal : .vertical }
            }
            if weekAxis == .vertical {
                if !tlPrepared { prepareTimelineDriver(); tlPrepared = true }   // size range + sync, once per gesture
                tlDriver.scrollWheel(with: e)          // native elastic bounce → mirrored into tlScroll
                if ended && !willFlip { sv.scrollWheel(with: e) }   // still let the SV settle the horizontal position
            } else if !willFlip {
                sv.scrollWheel(with: e)                // horizontal or still-ambiguous (a pure catch) → the SV
            }
            if ended {
                weekAxis = .undecided
                if engine.endWeekGesture() { swallowWeekMomentum = true }   // armed pull → flip; eat the fling tail
            }
        } else if engine.isDayLevel, let sv = dayBridge?.scrollView {
            // Day view: horizontal → the invisible day pager (native day-to-day paging); vertical →
            // the hour-timeline scroll. Same axis-lock + catch-capture as the week pager.
            if e.phase.contains(.mayBegin) { sv.scrollWheel(with: e); return }
            let ended = e.phase.contains(.ended) || e.phase.contains(.cancelled)
            // A boundary flip is about to commit → withhold `.ended` from the SV so its own snap
            // (computed in the old month's coords) can't fight the flip (same as the week pager).
            let willFlip = ended && engine.dayFlipArmed
            // Start the gesture on the FIRST fingers-down delta (phase not ended, no momentum), not on
            // `.began` — a forwarded scroll from the dashboard web view may never deliver `.began` here.
            // This keeps `liveDayScrolling` true for the whole finger-down phase (incl. pauses), so the
            // settle safety-net can't fire and snap while the user is still scrolling.
            let fingersDown = !ended && e.momentumPhase.isEmpty
            if fingersDown, !dayGestureActive { dayGestureActive = true; dayAxis = .undecided; engine.beginDayGesture() }
            if dayAxis == .undecided {
                let dx = abs(e.scrollingDeltaX), dy = abs(e.scrollingDeltaY)
                if dx > 1 || dy > 1 { dayAxis = dx > dy ? .horizontal : .vertical }
            }
            if dayAxis == .vertical {
                if !tlPrepared { prepareTimelineDriver(); tlPrepared = true }
                tlDriver.scrollWheel(with: e)          // native elastic bounce → mirrored into tlScroll
                if ended && !willFlip { sv.scrollWheel(with: e) }   // let the SV settle the horizontal position
            } else if !willFlip {
                sv.scrollWheel(with: e)                // horizontal or still-ambiguous (a pure catch)
            }
            if ended {
                dayAxis = .undecided
                dayGestureActive = false
                if engine.endDayGesture() { swallowDayMomentum = true }   // armed pull → flip; eat the fling tail
            }
        } else {
            engine.onWheel(dx: e.scrollingDeltaX, dy: e.scrollingDeltaY)
        }
    }
    override func magnify(with e: NSEvent) {
        if modalActive { return }
        let began = e.phase.contains(.began)
        let ended = e.phase.contains(.ended) || e.phase.contains(.cancelled)
        engine?.onMagnify(delta: e.magnification, at: point(e), began: began, ended: ended)
    }
    override func mouseDown(with e: NSEvent) {
        if modalActive { return }   // blocking modal up → canvas is inert
        engine?.enterMouseMode()   // mouse activity hides the keyboard cursor visual
        let p = point(e)
        // Day view: the daily-dashboard panel (and the band strip hidden behind it) owns its own clicks —
        // never start a calendar action (band-create, select, drill) under the panel.
        if engine?.inDayDashboard(p) == true { return }
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
        if e.clickCount == 2 {   // double-click any item → open its drawer
            // Open the SOURCE event (a ghost/promoted box maps back to its real item); the clicked
            // box stays selected → it gets the focused thick border while the series stays active.
            if let id = engine?.itemId(at: p) { onOpenEvent?(sourceId(of: id)) }
            return
        }
        engine?.onPointerDown(at: p)
    }
    override func mouseDragged(with e: NSEvent) {
        if modalActive { return }
        engine?.onPointerDrag(at: point(e)); NSCursor.closedHand.set()
    }
    override func mouseUp(with e: NSEvent) {
        if modalActive { return }
        engine?.onPointerUp(at: point(e))
    }
    /// The content extends under the (floating) window toolbar, and our tracking area reaches up
    /// there too — so ignore pointer events whose location is above the content area's top edge.
    private func overToolbar(_ e: NSEvent) -> Bool {
        guard let win = window else { return false }
        return e.locationInWindow.y > win.contentLayoutRect.maxY   // window coords: y grows upward
    }

    override func mouseMoved(with e: NSEvent) {
        if modalActive { return }
        engine?.enterMouseMode()   // mouse activity hides the keyboard cursor visual
        if overToolbar(e) { engine?.onHoverExit(); NSCursor.arrow.set(); return }   // don't hover through the toolbar
        if engine?.drawerOpen == true { return }   // drawer open → SwiftUI owns the cursor (title I-beam, handle resize)
        if scrolling { return }   // a scroll is in flight — skip hover recompute (perf)
        let p = point(e)
        // The dashboard web view owns its region AND its cursor (CSS drives pointer/hand over clickable
        // rows). Don't set a cursor here — our tracking area fires even under the overlaying web view, so
        // forcing .arrow would fight the web view's pointer cursor every move → visible flicker.
        if engine?.inDayDashboard(p) == true { engine?.onHoverExit(); return }

        engine?.onHover(at: p)
        toolTip = engine?.bandWarningTooltip(at: p)   // "Fully overlapping events" over the warn sign
        switch engine?.cursorHint(at: p) {
        case .grab: NSCursor.openHand.set()
        case .resizeLR: NSCursor.resizeLeftRight.set()
        case .text: NSCursor.iBeam.set()
        default: NSCursor.arrow.set()
        }
    }
    override func mouseExited(with e: NSEvent) { engine?.onHoverExit(); NSCursor.arrow.set() }

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
        guard let w = window, e.window === w else { return e }   // only our (key) window's events
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
            if e.keyCode == 40, e.modifierFlags.contains(.command) {
                if !keyGuideShown { keyGuideShown = true; onKeyGuide?(true) }
                return nil
            }
            // Cmd+F → open the toolbar search field (works from any state; the field then owns the keys).
            if e.keyCode == 3, e.modifierFlags.contains(.command), !e.isARepeat {
                onSearch?()
                return nil
            }
            if isTextInputFocused() { return e }   // a focused field/editor owns the key (typing, native undo)
            // ⌘Z / ⌘⇧Z are owned SOLELY by the Edit▸Undo/Redo menu command (one focus-aware handler). We
            // must NOT act on them here — doing so alongside the menu shortcut fired undo twice (rename +
            // create both undone on one press) — but we also must not let the catch-all `return nil` below
            // swallow them, or the menu shortcut never sees the key. So pass them straight through.
            if e.keyCode == 6, e.modifierFlags.contains(.command),
               !e.modifierFlags.contains(.option), !e.modifierFlags.contains(.control) {
                return e
            }
            engine?.wake()                          // calendar-owned key → drive a render (keyboard cursor/nav)
            if let token = Self.token(for: e) {
                // ⌘T → "go to today" from ANY navigation state (not just ones whose bindings include it).
                // Handled here so it's truly global; ignore OS auto-repeat so a held ⌘T flies once.
                if token == .cmdT {
                    if !e.isARepeat { engine?.enterKeyboardMode(); engine?.goToToday() }
                    return nil
                }
                // Repeatable keys (arrows, ⌘/⇧-arrows): we drive the auto-repeat OURSELVES (see the held-key
                // timer below) instead of the OS. macOS only repeats the LAST key pressed and never resumes
                // an earlier still-held key — so holding ← then tapping ↓ would "stick". Ignoring the OS
                // repeat and repeating the most-recently-held key ourselves keeps ← going after ↓ releases.
                if token.repeats {
                    if e.isARepeat { return nil }   // OS repeat suppressed; our timer drives it
                    dispatchNav(token)              // fire once on the fresh press (reveal-first handled inside)
                    trackHeld(e.keyCode, token)
                    return nil
                }
                // Discrete actions (Enter/Space/Tab/Esc/…): ignore OS auto-repeat (would double-fire).
                if e.isARepeat { return nil }
                if onKey?(token) == true { engine?.enterKeyboardMode(); return nil }   // dispatched → keyboard mode
            }
            switch e.keyCode {   // fallbacks for keys the current state didn't bind
            case 53: engine?.enterKeyboardMode(); engine?.onEscape()   // Esc → zoom out one level
            case 51, 117: onRequestDelete?()                           // Delete → raise the confirm dialog
            default: break
            }
            // Swallow any other unhandled key too. With no text field focused, the calendar owns the
            // keyboard; letting a key fall through to the window makes it emit the "funk" beep (e.g.
            // Space while the drawer is open). Command-shortcuts are handled earlier via menu key
            // equivalents, so they're unaffected. This is why we don't need to touch the window.
            return nil
        case .keyUp:
            if e.keyCode == 40, keyGuideShown { keyGuideShown = false; onKeyGuide?(false); return nil }
            if releaseHeld(e.keyCode) { return nil }   // a held nav key lifted → update the repeat set
            return e
        case .flagsChanged:
            if keyGuideShown, !e.modifierFlags.contains(.command) { keyGuideShown = false; onKeyGuide?(false) }
            return e
        default: return e
        }
    }
    // ── Custom auto-repeat for held navigation keys ────────────────────────────────────────────────
    // macOS repeats only the most-recently-pressed key and never resumes a still-held earlier one. We
    // track held repeatable keys ourselves and repeat the LAST one still down, so holding ← then tapping
    // ↓ resumes ← after ↓ is released (block & band cursors, event nav, etc.).
    private var heldOrder: [UInt16] = []          // keyCodes, ordered by press (last = most recent)
    private var heldToken: [UInt16: KeyToken] = [:]
    private var repeatTimer: Timer?
    private let repeatDelay: TimeInterval = 0.30
    private let repeatInterval: TimeInterval = 0.045

    /// Dispatch a nav token (with reveal-first): the first arrow after mouse mode only wakes the cursor.
    private func dispatchNav(_ token: KeyToken) {
        if isTextInputFocused() { return }
        engine?.wake()
        let isArrow = token == .up || token == .down || token == .left || token == .right
        if isArrow, engine?.keyboardActive == false { engine?.enterKeyboardMode(); return }
        if onKey?(token) == true { engine?.enterKeyboardMode() }
    }
    private func trackHeld(_ kc: UInt16, _ token: KeyToken) {
        heldOrder.removeAll { $0 == kc }; heldOrder.append(kc); heldToken[kc] = token
        repeatTimer?.invalidate()   // fresh press → restart the delay-then-repeat cycle
        repeatTimer = Timer.scheduledTimer(withTimeInterval: repeatDelay, repeats: false) { [weak self] _ in self?.beginRepeating() }
    }
    private func releaseHeld(_ kc: UInt16) -> Bool {
        guard heldToken[kc] != nil else { return false }
        heldOrder.removeAll { $0 == kc }; heldToken[kc] = nil
        if heldOrder.isEmpty { stopRepeat() }   // keep firing the remaining held key(s)
        return true
    }
    private func beginRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: repeatInterval, repeats: true) { [weak self] _ in
            guard let self, self.window?.isKeyWindow == true, let kc = self.heldOrder.last, let token = self.heldToken[kc]
            else { self?.stopRepeat(); return }
            self.dispatchNav(token)
        }
    }
    private func stopRepeat() { repeatTimer?.invalidate(); repeatTimer = nil; heldOrder.removeAll(); heldToken.removeAll() }

    /// Is a real text-input view the first responder? Then keys belong to it (typing / native undo),
    /// so the shortcut monitor steps aside. Covers the field editor (NSText) and the notes WKWebView.
    private func isTextInputFocused() -> Bool {
        // A drawer inline editor (the date/time NSDatePicker) owns the keyboard even though its focused
        // control isn't an NSText — pass all keys (incl. Tab) to it, don't advance the drawer cycle.
        if isEditingText?() == true { return true }
        guard let r = window?.firstResponder else { return false }
        if r === self { return false }
        // If focus lives inside a notes editor, trust ITS click-gate — not the raw responder class.
        // WebKit makes the WKWebView's internal WKContentView first responder on load, so a class-name
        // match would wrongly report "editing" the moment the drawer opens and swallow drawer shortcuts.
        // Walking up to the FocusGatedWebView and reading focusAllowed tells us if the user *clicked in*.
        if let v = r as? NSView {
            var node: NSView? = v
            while let cur = node {
                // Any gated web editor (drawer notes OR the daily-note dashboard) → trust its click-gate.
                if let gated = cur as? FocusGatedControl { return gated.focusAllowed }
                node = cur.superview
            }
        }
        if r is NSText { return true }   // a field editor (NSTextField / inline title) owns the keys
        let cls = String(describing: type(of: r))
        return cls.contains("TextView") || cls.contains("TextField")
    }
    // The canvas swallows raw keyDown (no beep) when it's first responder; the monitor above does the work.
    override func keyDown(with e: NSEvent) {}

    /// Normalize a raw key event into a view-independent `KeyToken` (or nil to leave it to native).
    private static func token(for e: NSEvent) -> KeyToken? {
        if e.modifierFlags.contains(.command) {
            switch e.keyCode {   // ⌘+arrows → nudge the selected event
            case 126: return .cmdUp
            case 125: return .cmdDown
            case 123: return .cmdLeft
            case 124: return .cmdRight
            default:
                switch e.charactersIgnoringModifiers?.lowercased() {
                case "s": return .cmdS
                case "n": return .cmdN
                case "t": return .cmdT           // ⌘T → go to today (any view)
                case "=", "+": return .cmdEqual   // ⌘= / ⌘+ → zoom in
                case "-", "_": return .cmdMinus   // ⌘− → zoom out
                default:  return nil               // other ⌘-combos → menu/native
                }
            }
        }
        let shift = e.modifierFlags.contains(.shift)
        switch e.keyCode {
        case 36, 76: return .enter
        case 49:     return .space
        case 53:     return .escape
        case 48:     return shift ? .backTab : .tab
        case 123:    return shift ? .shiftLeft : .left
        case 124:    return shift ? .shiftRight : .right
        case 126:    return shift ? .shiftUp : .up
        case 125:    return shift ? .shiftDown : .down
        case 51, 117:return .delete
        default:
            if let ch = e.charactersIgnoringModifiers?.first, ch.isLetter || ch.isNumber { return .char(ch) }
            return nil
        }
    }

    // Standard Undo/Redo actions. These reach the CatcherView ONLY when the calendar canvas is the
    // first responder — when a text field / editor is focused it's first in the chain and does its own
    // text undo instead, so ⌘Z layers correctly (text edits vs calendar edits).
    @objc func undo(_ sender: Any?) { engine?.undo() }
    @objc func redo(_ sender: Any?) { engine?.redo() }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return engine?.canUndo ?? false
        case #selector(redo(_:)): return engine?.canRedo ?? false
        default: return true
        }
    }
}
#endif
