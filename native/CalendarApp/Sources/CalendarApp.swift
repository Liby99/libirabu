// The macOS app shell. All the calendar lives in the CalendarKit package; this just
// hosts CalendarView in a WindowGroup so Xcode gives us a proper debuggable .app.

import SwiftUI
import AppKit
import CalendarUI

@main
struct CalendarApp: App {
    var body: some Scene {
        WindowGroup {
            CalendarView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 840)
        .commands {
            // Undo/redo route down the responder chain to the calendar input view,
            // which implements performUndo:/performRedo: (see CalendarView.swift).
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { NSApp.sendAction(Selector(("performUndo:")), to: nil, from: nil) }
                    .keyboardShortcut("z", modifiers: .command)
                Button("Redo") { NSApp.sendAction(Selector(("performRedo:")), to: nil, from: nil) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
        }
    }
}
