// The calendar surface: a per-frame Canvas driven by TimelineView(.animation),
// with an AppKit input bridge overlay for scroll-wheel / pinch / click / hover.

import SwiftUI
import CalendarGeometry
import CalendarEngine

public struct CalendarView: View {
    @State private var engine = CalendarEngine()
    @State private var ui = CalendarUIState()
    @State private var drawerWidth: CGFloat = 360
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
                    EventsOverlay(input: input, events: engine.seedEvents, bands: engine.seedBands, selected: engine.selectedId, theme: theme)
                        .offset(x: Layout.padLeft)
                    // 3. deadlines (above events, clipped to the content area)
                    Canvas { ctx, size in
                        var c = ctx
                        c.translateBy(x: Layout.padLeft, y: 0)
                        SceneRenderer.drawMid(input: input, deadlines: engine.seedDeadlines, selected: engine.selectedId, in: &c, theme: theme)
                    }
                    // 4. chrome on top of the glass: gutter labels/borders, track names,
                    //    now-line/cursor, dashboard title + bars
                    Canvas { ctx, size in
                        var c = ctx
                        c.translateBy(x: Layout.padLeft, y: 0)
                        SceneRenderer.drawAbove(input: input, tracks: engine.trackNames, in: &c, theme: theme)
                    }
                }
                .opacity(input.flipFade)   // whole-calendar fade during a year flip
            }
            // The visual layers are purely presentational — never let them intercept
            // mouse events (the Canvas layers are hit-testable and re-render every
            // frame, which otherwise steals clicks/drags from the input catcher).
            // No opaque background: the window is translucent (see CalendarApp),
            // so the desktop tint shows through.
            .allowsHitTesting(false)
            .overlay(InputCatcher(engine: engine, onOpenEvent: { ui.openEventId = $0 }))
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
                    EventDrawer(engine: engine, id: id, width: $drawerWidth, theme: theme, onClose: { ui.openEventId = nil })
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeOut(duration: 0.26), value: ui.openEventId)
            .onAppear { engine.setViewport(geo.size) }
            .onChange(of: geo.size) { _, s in engine.setViewport(s) }
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
                Button { } label: { Text("Today") }
                    .buttonStyle(.glass).buttonBorderShape(.capsule)
            }
        }
        // Let the translucent window material show through the toolbar (native tint).
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
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
                sep; crumb(MONTH_LONG[chrome.focus], active: chrome.level == 1)
            }
            if chrome.level >= 2 {
                sep; crumb("Week \(Int(chrome.week.rounded()) + 1)", active: chrome.level == 2)
            }
            if chrome.level >= 3, let r = resolveDate(chrome.year, chrome.focus, chrome.dailyDom) {
                sep; crumb("\(WD_LONG[dayOfWeek(chrome.year, r.month, r.day)]), \(r.day)\(ordinal(r.day))", active: true)
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
    }
    private func crumb(_ text: String, active: Bool) -> some View {
        Text(text)
            .font(.system(size: 13, weight: active ? .semibold : .regular))
            .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
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
    var onOpenEvent: (String) -> Void = { _ in }

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.engine = engine
        v.onOpenEvent = onOpenEvent
        v.installYearScrollDriver()
        return v
    }
    func updateNSView(_ v: CatcherView, context: Context) { v.engine = engine; v.onOpenEvent = onOpenEvent }
}

/// Flipped so its scroll origin (0 = top, increasing downward) matches our scrollY.
final class FlippedDocView: NSView { override var isFlipped: Bool { true } }

/// The year-scroll physics driver. Overriding scrollWheel (a) disables concurrent
/// "responsive scrolling" — which otherwise grabs the gesture and swallows the
/// .ended phase — so we reliably see begin/end, and (b) is the same pattern the
/// macOS pull-to-refresh libraries use. super still does the native elastic scroll.
final class DriverScrollView: NSScrollView {
    weak var engine: CalendarEngine?
    override func scrollWheel(with e: NSEvent) {
        print("[FLIP] driver phase=\(e.phase.rawValue) mom=\(e.momentumPhase.rawValue) dy=\(String(format: "%.1f", e.scrollingDeltaY))")
        if e.phase.contains(.began) { engine?.beginYearScrollGesture() }
        super.scrollWheel(with: e)
        if e.phase.contains(.ended) || e.phase.contains(.cancelled) { engine?.endYearScrollGesture() }
    }
}

final class CatcherView: NSView, NSMenuItemValidation {
    weak var engine: CalendarEngine?
    var onOpenEvent: ((String) -> Void)?
    private var trackingAreaRef: NSTrackingArea?
    // Invisible NSScrollView used purely as a physics driver: AppKit computes the elastic
    // bounce + momentum, and we mirror its offset into the engine (year-view scroll).
    private let yearScroll = DriverScrollView()
    private let docView = FlippedDocView()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Always be the event target; the scroll-view driver is a physics-only subview
        // that we feed manually (never a hit target for mouse/clicks).
        bounds.contains(convert(point, from: superview)) ? self : nil
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

        yearScroll.engine = engine   // the driver detects begin/end from the event phase
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged),
                       name: NSView.boundsDidChangeNotification, object: yearScroll.contentView)
        engine?.onSetYearScroll = { [weak self] y in self?.setDriverOffset(y) }
    }

    private func setDriverOffset(_ y: CGFloat) {
        let cv = yearScroll.contentView
        cv.scroll(to: NSPoint(x: 0, y: y))
        yearScroll.reflectScrolledClipView(cv)
    }

    @objc private func clipBoundsChanged() {
        guard let engine, engine.isYearLevel, !engine.isFlipping else { return }
        engine.setYearScroll(yearScroll.contentView.bounds.origin.y)
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
        engine?.setViewport(bounds.size)
        // Size the driver so its scrollable range == the engine's yearMaxScroll:
        // docHeight − clipHeight = maxScroll  ⇒  docHeight = clipHeight + maxScroll.
        yearScroll.frame = bounds
        let maxY = yearMaxScroll(Viewport(w: bounds.width, h: bounds.height))
        docView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height + maxY)
        setDriverOffset(engine?.scrollY ?? 0)   // keep the driver aligned with engine state
    }

    private func point(_ e: NSEvent) -> CGPoint {
        // Undo the render's padLeft translation so hits land in geometry space.
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: p.x - Layout.padLeft, y: p.y)
    }

    override func scrollWheel(with e: NSEvent) {
        // Year view: hand the event to the NSScrollView driver so AppKit does the elastic
        // physics; its offset is mirrored back via clipBoundsChanged. Deeper levels use
        // the manual timeline/week/day handling.
        guard let engine else { return }
        if engine.isFlipping { return }            // don't fight the flip transition
        if engine.isYearLevel {
            print("[FLIP] wheel phase=\(e.phase.rawValue) mom=\(e.momentumPhase.rawValue) dy=\(String(format: "%.1f", e.scrollingDeltaY))")
            // The scroll view grabs the gesture (concurrent scrolling), so begin/end come
            // from its live-scroll notifications, not the forwarded event's phase.
            yearScroll.scrollWheel(with: e)
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
        window?.makeFirstResponder(self)
        if e.clickCount == 2 {   // double-click any item → open its drawer
            if let id = engine?.itemId(at: point(e)) { onOpenEvent?(id) }
            return
        }
        engine?.onPointerDown(at: point(e))
    }
    override func mouseDragged(with e: NSEvent) { engine?.onPointerDrag(at: point(e)); NSCursor.closedHand.set() }
    override func mouseUp(with e: NSEvent) { engine?.onPointerUp(at: point(e)) }
    override func mouseMoved(with e: NSEvent) {
        let p = point(e)
        engine?.onHover(at: p)
        switch engine?.cursorHint(at: p) {
        case .grab: NSCursor.openHand.set()
        case .create: NSCursor.crosshair.set()
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
