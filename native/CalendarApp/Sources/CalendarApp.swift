// The macOS app shell. All the calendar lives in the CalendarKit package; this just
// hosts CalendarView in a WindowGroup so Xcode gives us a proper debuggable .app.

import SwiftUI
import AppKit
import CalendarUI

@main
struct CalendarApp: App {
    init() {
        // Reconcile preferences with iCloud at launch (KVS/UserDefaults only — no NSApp access,
        // so it's safe this early). This build carries the ubiquity-kvstore entitlement, so
        // synced prefs actually follow the user across their devices (see AppSettings.swift).
        // The appearance itself is applied in .onAppear below, once NSApp is up.
        PrefsSync.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            CalendarView()
                .frame(minWidth: 900, minHeight: 600)
                // Translucent window material → the calendar picks up the macOS 26
                // wallpaper tint (and the frosted masks read as glass over it). The
                // toolbar (breadcrumb + glass buttons) lives inside CalendarView.
                .containerBackground(.windowBackground, for: .window)
                // Apply the reconciled Light/Dark choice once the app is running (doing this in
                // App.init() would touch NSApp before it exists and crash).
                .onAppear { applyPersistedAppearance() }
        }
        .defaultSize(width: 1440, height: 840)
        .windowToolbarStyle(.unified(showsTitle: false))   // thick, Safari/Finder-style bar
        .commands {
            // Remove SwiftUI's default File → New Window (⌘N). ⌘N is our "new event at the block
            // cursor" shortcut (handled by the calendar's key monitor); otherwise it also spawns a
            // new window.
            CommandGroup(replacing: .newItem) { }
            // Undo/redo route down the responder chain to the calendar input view,
            // which implements performUndo:/performRedo: (see CalendarView.swift).
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { NSApp.sendAction(Selector(("performUndo:")), to: nil, from: nil) }
                    .keyboardShortcut("z", modifiers: .command)
                Button("Redo") { NSApp.sendAction(Selector(("performRedo:")), to: nil, from: nil) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
        }

        // Native macOS Settings scene → the standard ⌘, preferences window with toolbar tabs.
        Settings {
            SettingsView()
        }
    }
}
