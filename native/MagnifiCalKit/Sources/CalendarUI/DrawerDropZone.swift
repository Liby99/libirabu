// The event drawer's CARD-WIDE attachment drop zone (field-traced 2026-09-30): the drawer's
// note editor/preview accept drops only inside their exact frames, and anywhere else on the
// card — the padding gutters, the title/config area — AppKit resolved the drag to the app's
// window-wide .ics target (SwiftUI's onDrop host spans the whole window), which silently
// refuses non-.ics files: no cursor badge, no import, no log. The probe walk caught it:
// `reachable=[_PlatformDraggingDestinationView[0,0 1634x893]] frame-blocked=[MarginDropScroll
// View[1232,63 374x670]contains=false]` — the drop was 16pt right of the editor. This zone
// overlays the ENTIRE card: deeper than the window-wide target (the deeper registered view
// wins the drag), shallower than the editor/preview (caret-precise drops stay theirs), and
// appends dropped files to the open note. hitTest is nil — ordinary mouse never sees it.

import AppKit
import CalendarEngine
import SwiftUI

struct DrawerDropZone: NSViewRepresentable {
    let engine: CalendarEngine
    let deliver: ([AttachmentToken]) -> Void

    final class ZoneView: NSView {
        var store: (() -> AttachmentStore?)?
        var deliver: (([AttachmentToken]) -> Void)?
        private var active = false {
            didSet { if active != oldValue {
                needsDisplay = true
            } }
        }

        override func hitTest(_: NSPoint) -> NSView? {
            nil // drags arrive via the router; clicks pass through
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                DropTargets.register(self)
                AttachmentDropRouter.install(in: window)
            }
        }

        override func draw(_: NSRect) {
            if active {
                AttachmentDropOverlay.draw(in: bounds) // the shared Add-Attachment affordance
            }
        }

        // NO super calls: plain NSView implements none of NSDraggingDestination's optional
        // methods (the MarginDropScrollView "unrecognized selector" lesson).
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard attachDropVisible, store?() != nil,
                  AttachmentDropIntake.hasImportableFiles(sender.draggingPasteboard) else {
                return []
            }
            attachLog.notice("drawer zone entered")
            active = true
            return .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            active ? .copy : []
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            active = false
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            active = false
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            active
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            active = false
            guard let store = store?(), let deliver else { return false }
            return AttachmentDropIntake.receive(sender.draggingPasteboard, store: store,
                                                deliver: deliver)
        }
    }

    func makeNSView(context _: Context) -> ZoneView {
        let v = ZoneView()
        v.registerForDraggedTypes(AttachmentDropIntake.draggedTypes)
        return v
    }

    func updateNSView(_ v: ZoneView, context _: Context) {
        v.store = { [weak engine] in engine?.attachments }
        v.deliver = deliver
    }
}
