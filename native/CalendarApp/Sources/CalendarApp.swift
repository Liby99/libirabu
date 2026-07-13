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
                // Translucent window material → the calendar picks up the macOS 26
                // wallpaper tint (and the frosted masks read as glass over it).
                .containerBackground(.windowBackground, for: .window)
                .toolbar {
                    // Leading (right of the traffic lights): the zoom breadcrumb.
                    ToolbarItem(placement: .navigation) { Breadcrumb() }
                    // Trailing: search · AI · Today. Liquid Glass, no-op for now.
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { } label: { Image(systemName: "magnifyingglass") }
                            .buttonStyle(.glass).buttonBorderShape(.circle)
                            .help("Search")
                        Button { } label: { Image(systemName: "sparkles") }
                            .buttonStyle(.glass).buttonBorderShape(.circle)
                            .help("Assistant")
                        Button { } label: { Text("Today") }
                            .buttonStyle(.glass).buttonBorderShape(.capsule)
                    }
                }
        }
        .defaultSize(width: 1280, height: 840)
        .windowToolbarStyle(.unified(showsTitle: false))   // thick, Safari/Finder-style bar
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

/// Year › Month › Week › Day breadcrumb. Layout only for now (no-op buttons).
private struct Breadcrumb: View {
    private let levels = ["Year", "Month", "Week", "Day"]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, name in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                Button(name) { }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 4)
    }
}
