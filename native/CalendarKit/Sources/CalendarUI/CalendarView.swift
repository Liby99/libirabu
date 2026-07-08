// The calendar surface: a per-frame Canvas driven by TimelineView(.animation),
// with an AppKit input bridge overlay for scroll-wheel / pinch / click / hover.

import SwiftUI
import CalendarGeometry
import CalendarEngine

public struct CalendarView: View {
    @State private var engine = CalendarEngine()
    @State private var ui = CalendarUIState()
    @Environment(\.colorScheme) private var scheme

    public init() {}

    public var body: some View {
        let theme = Theme(dark: scheme == .dark)
        GeometryReader { geo in
            let vp = Viewport(w: geo.size.width, h: geo.size.height)
            TimelineView(.animation) { tl in
                let input = engine.sceneInput(at: tl.date, viewport: vp)
                ZStack {
                    Canvas { ctx, size in
                        var c = ctx
                        SceneRenderer.draw(input: input, tracks: engine.trackNames, in: &c, size: size, theme: theme)
                    }
                    EventsOverlay(input: input, events: engine.seedEvents, selected: engine.selectedId, theme: theme)
                }
            }
            .background(theme.bg)
            .overlay(InputCatcher(engine: engine, onOpenEvent: { ui.openEventId = $0 }))
            .overlay(alignment: .trailing) {
                if let id = ui.openEventId {
                    EventDrawer(engine: engine, id: id, theme: theme, onClose: { ui.openEventId = nil })
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeOut(duration: 0.25), value: ui.openEventId)
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
        if e.clickCount == 2 {   // double-click an event → open its drawer
            if let id = engine?.eventId(at: point(e)) { onOpenEvent?(id) }
            return
        }
        engine?.onPointerDown(at: point(e))
    }
    override func mouseDragged(with e: NSEvent) { engine?.onPointerDrag(at: point(e)) }
    override func mouseUp(with e: NSEvent) { engine?.onPointerUp(at: point(e)) }
    override func mouseMoved(with e: NSEvent) { engine?.onHover(at: point(e)) }
    override func mouseExited(with e: NSEvent) { engine?.onHoverExit() }
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
