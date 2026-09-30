// ONE drag-and-drop destination for the whole window, routing per-move to the right target —
// because AppKit's own resolution is a lottery we kept losing. Field-established (2026-09-30,
// three probe stages): the destination is chosen ONCE when a drag enters the window, by an
// undocumented frame walk whose ordering SwiftUI reshuffles as hosted views mount/unmount per
// calendar level; the window-spanning SwiftUI .onDrop host (the .ics import target) often won
// that pick, and since the cursor never leaves its frame, it KEPT the session for its whole
// lifetime — the note editors below never heard the drag, no matter where the cursor moved.
// Symptom: file drops into drawer/panel notes working or dying depending on view level and
// where the drag happened to enter the window.
//
// The router inverts the game: it is the front-most, window-wide registered destination, so
// it deliberately wins EVERY file-drag session (the probe proved this placement always
// receives it). On every draggingUpdated it re-routes to the deepest visible participant
// under the cursor — editor text > preview > margin scroll > drawer card — forwarding the
// standard NSDraggingDestination calls so each target's existing logic (overlays, caret
// insertion, promise intake) runs unchanged, with real entered/exited transitions the sticky
// AppKit session never delivered. No participant under the cursor → the .ics fallback (the
// old window-wide behavior, now scoped to "nowhere better"). Every routing switch logs at
// notice — `log show --predicate 'category == "attach"'` narrates the whole drag.

import AppKit
import CalendarEngine
import UniformTypeIdentifiers

/// The participant registry: every attachment drop view announces itself when it lands in a
/// window; the router routes among the live, visible ones by depth (deepest wins — the text
/// view inside its margin scroll, both inside the drawer's card zone).
@MainActor enum DropTargets {
    private struct Entry {
        weak var view: NSView?
    }

    private static var entries: [Entry] = []

    static func register(_ v: NSView) {
        entries.removeAll { $0.view == nil }
        guard !entries.contains(where: { $0.view === v }) else { return }
        entries.append(Entry(view: v))
    }

    /// Visible participants in `window` whose window-frame contains `p`, deepest first.
    static func candidates(in window: NSWindow, at p: NSPoint) -> [NSView] {
        entries.compactMap(\.view)
            .filter { v in
                v.window === window && v.attachDropVisible
                    && v.convert(v.bounds, to: nil).contains(p)
            }
            .sorted { depth($0) > depth($1) }
    }

    private static func depth(_ v: NSView) -> Int {
        var d = 0
        var cur = v.superview
        while cur != nil {
            d += 1
            cur = cur?.superview
        }
        return d
    }
}

/// The single window-wide destination. Installed once per window by the first participant
/// (idempotent: presence in the content view is the guard — offscreen windows all share
/// windowNumber -1, and a swapped content view needs a fresh install anyway).
@MainActor final class AttachmentDropRouter: NSView {
    /// The .ics fallback, wired by CalendarView (it owns the engine and the overlay state).
    static var icsImport: (([URL]) -> Void)?
    static var icsOverlay: ((Bool) -> Void)?

    static func install(in window: NSWindow) {
        guard let root = window.contentView,
              !root.subviews.contains(where: { $0 is AttachmentDropRouter }) else { return }
        let router = AttachmentDropRouter(frame: root.bounds)
        router.autoresizingMask = [.width, .height]
        router.registerForDraggedTypes(AttachmentDropIntake.draggedTypes)
        root.addSubview(router, positioned: .above, relativeTo: nil)
        attachLog.notice("drop router installed in window #\(window.windowNumber)")
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil // ordinary mouse never sees the router; only drag sessions land here
    }

    // ── Session state ─────────────────────────────────────────────────────────────────
    private weak var current: NSView? // the participant now owning the visuals
    private var icsActive = false

    private func isICSDrag(_ pb: NSPasteboard) -> Bool {
        guard let urls = AttachmentDropIntake.fileURLs(pb) else { return false }
        return urls.contains { $0.pathExtension.lowercased() == "ics" }
    }

    /// The per-move core: pick the target for this position, hand off with real
    /// entered/exited transitions, and return the operation the active target reports.
    private func routeMove(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = sender.draggingLocation
        guard let window else { return [] }
        // First candidate that ACCEPTS wins — a refusing view (no store, parked twin)
        // falls through to the next instead of blackholing the session.
        var accepted: NSView?
        var operation: NSDragOperation = []
        for c in DropTargets.candidates(in: window, at: p) {
            if c === current {
                accepted = c
                operation = c.draggingUpdated(sender)
                break
            }
            let op = c.draggingEntered(sender)
            if op != [] {
                accepted = c
                operation = op
                break
            }
        }
        if accepted !== current {
            current?.draggingExited(sender)
            attachLog.notice("""
            drop route: \(accepted.map { String(describing: type(of: $0)) } ?? "none") \
            at \(Int(p.x)),\(Int(p.y))\(self.current != nil ? " (was \(String(describing: type(of: self.current!))))" : "")
            """)
            current = accepted
        }
        if accepted != nil {
            setICSOverlay(false)
            return operation
        }
        // Nobody better → the .ics fallback (only lights up for drags that carry .ics).
        let ics = isICSDrag(sender.draggingPasteboard)
        setICSOverlay(ics)
        return ics ? .copy : []
    }

    private func setICSOverlay(_ on: Bool) {
        guard on != icsActive else { return }
        icsActive = on
        Self.icsOverlay?(on)
    }

    // ── NSDraggingDestination (no super: plain NSView implements none of these) ──────
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        attachLog.notice("drop router: session entered at \(Int(sender.draggingLocation.x)),\(Int(sender.draggingLocation.y))")
        return routeMove(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        routeMove(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let sender {
            current?.draggingExited(sender)
        }
        current = nil
        setICSOverlay(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        current?.draggingEnded(sender)
        current = nil
        setICSOverlay(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let current {
            return current.prepareForDragOperation(sender)
        }
        return isICSDrag(sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setICSOverlay(false)
        if let current {
            attachLog.notice("drop router: perform → \(String(describing: type(of: current)))")
            let ok = current.performDragOperation(sender)
            self.current = nil
            return ok
        }
        guard isICSDrag(sender.draggingPasteboard),
              let urls = AttachmentDropIntake.fileURLs(sender.draggingPasteboard) else {
            return false
        }
        attachLog.notice("drop router: perform → ics import (\(urls.count) file(s))")
        Self.icsImport?(urls)
        return true
    }
}
