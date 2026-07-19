// The macOS app shell. All the calendar lives in the CalendarKit package; this just
// hosts CalendarView in a WindowGroup so Xcode gives us a proper debuggable .app.

import SwiftUI
import AppKit
import CalendarUI
import CalendarEngine

@main
struct CalendarApp: App {
    // The persisted conversation list, shared by BOTH assistant sessions below.
    @State private var chatStore: ConversationStore
    // The standalone chat window's session. Lives at app level (not in a window) so it persists
    // while the window is closed and while only the menu bar is present.
    @State private var assistant: AssistantState
    // The quick-ask callout's OWN session — independent thread from the window's (a new chat in
    // the window never switches the callout), but recorded in the same store/sidebar.
    @State private var quickAssistant: AssistantState

    // The one calendar engine, owned at app level so BOTH the calendar window and the standalone
    // chat window read the same live state — the assistant's read-only calendar context reflects
    // whatever the calendar is currently showing.
    @State private var engine = CalendarEngine()
    // Keeps the File ▸ Close item pinned to the bottom of the File menu (retained so its delegate lives).
    @State private var fileMenuCloseRelocator = FileMenuCloseRelocator()

    init() {
        let store = ConversationStore()
        _chatStore = State(initialValue: store)
        _assistant = State(initialValue: AssistantState(store: store))
        _quickAssistant = State(initialValue: AssistantState(store: store))
        // Reconcile preferences with iCloud at launch (KVS/UserDefaults only — no NSApp access,
        // so it's safe this early). This build carries the ubiquity-kvstore entitlement, so
        // synced prefs actually follow the user across their devices (see AppSettings.swift).
        // The appearance itself is applied in .onAppear below, once NSApp is up.
        PrefsSync.shared.start()
    }

    var body: some Scene {
        WindowGroup(id: "calendar") {
            CalendarView(engine: engine, assistant: quickAssistant, windowAssistant: assistant)
                .frame(minWidth: 900, minHeight: 600)
                // Translucent window material → the calendar picks up the macOS 26
                // wallpaper tint (and the frosted masks read as glass over it). The
                // toolbar (breadcrumb + glass buttons) lives inside CalendarView.
                .containerBackground(.windowBackground, for: .window)
                // Apply the reconciled Light/Dark choice once the app is running (doing this in
                // App.init() would touch NSApp before it exists and crash).
                .onAppear {
                    applyPersistedAppearance()
                    quickAssistant.engine = engine   // the callout's session needs the engine too
                    assistant.engine = engine
                    // The calendar is a single-window app — no window tabs. Turning off automatic
                    // tabbing removes the View/Window menu's "Show Tab Bar / Show All Tabs / Move Tab…"
                    // items. Idempotent; safe to set on every appearance.
                    NSWindow.allowsAutomaticWindowTabbing = false
                    // Move the default File ▸ Close (⌘W) to the bottom of the File menu (SwiftUI injects it
                    // at the top), matching the dev shell's spec-driven placement.
                    fileMenuCloseRelocator.install()
                }
        }
        .defaultSize(width: 1440, height: 840)
        .windowToolbarStyle(.unified(showsTitle: false))   // thick, Safari/Finder-style bar
        .commands {
            // ⌘I (I for AI) → open the standalone Calendar AI window from anywhere in the app.
            // A menu command's key equivalent fires whenever the app is active, across any window.
            CommandGroup(after: .appInfo) {
                OpenAssistantCommand(engine: engine)
            }
            // Remove SwiftUI's default File → New Window (⌘N). ⌘N is our "new event at the block
            // cursor" shortcut (handled by the calendar's key monitor); otherwise it also spawns a
            // new window.
            CommandGroup(replacing: .newItem) { }
            // File menu: the open-calendar ("document") controls, then import an .ics calendar and
            // import/export a backup. Contents live in CalendarUI (CalendarMenuContent / FileCommands);
            // `.importExport` lands them in the standard File menu.
            CommandGroup(replacing: .importExport) {
                CalendarMenuContent(engine: engine)
                Divider()
                FileCommands(engine: engine)
            }
            // File ▸ Print… (⌘P): the YEAR view prints via the system panel; other levels show a notice.
            // Title/shortcut + the action (post .requestPrint) come from the shared AppMenu spec.
            CommandGroup(replacing: .printItem) {
                MenuActionButton(.printCalendar, engine: engine)
            }
            // ⌘Z / ⌘⇧Z — the SINGLE undo/redo handler (the calendar's key monitor deliberately passes these
            // through so they don't fire twice). A focused text field does its own native undo via `undo:`;
            // otherwise call the engine DIRECTLY — not via the responder chain — so undo works even when the
            // canvas isn't first responder (e.g. right after an inline title rename hands focus back). Titles
            // come from the shared spec (StandardItem); the routing is host-specific so it stays here.
            CommandGroup(replacing: .undoRedo) {
                Button { routeUndoRedo(redo: false, engine: engine) } label: { Label(StandardItem.undo.title, systemImage: "arrow.uturn.backward") }
                    .keyboardShortcut("z", modifiers: .command)
                Button { routeUndoRedo(redo: true, engine: engine) } label: { Label(StandardItem.redo.title, systemImage: "arrow.uturn.forward") }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            // Deselect All (⌘D). "Select All" (⌘A) is the standard Edit item, handled by the calendar canvas's
            // `selectAll(_:)` responder. Both also flow through the key monitor so they work regardless of focus.
            CommandGroup(after: .pasteboard) {
                MenuActionButton(.deselectAll, engine: engine)
            }
            // The View menu payload (go-to-today, show-hidden, timezone pickers, tag filter) is defined ONCE
            // in CalendarUI (ViewMenuContent) and shared with the dev shell's View menu. REPLACING the
            // .toolbar group also strips its "Show/Customize Toolbar" items — the calendar's toolbar is fixed.
            // (SwiftUI still supplies Enter/Exit Full Screen itself; window-tab items are removed separately.)
            CommandGroup(replacing: .toolbar) {
                ViewMenuContent(engine: engine)
            }
            // A top-level "Assistant" menu — new/current conversation, model selection, API keys. Its
            // contents live in CalendarUI (AICommands) so they can read the internal assistant model catalog.
            CommandMenu("Assistant") {
                AICommands(assistant: assistant)
            }
            // A top-level "Sync" menu: when iCloud last synced + a manual refresh (Apple Calendar
            // import + iCloud fetch/push). The label re-renders each minute via the monitor's ticker.
            CommandMenu("Sync") {
                ConnectivityMenu(engine: engine)
            }
            // Standard macOS Help menu (kept at the end). Per Apple HIG, "<App> Help" is the first item
            // and opens the in-app Help browser window; the tutorial + ⌘K shortcut guide sit below it. All
            // titles/shortcuts/actions come from the shared AppMenu spec.
            CommandGroup(replacing: .help) {
                OpenHelpCommand()   // "MagiCal Help" (⌘?) → opens the HelpView window
                Divider()
                MenuActionButton(.tutorial, engine: engine)
                MenuActionButton(.keyboardShortcuts, engine: engine)
            }
        }

        // Native macOS Settings scene → the standard ⌘, preferences window with toolbar tabs.
        Settings {
            SettingsView()
        }

        // The standalone "Calendar AI" chat window — a separate, draggable window opened from the
        // toolbar sparkles button or the menu-bar item. Independent of the calendar window.
        Window("MagiCal AI", id: "assistant") {
            AssistantWindowView(state: assistant, callout: quickAssistant)
                .onAppear {
                    applyPersistedAppearance()
                    assistant.engine = engine        // share the live engine → read-only calendar context
                    quickAssistant.engine = engine   // (in case the chat window opens first)
                }
        }
        .defaultSize(width: 420, height: 640)   // slim, chat-only by default (sidebar starts closed)
        .windowResizability(.contentMinSize)

        // The in-app Help browser — its own window (matches the AppKit dev shell's Help ▸ MagiCal Help).
        // A single-instance window: opening it again just refocuses it. Content is HelpView (CalendarUI).
        Window("MagiCal Help", id: "help") {
            HelpView()
                .onAppear { applyPersistedAppearance() }
        }
        .defaultSize(width: 860, height: 620)
        .windowResizability(.contentMinSize)

        // Menu-bar item (top-right) → a small dropdown. Its presence keeps the app alive when all
        // windows are closed, so the chat can be opened without (or outliving) the calendar window.
        MenuBarExtra("MagiCal AI", systemImage: "sparkles") {
            MenuBarContent(assistant: assistant)
        }
    }
}

/// Moves the default File ▸ Close (⌘W) item SwiftUI injects at the TOP of the File menu down to the
/// bottom, out of the way of the calendar/document actions. A one-shot move is unreliable (SwiftUI builds
/// the menu lazily and can rebuild it when our dynamic File content changes), so this attaches as the File
/// menu's delegate and re-positions on every open. The File menu is found locale-independently by our own
/// "New MagiCal" item; a ⌘W match (plus the performClose action) catches Close whatever selector SwiftUI
/// gives it. Mirrors the dev shell, where the spec puts Close at the bottom of File.
@MainActor final class FileMenuCloseRelocator: NSObject, NSMenuDelegate {
    func install(attempt: Int = 0) {
        if let file = findFileMenu() {
            relocate(file)
            file.delegate = self   // re-position on every open (survives SwiftUI rebuilding the menu)
        } else if attempt < 12 {   // menu bar not built yet → retry briefly
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.install(attempt: attempt + 1) }
        }
    }
    func menuNeedsUpdate(_ menu: NSMenu) { relocate(menu) }

    private func findFileMenu() -> NSMenu? {
        for top in NSApp.mainMenu?.items ?? [] {
            if let sub = top.submenu, sub.items.contains(where: { $0.title == MenuItemID.newCalendar.title }) {
                return sub
            }
        }
        return nil
    }
    /// Collapse any Close item(s) to exactly one, at the bottom (after a separator). Idempotent: once
    /// Close is last, re-running leaves it in place.
    private func relocate(_ menu: NSMenu) {
        let closes = menu.items.filter(isClose)
        guard !closes.isEmpty else { return }
        for c in closes { menu.removeItem(c) }
        if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
        menu.addItem(closes[0])
    }
    private func isClose(_ item: NSMenuItem) -> Bool {
        item.action == #selector(NSWindow.performClose(_:))
            || (item.keyEquivalent == "w" && item.keyEquivalentModifierMask == [.command])
    }
}

/// ⌘Z / ⌘⇧Z routing. A focused text field / editor keeps its own native undo (via the `undo:`/`redo:`
/// responder-chain selectors); anywhere else, undo the calendar engine directly. Calling the engine
/// directly (rather than sending `undo:` to the chain) means it works even when the canvas isn't first
/// responder — the case that made an inline title rename look un-undoable.
@MainActor private func routeUndoRedo(redo: Bool, engine: CalendarEngine) {
    if engine.inputModalUp { return }   // a blocking modal (delete confirm) is up → ignore undo/redo
    if firstResponderIsTextInput() {
        NSApp.sendAction(NSSelectorFromString(redo ? "redo:" : "undo:"), to: nil, from: nil)
    } else {
        redo ? engine.redo() : engine.undo()
    }
}

/// Is the key window's first responder a text-editing view (field editor, text field, or the notes
/// WKWebView's content view)? Then ⌘Z belongs to it, not the calendar.
@MainActor private func firstResponderIsTextInput() -> Bool {
    guard let r = NSApp.keyWindow?.firstResponder else { return false }
    if r is NSText { return true }
    let cls = String(describing: type(of: r))
    return cls.contains("TextView") || cls.contains("TextField") || cls.contains("WKContent")
}

/// The "Connectivity" menu's contents: a disabled "Last Synced" line + a "Sync Now" action. A dedicated
/// view so it can observe the engine's `syncMonitor` (@Observable) and refresh the relative-time label.
private struct ConnectivityMenu: View {
    let engine: CalendarEngine
    var body: some View {
        Text(lastSyncedLabel)   // plain Text → a disabled info row in the menu
        Button { engine.refreshConnectivity() } label: {
            Label(engine.syncMonitor.isSyncing ? "Syncing…" : "Sync Now", systemImage: "arrow.triangle.2.circlepath")
        }
        .keyboardShortcut("r", modifiers: .command) // matches AppMenu's .syncNow spec (⌘R, dev shell)
        .disabled(engine.syncMonitor.isSyncing)
    }
    private var lastSyncedLabel: String {
        _ = engine.syncMonitor.minuteTick   // depend on the tick so a Today→Yesterday rollover refreshes
        guard engine.syncMonitor.cloudEnabled else { return "iCloud: Local only" }
        guard let at = engine.syncMonitor.lastSyncedAt else { return "Last Sync: never" }
        let cal = Calendar.current
        let time = at.formatted(date: .omitted, time: .shortened)   // locale-aware "12:35 PM" / "12:35"
        let day: String
        if cal.isDateInToday(at) { day = "Today" }
        else if cal.isDateInYesterday(at) { day = "Yesterday" }
        else { day = at.formatted(date: .abbreviated, time: .omitted) }
        return "Last Sync: \(day), \(time)"
    }
}

/// The ⌘I menu command that opens the Calendar AI window. A dedicated view so
/// `@Environment(\.openWindow)` resolves inside the command builder.
private struct OpenAssistantCommand: View {
    let engine: CalendarEngine
    @Environment(\.openWindow) private var openWindow
    // Published by CalendarView (and by the open callout itself): present while a calendar window
    // is key → ⌘I toggles the quick-ask callout; absent (menu-bar only / chat window key) → ⌘I
    // opens the standalone window as before.
    @FocusedBinding(\.assistantCallout) private var callout: Bool?

    var body: some View {
        Button {
            guard !engine.inputModalUp else { return }   // blocked while a modal is up
            if callout != nil { callout = !(callout ?? false) }
            else { openWindow(id: "assistant") }
        } label: {
            menuLabel(.openAssistant)   // "MagiCal AI" + sparkles, from the shared spec
        }
        .modifier(OptionalShortcut(s: MenuItemID.openAssistant.shortcut))
    }
}

/// Help ▸ "MagiCal Help" (⌘?) — opens the in-app Help browser window. A dedicated view so
/// `@Environment(\.openWindow)` resolves inside the command builder (mirrors OpenAssistantCommand).
private struct OpenHelpCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button { openWindow(id: "help") } label: { menuLabel(.help) }   // "MagiCal Help" + icon, from the spec
            .modifier(OptionalShortcut(s: MenuItemID.help.shortcut))
    }
}

/// The menu-bar dropdown. A dedicated view so `@Environment(\.openWindow)` resolves (it isn't
/// reliably populated directly on the `App` type).
private struct MenuBarContent: View {
    let assistant: AssistantState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button { openWindow(id: "assistant") } label: { Label("Open MagiCal AI", systemImage: "sparkles") }
        Button { assistant.newChat(); openWindow(id: "assistant") } label: { Label("New Chat", systemImage: "square.and.pencil") }
        Divider()
        Button { openWindow(id: "calendar") } label: { Label("Show MagiCal", systemImage: "calendar") }
        SettingsLink { Label("Settings…", systemImage: "gearshape") }
        Divider()
        Button { NSApplication.shared.terminate(nil) } label: { Label("Quit MagiCal", systemImage: "power") }
    }
}
