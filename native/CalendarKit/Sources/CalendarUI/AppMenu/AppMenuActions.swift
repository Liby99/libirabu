// The shared, API-agnostic behavior behind each plain menu item. Both the SwiftUI and AppKit adapters
// call `runMenuItem` so an item does exactly the same thing in both shells. Everything here is either a
// NotificationCenter post, an engine call, a UserDefaults flip, or an NSApp/window action — all of which
// work identically from either host. Window-opening is the one host-specific bit, injected as a closure.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CalendarEngine
import CalendarGeometry   // isoDayString

/// Which host window a menu action wants to summon (opened differently per shell).
public enum MenuWindow: Sendable { case assistant, help, settings }

/// The host-provided hooks the shared actions need. `engine` is a getter (the AppKit shell resolves it
/// lazily via `CalendarEngine.mainInstance`; the .app captures its live instance).
@MainActor public struct MenuContext {
    public var engine: () -> CalendarEngine?
    public var open: (MenuWindow) -> Void
    public var newChat: () -> Void
    public var showAbout: () -> Void
    public init(engine: @escaping () -> CalendarEngine?,
                open: @escaping (MenuWindow) -> Void,
                newChat: @escaping () -> Void = {},
                showAbout: @escaping () -> Void = {}) {
        self.engine = engine; self.open = open; self.newChat = newChat; self.showAbout = showAbout
    }
}

/// Run a plain menu item's action. Identical behavior in both shells.
@MainActor public func runMenuItem(_ id: MenuItemID, _ ctx: MenuContext) {
    switch id {
    case .about:               ctx.showAbout()
    case .openAssistant:       ctx.open(.assistant)
    case .settings:            ctx.open(.settings)
    case .hide:                NSApp.hide(nil)
    case .quit:                NSApp.terminate(nil)
    case .importICS:           if let e = ctx.engine() { MenuFileActions.importICS(e) }
    case .importMDC:           if let e = ctx.engine() { MenuFileActions.importMDC(e) }
    case .exportMDC:           if let e = ctx.engine() { MenuFileActions.exportMDC(e) }
    case .printCalendar:       NotificationCenter.default.post(name: .requestPrint, object: nil)
    case .deselectAll:         ctx.engine()?.deselectAll()
    case .goToYear:            ctx.engine()?.goToCurrent("year")
    case .goToMonth:           ctx.engine()?.goToCurrent("month")
    case .goToWeek:            ctx.engine()?.goToCurrent("week")
    case .goToDay:             ctx.engine()?.goToCurrent("day")
    case .newConversation:     ctx.newChat(); ctx.open(.assistant)
    case .currentConversation: ctx.open(.assistant)
    case .apiKeys:             ctx.open(.settings)
    case .syncNow:             ctx.engine()?.refreshConnectivity()
    case .help:                ctx.open(.help)
    case .tutorial:            NotificationCenter.default.post(name: .showTutorial, object: nil)
    case .keyboardShortcuts:   NotificationCenter.default.post(name: .showKeyboardShortcuts, object: nil)
    case .closeWindow:         NSApp.keyWindow?.performClose(nil)
    case .minimize:            NSApp.keyWindow?.performMiniaturize(nil)
    }
}

// ── File ▸ import/export. AppKit panels + alerts; the work is on the engine. Shared so both the SwiftUI
//    FileCommands view and the AppKit menu run the exact same code. ─────────────────────────────────
@MainActor public enum MenuFileActions {
    public static func importICS(_ engine: CalendarEngine) {
        guard let url = openPanel([UTType(filenameExtension: "ics") ?? .plainText, .plainText]) else { return }
        do {
            let n = try engine.importICS(from: url)
            info("Imported \(n) item\(n == 1 ? "" : "s") from “\(url.lastPathComponent)”.")
        } catch { report("Couldn’t import that .ics file.", error) }
    }

    public static func importMDC(_ engine: CalendarEngine) {
        let mdc = UTType(filenameExtension: "mdc") ?? .data
        guard let url = openPanel([mdc, .zip]) else { return }
        let a = NSAlert()
        a.messageText = "Replace all calendar data?"
        a.informativeText = "Importing “\(url.lastPathComponent)” replaces your current events, deadlines, notes, and track names with the backup’s contents. You can undo this with ⌘Z."
        a.alertStyle = .warning
        a.addButton(withTitle: "Replace")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do { try engine.importMDC(from: url) }
        catch { report("Couldn’t import that backup.", error) }
    }

    public static func exportMDC(_ engine: CalendarEngine) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mdc") ?? .data]
        panel.nameFieldStringValue = "MagiCal-\(isoDayString()).mdc"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try engine.exportMDC(to: url) }
        catch { report("Couldn’t export the backup.", error) }
    }

    private static func openPanel(_ types: [UTType]) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }
    private static func info(_ text: String) {
        let a = NSAlert(); a.messageText = text; a.alertStyle = .informational; a.addButton(withTitle: "OK"); a.runModal()
    }
    private static func report(_ text: String, _ error: Error) {
        let a = NSAlert(); a.messageText = text
        a.informativeText = error.localizedDescription
        a.alertStyle = .warning; a.addButton(withTitle: "OK"); a.runModal()
    }
}
