// macOS app bootstrap. A plain SwiftPM executable can't rely on the SwiftUI App
// lifecycle to show a window reliably, so we bring up NSApplication ourselves and
// host CalendarView in an NSWindow via NSHostingController.

import AppKit
import SwiftUI
import CalendarUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = NSHostingController(rootView: CalendarView())
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Calendar"
        window.contentViewController = controller
        window.setFrameAutosaveName("CalendarMainWindow")
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
