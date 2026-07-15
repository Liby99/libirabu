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
    @State private var noteMode: NotesMode = .edit // daily-note edit/preview (native toggle mirrors JS)
    // Global Performance Mode: render events as flat tinted fills instead of Liquid Glass
    // (glass is one GPU pass per sticker). Persisted; defaults on for now.
    @AppStorage("cc.performanceMode") private var perfMode = true
    @Environment(\.colorScheme) private var scheme

    public init() {}

    public var body: some View {
        let theme = Theme(dark: scheme == .dark)
        GeometryReader { geo in
            let vp = Viewport(w: geo.size.width - Layout.padLeft - Layout.padRight, h: geo.size.height)
            TimelineView(.animation) { tl in
                let input = engine.sceneInput(at: tl.date, viewport: vp)
                ZStack {
                    // Single translucent-glass background (the window material). Everything
                    // below is just fonts + borders drawn on top; the gutter + dashboard
                    // regions are the same glass, so content is CLIPPED (not masked) so it
                    // never overflows into them.
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
                                  drawerOpen: ui.openEventId != nil, editingId: ui.editingBand?.id,
                                  draggingId: engine.activeTimedDragId,
                                  perfMode: perfMode, theme: theme)
                        .offset(x: Layout.padLeft)
                    // 3. deadlines: the moment line + dots are drawn in the Canvas…
                    Canvas { ctx, size in
                        var c = ctx
                        c.translateBy(x: Layout.padLeft, y: 0)
                        SceneRenderer.drawMid(input: input, deadlines: engine.viewDeadlines(), selected: engine.selectedId, drawerOpen: ui.openEventId != nil, hovered: engine.hoveredEventId, in: &c, theme: theme)
                    }
                    // …and the labels are SwiftUI glass pills (activation styling), above the line.
                    DeadlinesOverlay(input: input, deadlines: engine.viewDeadlines(),
                                     sides: engine.deadlineSides(),
                                     selected: engine.selectedId, hovered: engine.hoveredEventId,
                                     drawerOpen: ui.openEventId != nil, theme: theme)
                        .offset(x: Layout.padLeft)
                    // 4. chrome on top of the glass: gutter labels/borders, track names,
                    //    now-line/cursor, dashboard title + bars
                    Canvas { ctx, size in
                        var c = ctx
                        c.translateBy(x: Layout.padLeft, y: 0)
                        SceneRenderer.drawAbove(input: input, tracks: engine.trackNames,
                                                hideTrack: ui.editingTrack.map { ($0.month, $0.track) }, in: &c, theme: theme)
                    }
                    // Per-frame day-carousel driver for the dashboard WebView (invisible). Inside the
                    // TimelineView so it ticks every frame while paging days AND across the zoom reveal
                    // (z 2→3): it carries {from,to,dir,p} for day paging and `reveal` for the panel's
                    // slide-in-from-right + fade. Active from week level up so the reveal animates fully.
                    if input.z > 1.5 {
                        let c = engine.dashboardCarousel()
                        // Slide fraction (0 open → 1 off-right) derived from the SAME geometry the
                        // Canvas uses, so the panel's left edge tracks dashboardLeftAnimated exactly
                        // (it depends on the growing day-column width, not `reveal` alone). The web view
                        // frame rests at `lOpen`; translating by this fraction of its width `wvW` lands
                        // its left edge at padLeft + dashboardLeftAnimated.
                        let lOpen = Layout.labelW + dashFrac * max(1, vp.w - Layout.labelW)
                        let wvW = max(1, vp.w - lOpen)
                        let slide = min(1, max(0, Double((dashboardLeftAnimated(input) - lOpen) / wvW)))
                        CarouselDriver(carousel: dashCarousel, anim: dashAnim, from: c.from, to: c.to,
                                       dir: c.dir, p: c.p, reveal: c.reveal, slide: slide)
                            .frame(width: 0, height: 0)
                    }
                }
                .opacity(input.flipFade)   // whole-calendar fade during a year flip
                .offset(x: -engine.drawerShift)   // slide left so the drawer item is revealed/centered
            }
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
                                  onEditTrack: { te in engine.trackEditing = true; ui.editingTrack = te }))
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
                                          tab: $dashTab, noteMode: $noteMode, frac: dashFrac, vp: vp,
                                          containerWidth: geo.size.width, height: geo.size.height, theme: theme,
                                          onOpen: { ui.openEventId = sourceId(of: $0) })
                        .allowsHitTesting(engine.chrome.level == 3 && ui.openEventId == nil)
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
                                    onDone: { ui.editingTrack = nil; engine.trackEditing = false })
                }
            }
            // inline band-title editor
            .overlay {
                if let be = ui.editingBand {
                    BandTitleEditor(engine: engine, target: be, theme: theme,
                                    onDone: { ui.editingBand = nil; engine.bandEditing = false })
                }
            }
            // 4a. scrim — blocks the canvas + closes on outside-click (fades)
            .overlay {
                if ui.openEventId != nil {
                    Rectangle()
                        .fill(.black.opacity(0.2))
                        .contentShape(Rectangle())
                        .onTapGesture { ui.openEventId = nil }
                        .transition(.opacity)
                }
            }
            // 4b. the drawer panel — slides in from the trailing edge
            .overlay(alignment: .trailing) {
                if let id = ui.openEventId {
                    EventDrawer(engine: engine, id: id, width: $drawerWidth, containerWidth: geo.size.width, theme: theme, onClose: { ui.openEventId = nil })
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeOut(duration: 0.26), value: ui.openEventId)
            .onAppear {
                engine.setViewport(geo.size)
                dashFrac = engine.daily.frac
                engine.onEditBand = { id, rect in engine.bandEditing = true; ui.editingBand = BandEdit(id: id, rect: rect) }
            }
            .onChange(of: geo.size) { _, s in engine.setViewport(s) }
            .onChange(of: ui.openEventId) { _, v in
                engine.drawerOpen = v != nil
                if let id = v {
                    engine.onHoverExit()   // clear any lingering highlight now
                    engine.openDrawerShift(id: id, drawerWidth: drawerWidth)
                    NSCursor.arrow.set()   // reset a stale hover cursor; SwiftUI takes over while open
                } else {
                    engine.closeDrawerShift()
                }
            }
            .onChange(of: drawerWidth) { _, w in
                if let id = ui.openEventId { engine.updateDrawerShift(id: id, drawerWidth: w) }
            }
            // Leaving day view → snap the dashboard back to the TODO tab (the NOTE editor is a
            // day-level-only surface; this keeps the zoom-out reveal driven by the TODO WebView).
            .onChange(of: engine.chrome.level) { _, lvl in if lvl != 3 { dashTab = .todo } }
        }
        .ignoresSafeArea()
        .toolbar {
            ToolbarItem(placement: .navigation) { Breadcrumb(engine: engine) }
            ToolbarSpacer(.flexible)
            ToolbarItem(placement: .primaryAction) {
                Button { } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.glass).buttonBorderShape(.circle).help("Search")
            }
            ToolbarSpacer(.fixed)
            ToolbarItem(placement: .primaryAction) {
                Button { } label: { Image(systemName: "sparkles") }
                    .buttonStyle(.glass).buttonBorderShape(.circle).help("Assistant")
            }
            ToolbarSpacer(.fixed)
            ToolbarItem(placement: .primaryAction) {
                Button { engine.goToToday() } label: { Text("Today") }
                    .buttonStyle(.glass).buttonBorderShape(.capsule)
            }
        }
        // Let the translucent window material show through the toolbar (native tint).
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}

/// Draggable handle on the timeline↔dashboard boundary in day view. Mirrors the drawer's resize
/// handle: a slim capsule that surfaces on hover, with a resize cursor; dragging it adjusts the
/// split (`daily.frac`). Positioned from `engine.daily.frac` each render — during a drag its own
/// `dragFrac` state drives both the position and the engine update, so the handle tracks the cursor
/// even though the engine isn't `@Observable`.
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
    @FocusState private var focused: Bool

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
            .onAppear { text = engine.band(target.id)?.title ?? ""; focused = true }
            .onChange(of: text) { _, v in engine.setBandTitle(target.id, v) }
            .onChange(of: focused) { _, f in if !f { onDone() } }
            .onSubmit { onDone() }
            .onExitCommand { onDone() }
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
                sep; crumbButton(MONTH_LONG[chrome.focus], active: chrome.level == 1) { engine.zoomToMonth() }
            }
            if chrome.level >= 2 {
                sep; crumbButton("Week \(Int(chrome.week.rounded()) + 1)", active: chrome.level == 2) { engine.zoomToWeek() }
            }
            if chrome.level >= 3, let r = resolveDate(chrome.year, chrome.focus, chrome.dailyDom) {
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

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.engine = engine
        v.monthBridge = monthBridge
        v.weekBridge = weekBridge
        v.dayBridge = dayBridge
        v.onOpenEvent = onOpenEvent
        v.onEditTrack = onEditTrack
        forwarder?.catcher = v   // let the dashboard web view forward horizontal scroll + pinch here
        v.installYearScrollDriver()
        v.installTimelineScrollDriver()
        return v
    }
    func updateNSView(_ v: CatcherView, context: Context) {
        v.engine = engine; v.monthBridge = monthBridge; v.weekBridge = weekBridge; v.dayBridge = dayBridge
        v.onOpenEvent = onOpenEvent; v.onEditTrack = onEditTrack
        forwarder?.catcher = v
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

final class CatcherView: NSView, NSMenuItemValidation {
    weak var engine: CalendarEngine?
    var onOpenEvent: ((String) -> Void)?
    var onEditTrack: ((TrackEdit) -> Void)?
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
    // Week view has TWO scroll axes (horizontal = week window, vertical = hour timeline). Lock to
    // the dominant axis at gesture start so a diagonal drag doesn't do both at once.
    private enum ScrollAxis { case undecided, horizontal, vertical }
    private var weekAxis: ScrollAxis = .undecided
    private var dayAxis: ScrollAxis = .undecided
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

    deinit { NotificationCenter.default.removeObserver(self) }

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
        engine?.setViewport(bounds.size)
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
        if engine.isFlipping || engine.isMonthFlipping || engine.isWeekFlipping || engine.isDayFlipping || engine.trackEditing || engine.bandEditing { return }   // don't fight flip / inline edit
        noteScroll()   // suppress hover while this scroll (and its momentum) is live
        if e.phase.contains(.began) { tlPrepared = false }   // new gesture → re-prep the timeline driver on first vertical event
        if engine.isYearLevel {
            yearScroll.scrollWheel(with: e)   // DriverScrollView does the physics + begin/end
        } else if engine.isMonthLevel, let sv = monthBridge?.scrollView {
            if e.phase.contains(.began) { engine.beginMonthGesture() }
            sv.scrollWheel(with: e)           // invisible SwiftUI ScrollView does native .paging
            if e.phase.contains(.ended) || e.phase.contains(.cancelled) {
                engine.endMonthGesture()
                if engine.isMonthFlipping { swallowMonthMomentum = true }   // eat the fling's tail
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
            if e.phase.contains(.began) { dayAxis = .undecided; engine.beginDayGesture() }
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
                if engine.endDayGesture() { swallowDayMomentum = true }   // armed pull → flip; eat the fling tail
            }
        } else {
            engine.onWheel(dx: e.scrollingDeltaX, dy: e.scrollingDeltaY)
        }
    }
    override func magnify(with e: NSEvent) {
        let began = e.phase.contains(.began)
        let ended = e.phase.contains(.ended) || e.phase.contains(.cancelled)
        engine?.onMagnify(delta: e.magnification, at: point(e), began: began, ended: ended)
    }
    override func mouseDown(with e: NSEvent) {
        let p = point(e)
        // Day view: the daily-dashboard panel (and the band strip hidden behind it) owns its own clicks —
        // never start a calendar action (band-create, select, drill) under the panel.
        if engine?.inDayDashboard(p) == true { return }
        // Track-name edit: a click just commits/dismisses it (swallowed — no zoom).
        if engine?.trackEditing == true {
            window?.makeFirstResponder(self)
            return
        }
        // Band-title edit: commit/dismiss it (blur), then let THIS click act normally —
        // selecting another event, or deselecting on blank (fall through below).
        if engine?.bandEditing == true {
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
    override func mouseDragged(with e: NSEvent) { engine?.onPointerDrag(at: point(e)); NSCursor.closedHand.set() }
    override func mouseUp(with e: NSEvent) { engine?.onPointerUp(at: point(e)) }
    /// The content extends under the (floating) window toolbar, and our tracking area reaches up
    /// there too — so ignore pointer events whose location is above the content area's top edge.
    private func overToolbar(_ e: NSEvent) -> Bool {
        guard let win = window else { return false }
        return e.locationInWindow.y > win.contentLayoutRect.maxY   // window coords: y grows upward
    }

    override func mouseMoved(with e: NSEvent) {
        if overToolbar(e) { engine?.onHoverExit(); NSCursor.arrow.set(); return }   // don't hover through the toolbar
        if engine?.drawerOpen == true { return }   // drawer open → SwiftUI owns the cursor (title I-beam, handle resize)
        if scrolling { return }   // a scroll is in flight — skip hover recompute (perf)
        let p = point(e)
        if engine?.inDayDashboard(p) == true { engine?.onHoverExit(); NSCursor.arrow.set(); return }   // panel owns its region

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
    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 53: engine?.onEscape()             // Esc
        case 51, 117: engine?.deleteSelected()  // Delete / Forward-Delete
        default: super.keyDown(with: e)
        }
    }

    // Edit-menu Undo/Redo (nil-targeted → reach here via the responder chain).
    @objc func performUndo(_ sender: Any?) { engine?.undo() }
    @objc func performRedo(_ sender: Any?) { engine?.redo() }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(performUndo(_:)): return engine?.canUndo ?? false
        case #selector(performRedo(_:)): return engine?.canRedo ?? false
        default: return true
        }
    }
}
#endif
