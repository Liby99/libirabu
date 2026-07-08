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
            let vp = Viewport(w: geo.size.width, h: geo.size.height)
            TimelineView(.animation) { tl in
                let input = engine.sceneInput(at: tl.date, viewport: vp)
                ZStack {
                    // 1. base scene (below events)
                    Canvas { ctx, size in
                        var c = ctx
                        SceneRenderer.drawBase(input: input, tracks: engine.trackNames, in: &c, theme: theme)
                    }
                    // 2. events (bands + timed), frosted-glass stickers
                    EventsOverlay(input: input, events: engine.seedEvents, bands: engine.seedBands, selected: engine.selectedId, theme: theme)
                    // 3. foreground: deadlines + now-line + cursor, then the dashboard mask
                    Canvas { ctx, size in
                        var c = ctx
                        SceneRenderer.drawForeground(input: input, deadlines: engine.seedDeadlines, selected: engine.selectedId, in: &c, theme: theme)
                    }
                }
            }
            .background(theme.bg)
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
        return v
    }
    func updateNSView(_ v: CatcherView, context: Context) { v.engine = engine; v.onOpenEvent = onOpenEvent }
}

final class CatcherView: NSView, NSMenuItemValidation {
    weak var engine: CalendarEngine?
    var onOpenEvent: ((String) -> Void)?
    private var trackingAreaRef: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

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
    }

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func scrollWheel(with e: NSEvent) {
        engine?.onWheel(dx: e.scrollingDeltaX, dy: e.scrollingDeltaY)
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
