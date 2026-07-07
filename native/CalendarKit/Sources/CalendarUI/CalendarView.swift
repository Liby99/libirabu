// The calendar surface: a per-frame Canvas driven by TimelineView(.animation),
// with an AppKit input bridge overlay for scroll-wheel / pinch / click / hover.

import SwiftUI
import CalendarGeometry
import CalendarEngine

public struct CalendarView: View {
    @State private var engine = CalendarEngine()
    @Environment(\.colorScheme) private var scheme

    public init() {}

    public var body: some View {
        let theme = Theme(dark: scheme == .dark)
        GeometryReader { geo in
            let vp = Viewport(w: geo.size.width, h: geo.size.height)
            TimelineView(.animation) { tl in
                let input = engine.sceneInput(at: tl.date, viewport: vp)
                Canvas { ctx, size in
                    var c = ctx
                    SceneRenderer.draw(input: input, events: engine.seedEvents, in: &c, size: size, theme: theme)
                }
            }
            .background(theme.bg)
            .overlay(InputCatcher(engine: engine))
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

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.engine = engine
        return v
    }
    func updateNSView(_ v: CatcherView, context: Context) { v.engine = engine }
}

final class CatcherView: NSView {
    weak var engine: CalendarEngine?
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
        engine?.onClick(at: point(e))
    }
    override func mouseMoved(with e: NSEvent) { engine?.onHover(at: point(e)) }
    override func mouseExited(with e: NSEvent) { engine?.onHoverExit() }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { engine?.onEscape() }  // Esc
        else { super.keyDown(with: e) }
    }
}
#endif
