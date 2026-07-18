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
                Button("Undo") { routeUndoRedo(redo: false, engine: engine) }
                    .keyboardShortcut("z", modifiers: .command)
                Button("Redo") { routeUndoRedo(redo: true, engine: engine) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            // A top-level "View" menu — display preferences (stored in UserDefaults, shared with the renderer).
            CommandMenu("View") {
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
                Button("Tutorial") {
                    NotificationCenter.default.post(name: .showTutorial, object: nil)
                }
                Button("Keyboard Shortcuts") {
                    NotificationCenter.default.post(name: .showKeyboardShortcuts, object: nil)
                }
            }
        }

        // Native macOS Settings scene → the standard ⌘, preferences window with toolbar tabs.
        Settings {
            SettingsView()
        }

        // The standalone "Calendar AI" chat window — a separate, draggable window opened from the
        // toolbar sparkles button or the menu-bar item. Independent of the calendar window.
        Window("Calendar AI", id: "assistant") {
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
        MenuBarExtra("Calendar AI", systemImage: "sparkles") {
            MenuBarContent(assistant: assistant)
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
        NSApp.sendAction(Selector((redo ? "redo:" : "undo:")), to: nil, from: nil)
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
    var body: some View {
        Toggle("Show Hidden Imported Events", isOn: $showHidden)
    }
}

/// The "Connectivity" menu's contents: a disabled "Last Synced" line + a "Sync Now" action. A dedicated
/// view so it can observe the engine's `syncMonitor` (@Observable) and refresh the relative-time label.
private struct ConnectivityMenu: View {
    let engine: CalendarEngine
    var body: some View {
        Text(lastSyncedLabel)   // plain Text → a disabled info row in the menu
        Button(engine.syncMonitor.isSyncing ? "Syncing…" : "Sync Now") { engine.refreshConnectivity() }
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
        Button("Calendar AI") {
            guard !engine.inputModalUp else { return }   // blocked while a modal is up
            if callout != nil { callout = !(callout ?? false) }
            else { openWindow(id: "assistant") }
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
        Button("Open Calendar AI") { openWindow(id: "assistant") }
        Button("New Chat") { assistant.newChat(); openWindow(id: "assistant") }
        Divider()
        Button("Show Calendar") { openWindow(id: "calendar") }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Calendar") { NSApplication.shared.terminate(nil) }
    }
}
