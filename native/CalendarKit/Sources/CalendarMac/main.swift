// macOS app bootstrap. A plain SwiftPM executable can't rely on the SwiftUI App
// lifecycle to show a window reliably, so we bring up NSApplication ourselves and
// host CalendarView in an NSWindow via NSHostingController.

import AppKit
import SwiftUI
import CalendarUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let size = NSSize(width: 1280, height: 840)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Calendar"
        // contentView (not contentViewController): a GeometryReader-based SwiftUI view
        // reports a 0×0 fitting size, which contentViewController would collapse the
        // window to. contentView + an explicit size keeps the window at 1280×840.
        let hosting = NSHostingView(rootView: CalendarView())
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.setContentSize(size)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        FileHandle.standardError.write("window frame=\(window.frame) visible=\(window.isVisible)\n".data(using: .utf8)!)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
