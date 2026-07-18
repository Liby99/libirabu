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
                    // Drop the default File ▸ Close (⌘W): the menu-bar item keeps the app alive, so a
                    // single persistent window has no meaningful "Close" — it just hides the calendar.
                    removeFileCloseItem()
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
            // File menu: import an .ics calendar, and import/export a .mdc backup. Contents live in
            // CalendarUI (FileCommands); `.importExport` lands them in the standard File menu.
            CommandGroup(replacing: .importExport) {
                FileCommands(engine: engine)
            }
            // ⌘Z / ⌘⇧Z — the SINGLE undo/redo handler (the calendar's key monitor deliberately passes these
            // through so they don't fire twice). A focused text field does its own native undo via `undo:`;
            // otherwise call the engine DIRECTLY — not via the responder chain — so undo works even when the
            // canvas isn't first responder (e.g. right after an inline title rename hands focus back).
            CommandGroup(replacing: .undoRedo) {
                Button { routeUndoRedo(redo: false, engine: engine) } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .keyboardShortcut("z", modifiers: .command)
                Button { routeUndoRedo(redo: true, engine: engine) } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            // Display preferences (stored in UserDefaults, shared with the renderer), placed INTO the
            // native View menu. REPLACING the .toolbar group also strips its "Show/Customize Toolbar"
            // items — the calendar's toolbar is fixed, so those don't apply. (Window-tab items are
            // removed separately by disabling automatic window tabbing; see the window's onAppear.)
            CommandGroup(replacing: .toolbar) {
                ViewMenu()
            }
            // A top-level "AI" menu — new/current conversation, model selection, API keys. Its contents
            // live in CalendarUI (AICommands) so they can read the internal assistant model catalog.
            CommandMenu("AI") {
                AICommands(assistant: assistant)
            }
            // A top-level "Sync" menu: when iCloud last synced + a manual refresh (Apple Calendar
            // import + iCloud fetch/push). The label re-renders each minute via the monitor's ticker.
            CommandMenu("Sync") {
                ConnectivityMenu(engine: engine)
            }
            // Standard macOS Help menu (kept at the end): the onboarding tutorial + the ⌘K shortcut guide.
            CommandGroup(replacing: .help) {
                Button { NotificationCenter.default.post(name: .showTutorial, object: nil) } label: { Label("Tutorial", systemImage: "graduationcap") }
                Button { NotificationCenter.default.post(name: .showKeyboardShortcuts, object: nil) } label: { Label("Keyboard Shortcuts", systemImage: "keyboard") }
            }
        }

        // Native macOS Settings scene → the standard ⌘, preferences window with toolbar tabs.
        Settings {
            SettingsView()
        }

        // The standalone "Calendar AI" chat window — a separate, draggable window opened from the
        // toolbar sparkles button or the menu-bar item. Independent of the calendar window.
        Window("Madocal AI", id: "assistant") {
            AssistantWindowView(state: assistant, callout: quickAssistant)
                .onAppear {
                    applyPersistedAppearance()
                    assistant.engine = engine        // share the live engine → read-only calendar context
                    quickAssistant.engine = engine   // (in case the chat window opens first)
                }
        }
        .defaultSize(width: 420, height: 640)   // slim, chat-only by default (sidebar starts closed)
        .windowResizability(.contentMinSize)

        // Menu-bar item (top-right) → a small dropdown. Its presence keeps the app alive when all
        // windows are closed, so the chat can be opened without (or outliving) the calendar window.
        MenuBarExtra("Madocal AI", systemImage: "sparkles") {
            MenuBarContent(assistant: assistant)
        }
    }
}

/// Remove the default File ▸ Close (⌘W) item SwiftUI adds for the window. Deferred to the next runloop
/// so it runs after the main menu is built. Matches by the `performClose:` action (locale-independent).
@MainActor private func removeFileCloseItem() {
    DispatchQueue.main.async {
        for top in NSApp.mainMenu?.items ?? [] {
            guard let sub = top.submenu else { continue }
            for item in sub.items where item.action == #selector(NSWindow.performClose(_:)) {
                sub.removeItem(item)
            }
        }
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

/// The "View" menu's contents. A Toggle bound to @AppStorage renders as a checkmark menu item and shares
/// the UserDefaults key the renderer reads; CalendarView's own @AppStorage onChange repaints on flip.
private struct ViewMenu: View {
    @AppStorage(CalendarEngine.showHiddenImportedKey) private var showHidden = false
    @AppStorage(CalendarEngine.mainTzKey) private var mainTz = CalendarTimezones.autoId
    @AppStorage(CalendarEngine.altTzKey) private var altTz = "none"
    var body: some View {
        Toggle(isOn: $showHidden) { Label("Show Hidden Imported Events", systemImage: "eye.slash") }
        Divider()
        // "Current Timezone ▸" — drives deadline origin-time labels.
        Picker(selection: $mainTz) {
            ForEach(CalendarTimezones.all) { Text($0.label).tag($0.id) }
        } label: {
            Label("Current Timezone", systemImage: "clock")
        }
        // "Alternative Timezone ▸" — a second dimmed hour column on the week/day/month timeline. "None"
        // hides it; a concrete zone shows it (Automatic/device isn't offered — that would equal Current).
        Picker(selection: $altTz) {
            Text("None").tag("none")
            ForEach(CalendarTimezones.all.filter { $0.id != CalendarTimezones.autoId }) { Text($0.label).tag($0.id) }
        } label: {
            Label("Alternative Timezone", systemImage: "globe")
        }
    }
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
            Label("Madocal AI", systemImage: "sparkles")
        }
        .keyboardShortcut("i", modifiers: .command)
    }
}

/// The menu-bar dropdown. A dedicated view so `@Environment(\.openWindow)` resolves (it isn't
/// reliably populated directly on the `App` type).
private struct MenuBarContent: View {
    let assistant: AssistantState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button { openWindow(id: "assistant") } label: { Label("Open Madocal AI", systemImage: "sparkles") }
        Button { assistant.newChat(); openWindow(id: "assistant") } label: { Label("New Chat", systemImage: "square.and.pencil") }
        Divider()
        Button { openWindow(id: "calendar") } label: { Label("Show Madocal", systemImage: "calendar") }
        SettingsLink { Label("Settings…", systemImage: "gearshape") }
        Divider()
        Button { NSApplication.shared.terminate(nil) } label: { Label("Quit Madocal", systemImage: "power") }
    }
}
