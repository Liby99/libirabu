// macOS app bootstrap. A plain SwiftPM executable can't rely on the SwiftUI App
// lifecycle to show a window reliably, so we bring up NSApplication ourselves and
// host CalendarView in an NSWindow via NSHostingView.

import AppKit
import SwiftUI
import CalendarUI
import CalendarEngine

// Note: the unhandled-key "funk" beep is silenced inside CalendarView (WindowBeepSilencerView), so
// it's handled for both this shell and the SwiftUI CalendarApp shell without per-window subclassing.

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    var window: NSWindow!
    var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        // Reconcile preferences with iCloud, then apply the saved appearance now that NSApp
        // exists. Syncs only on the entitled signed app; local-only here (see AppSettings.swift).
        PrefsSync.shared.start()
        applyPersistedAppearance()

        // The default 1440×840 (also used for GIF recording — a wider grid reads less cluttered; the recorded
        // crop rect is read back from the actual window, so any fixed size stays deterministic).
        let demo = !(ProcessInfo.processInfo.environment["CC_DEMO"] ?? "").isEmpty
        let size = NSSize(width: 1440, height: 840)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Calendar"
        // Keep the window alive after Cmd-W so it can be reopened (see reopen handler).
        window.isReleasedWhenClosed = false
        // contentView (not contentViewController): a GeometryReader-based SwiftUI view
        // reports a 0×0 fitting size, which contentViewController would collapse to.
        let hosting = NSHostingView(rootView: CalendarView())
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.setContentSize(size)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if demo { exportContentRect() }
    }

    /// Write the window's CONTENT area as a top-left-origin screen rect (points) so the recording script can
    /// `screencapture -R` exactly the calendar (no title bar). Written to $CC_DEMO_DATADIR/rect.txt.
    private func exportContentRect() {
        guard let dir = ProcessInfo.processInfo.environment["CC_DEMO_DATADIR"], !dir.isEmpty,
              let screen = window.screen ?? NSScreen.main else { return }
        let c = window.contentRect(forFrameRect: window.frame)          // bottom-left origin, points
        let topLeftY = screen.frame.height - c.maxY                      // flip to top-left origin
        let line = "\(Int(c.origin.x.rounded())) \(Int(topLeftY.rounded())) \(Int(c.width.rounded())) \(Int(c.height.rounded()))\n"
        try? line.write(toFile: (dir as NSString).appendingPathComponent("rect.txt"), atomically: true, encoding: .utf8)
    }

    // Cmd-W closes the window but leaves the app running (Cmd-Q quits).
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    // Reopen the window when the Dock icon is clicked and nothing is visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window.makeKeyAndOrderFront(nil) }
        return true
    }

    // Settings/Preferences (⌘,). Lazily create a single window hosting SettingsView; reuse it on
    // subsequent invocations so ⌘, just brings the existing window forward (no duplicates).
    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            w.title = "Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Standard menu bar so Cmd-Q / Cmd-W / Cmd-M work.
    private func buildMenu() {
        let name = "Calendar"
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About \(name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        // ⌘, — target self explicitly: the app delegate isn't in the responder chain by default.
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        // Standard undo:/redo: selectors → the responder chain routes them to whoever's focused: a
        // focused text field / editor does its own text undo; the focused calendar canvas (CatcherView
        // implements undo:/redo:) does the calendar undo. So ⌘Z works in every focus state.
        editMenu.addItem(withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: NSSelectorFromString("cut:"), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: NSSelectorFromString("copy:"), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: NSSelectorFromString("paste:"), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: NSSelectorFromString("selectAll:"), keyEquivalent: "a")

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        // Checkmark toggle; validateMenuItem (below) reflects the current state each time the menu opens.
        let showHidden = viewMenu.addItem(withTitle: "Show Hidden Imported Events",
                                          action: #selector(toggleShowHiddenImported(_:)), keyEquivalent: "")
        showHidden.target = self

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        NSApp.windowsMenu = windowMenu

        let helpItem = NSMenuItem()
        main.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        helpItem.submenu = helpMenu
        let tut = helpMenu.addItem(withTitle: "Tutorial", action: #selector(showTutorial(_:)), keyEquivalent: "")
        tut.target = self
        let ks = helpMenu.addItem(withTitle: "Keyboard Shortcuts", action: #selector(showKeyboardShortcuts(_:)), keyEquivalent: "")
        ks.target = self

        NSApp.mainMenu = main
    }

    @objc func showTutorial(_ sender: Any?) { NotificationCenter.default.post(name: .showTutorial, object: nil) }
    @objc func showKeyboardShortcuts(_ sender: Any?) { NotificationCenter.default.post(name: .showKeyboardShortcuts, object: nil) }

    // View ▸ Show Hidden Imported Events — flip the shared UserDefaults key + nudge the running calendar to
    // repaint. The @AppStorage in CalendarView also observes this key, but the notification is the reliable
    // cross-actor trigger from this AppKit menu.
    @objc func toggleShowHiddenImported(_ sender: NSMenuItem) {
        let key = CalendarEngine.showHiddenImportedKey
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
        NotificationCenter.default.post(name: .calendarViewPrefsChanged, object: nil)
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleShowHiddenImported(_:)) {
            item.state = UserDefaults.standard.bool(forKey: CalendarEngine.showHiddenImportedKey) ? .on : .off
        }
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
