// macOS app bootstrap. A plain SwiftPM executable can't rely on the SwiftUI App
// lifecycle to show a window reliably, so we bring up NSApplication ourselves and
// host CalendarView in an NSWindow via NSHostingView.

import AppKit
import SwiftUI
import CalendarUI
import CalendarEngine

// Note: the unhandled-key "funk" beep is silenced inside CalendarView (WindowBeepSilencerView), so
// it's handled for both this shell and the SwiftUI CalendarApp shell without per-window subclassing.

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    var window: NSWindow!
    var settingsWindow: NSWindow?
    var helpWindow: NSWindow?
    // View ▸ Filter by Tags: the dynamic submenu + its parent item (retitled when filtering), and the
    // last-shown tag universe keys ("Hide All" needs the full key set).
    var tagFilterMenu: NSMenu?
    var tagFilterItem: NSMenuItem?
    var tagAllKeys: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        // Reconcile preferences with iCloud, then apply the saved appearance now that NSApp
        // exists. Syncs only on the entitled signed app; local-only here (see AppSettings.swift).
        PrefsSync.shared.start()
        applyPersistedAppearance()

        // The default 1440×840 (also used for GIF recording — a wider grid reads less cluttered; the recorded
        // crop rect is read back from the actual window, so any fixed size stays deterministic).
        let demo = !(ProcessInfo.processInfo.environment["CC_DEMO"] ?? "").isEmpty
        // CC_WINDOW=WxH overrides the size (benchmarks measure at realistic, e.g. full-screen, sizes).
        var size = NSSize(width: 1440, height: 840)
        if let ws = ProcessInfo.processInfo.environment["CC_WINDOW"] {
            let p = ws.lowercased().split(separator: "x")
            if p.count == 2, let w = Double(p[0]), let h = Double(p[1]) { size = NSSize(width: w, height: h) }
        }
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MagiCal"
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
        // Dev/screenshot affordance: open the Help window on launch (used to capture Help GIFs/screens).
        if ProcessInfo.processInfo.environment["CC_OPEN_HELP"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showHelp(nil) }
        }
        if ProcessInfo.processInfo.environment["CC_OPEN_TUTORIAL"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NotificationCenter.default.post(name: .showTutorial, object: nil) }
        }
        // Dev: fire File ▸ Print… a few seconds in (pair with CC_PRINT_PDF to verify the pipeline headless).
        if ProcessInfo.processInfo.environment["CC_PRINT_ON_LAUNCH"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { NotificationCenter.default.post(name: .requestPrint, object: nil) }
        }
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
        let name = "MagiCal"
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        let about = appMenu.addItem(withTitle: "About \(name)", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        appMenu.addItem(.separator())
        // ⌘, — target self explicitly: the app delegate isn't in the responder chain by default.
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File menu — Print… (⌘P). (Import/export will join this menu when FileCommands is wired up.)
        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        let print = fileMenu.addItem(withTitle: "Print…", action: #selector(requestPrint(_:)), keyEquivalent: "p")
        print.target = self

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
        // Top group: jump to TODAY at each zoom level (the web View menu's This Year/Month/Week/Today).
        for (title, sel) in [("Go to Current Year", #selector(goToCurrentYear(_:))),
                             ("Go to Current Month", #selector(goToCurrentMonth(_:))),
                             ("Go to Current Week", #selector(goToCurrentWeek(_:))),
                             ("Go to Current Day", #selector(goToCurrentDay(_:)))] {
            viewMenu.addItem(withTitle: title, action: sel, keyEquivalent: "").target = self
        }
        viewMenu.addItem(.separator())
        // Checkmark toggle; validateMenuItem (below) reflects the current state each time the menu opens.
        let showHidden = viewMenu.addItem(withTitle: "Show Hidden Imported Events",
                                          action: #selector(toggleShowHiddenImported(_:)), keyEquivalent: "")
        showHidden.target = self
        // View ▸ Filter by Tags — a dynamic submenu (menuNeedsUpdate repopulates it each open with the
        // live tag universe; NSMenu scrolls natively if the list outgrows the screen). Ported from the
        // web's "Tag Filter" flyout; ✓ = shown, semantics are "if any tag is shown, the item shows".
        viewMenu.addItem(.separator())
        let tagItem = viewMenu.addItem(withTitle: "Filter by Tags", action: nil, keyEquivalent: "")
        let tagMenu = NSMenu(title: "Filter by Tags")
        tagMenu.delegate = self
        tagMenu.autoenablesItems = false
        tagItem.submenu = tagMenu
        tagFilterMenu = tagMenu
        tagFilterItem = tagItem
        viewMenu.delegate = self   // retitles "Filter by Tags (Filtered)" when a filter is active
        // Bottom group: Full Screen on its own. An explicit toggleFullScreen: item (responder chain → the
        // window) also stops AppKit from auto-inserting its own copy elsewhere in this menu. The system
        // renames it Enter/Exit to match the window state.
        viewMenu.addItem(.separator())
        let fs = viewMenu.addItem(withTitle: "Enter Full Screen",
                                  action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.control, .command]

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
        NSApp.helpMenu = helpMenu   // marks this as THE Help menu (rightmost; system may add its search field)
        // Apple HIG: "<App> Help" is the first item and opens help to its first page; extras go below it.
        let help = helpMenu.addItem(withTitle: "\(name) Help", action: #selector(showHelp(_:)), keyEquivalent: "?")
        help.target = self
        helpMenu.addItem(.separator())
        let tut = helpMenu.addItem(withTitle: "Welcome to \(name)", action: #selector(showTutorial(_:)), keyEquivalent: "")
        tut.target = self
        let ks = helpMenu.addItem(withTitle: "Keyboard Shortcuts", action: #selector(showKeyboardShortcuts(_:)), keyEquivalent: "")
        ks.target = self

        NSApp.mainMenu = main
    }

    /// Help ▸ MagiCal Help — open (or focus) the in-app Help browser window.
    @objc func showHelp(_ sender: Any?) {
        if helpWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            w.title = "MagiCal Help"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: HelpView())
            w.center()
            helpWindow = w
        }
        helpWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A richer standard About panel (the SPM binary has no Info.plist strings to populate it).
    @objc func showAbout(_ sender: Any?) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let credits = NSAttributedString(
            string: "A zoomable calendar that keeps your schedule, notes, and to-dos together — with a built-in AI assistant.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "MagiCal",
            .applicationVersion: version,
            .credits: credits,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showTutorial(_ sender: Any?) { NotificationCenter.default.post(name: .showTutorial, object: nil) }
    @objc func requestPrint(_ sender: Any?) { NotificationCenter.default.post(name: .requestPrint, object: nil) }
    @objc func showKeyboardShortcuts(_ sender: Any?) { NotificationCenter.default.post(name: .showKeyboardShortcuts, object: nil) }

    // View ▸ Show Hidden Imported Events — flip the shared UserDefaults key + nudge the running calendar to
    // repaint. The @AppStorage in CalendarView also observes this key, but the notification is the reliable
    // cross-actor trigger from this AppKit menu.
    @objc func toggleShowHiddenImported(_ sender: NSMenuItem) {
        let key = PrefKeys.showHiddenImported
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
        NotificationCenter.default.post(name: .calendarViewPrefsChanged, object: nil)
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleShowHiddenImported(_:)) {
            item.state = UserDefaults.standard.bool(forKey: PrefKeys.showHiddenImported) ? .on : .off
        }
        return true
    }

    // ── View ▸ Filter by Tags (dynamic submenu; web's "Tag Filter" flyout, adapted native) ──────────
    private var hiddenTagSet: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: PrefKeys.hiddenTags) ?? []) }
        set {
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: PrefKeys.hiddenTags)
            NotificationCenter.default.post(name: .calendarViewPrefsChanged, object: nil)
        }
    }

    /// Repopulate the tag submenu each time it opens (tags/counts are live); retitle the parent row in
    /// the View menu so an active filter is visible before drilling in.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let hidden = hiddenTagSet
        if menu !== tagFilterMenu {   // the View menu itself → just refresh the parent row's title
            tagFilterItem?.title = hidden.isEmpty ? "Filter by Tags" : "Filter by Tags (Filtered)"
            return
        }
        menu.removeAllItems()
        // The engine owns the tag universe; menus fire on the main thread, where the engine lives.
        let uni = MainActor.assumeIsolated { CalendarEngine.mainInstance?.tagUniverse() }
        guard let uni else {
            menu.addItem(withTitle: "Calendar not loaded", action: nil, keyEquivalent: "").isEnabled = false
            return
        }
        tagAllKeys = uni.rows.map(\.key) + [CalendarEngine.untaggedKey]
        if uni.rows.isEmpty && uni.untagged == 0 {
            menu.addItem(withTitle: "No Tags", action: nil, keyEquivalent: "").isEnabled = false
            return
        }
        for row in uni.rows {   // count-ordered; ✓ = shown (the item participates in the calendar)
            let it = menu.addItem(withTitle: "\(row.label) (\(row.count))",
                                  action: #selector(toggleTagFilter(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = row.key
            it.state = hidden.contains(row.key) ? .off : .on
        }
        let un = menu.addItem(withTitle: "Untagged (\(uni.untagged))",
                              action: #selector(toggleTagFilter(_:)), keyEquivalent: "")
        un.target = self
        un.representedObject = CalendarEngine.untaggedKey
        un.state = hidden.contains(CalendarEngine.untaggedKey) ? .off : .on
        menu.addItem(.separator())
        let all = menu.addItem(withTitle: "Show All", action: #selector(showAllTags(_:)), keyEquivalent: "")
        all.target = self
        all.isEnabled = !hidden.isEmpty
        let none = menu.addItem(withTitle: "Show None", action: #selector(showNoTags(_:)), keyEquivalent: "")
        none.target = self
    }

    // View ▸ Go to Current … — land on today's period at the named zoom level (engine lives on the
    // main actor; menu actions fire on the main thread).
    @objc func goToCurrentYear(_ sender: Any?)  { MainActor.assumeIsolated { CalendarEngine.mainInstance?.goToCurrent("year") } }
    @objc func goToCurrentMonth(_ sender: Any?) { MainActor.assumeIsolated { CalendarEngine.mainInstance?.goToCurrent("month") } }
    @objc func goToCurrentWeek(_ sender: Any?)  { MainActor.assumeIsolated { CalendarEngine.mainInstance?.goToCurrent("week") } }
    @objc func goToCurrentDay(_ sender: Any?)   { MainActor.assumeIsolated { CalendarEngine.mainInstance?.goToCurrent("day") } }

    @objc func toggleTagFilter(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        var h = hiddenTagSet
        if h.contains(key) { h.remove(key) } else { h.insert(key) }
        hiddenTagSet = h
    }
    @objc func showAllTags(_ sender: Any?) { hiddenTagSet = [] }
    @objc func showNoTags(_ sender: Any?) { hiddenTagSet = Set(tagAllKeys) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
