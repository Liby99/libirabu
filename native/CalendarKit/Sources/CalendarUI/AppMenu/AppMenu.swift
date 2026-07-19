// The SINGLE SOURCE OF TRUTH for the app's menu bar.
//
// Both macOS shells render their menu bar from `AppMenu.sections(...)`:
//   • CalendarApp (the Xcode .app)  → a SwiftUI `Commands` adapter (AppMenuCommands.swift)
//   • CalendarMac (the dev shell)   → an AppKit `NSMenu` adapter    (AppMenuAppKit.swift)
// Because both read this one declaration, the two menu bars cannot silently drift — add or retitle
// an item here and both shells pick it up. Titles, shortcuts, icons, ordering, and the (shared,
// API-agnostic) action for each item all live here.
//
// What is NOT here (genuinely per-target): the *rendering* itself (SwiftUI Button vs NSMenuItem),
// and a few SwiftUI-only host constructs (the Settings scene, the MenuBarExtra status item). The
// Assistant menu + AI item require an assistant session, which only the .app has — so those nodes
// are gated behind `caps.hasAssistant` and simply omitted from the dev shell.

import AppKit
import CalendarEngine

// ── Shortcut description (API-neutral; each adapter converts to its own modifier type) ──────────
public struct MenuMods: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = MenuMods(rawValue: 1 << 0)
    public static let shift   = MenuMods(rawValue: 1 << 1)
    public static let control = MenuMods(rawValue: 1 << 2)
    public static let option  = MenuMods(rawValue: 1 << 3)
}

public struct MenuShortcut: Sendable {
    public let key: Character
    public let mods: MenuMods
    public init(_ key: Character, _ mods: MenuMods = .command) { self.key = key; self.mods = mods }
}

// ── The plain (button) items. Each carries its own title / shortcut / SF Symbol. ────────────────
public enum MenuItemID: Sendable {
    case about, openAssistant, settings, hide, quit
    case importICS, importMDC, exportMDC, printCalendar
    case deselectAll
    case goToYear, goToMonth, goToWeek, goToDay
    case newConversation, currentConversation, apiKeys
    case syncNow
    case help, tutorial, keyboardShortcuts
    case closeWindow, minimize

    public static let appName = "MagiCal"

    public var title: String {
        switch self {
        case .about:               return "About \(Self.appName)"
        case .openAssistant:       return "\(Self.appName) AI"
        case .settings:            return "Settings…"
        case .hide:                return "Hide \(Self.appName)"
        case .quit:                return "Quit \(Self.appName)"
        case .importICS:           return "Import .ics…"
        case .importMDC:           return "Import Backup (.mdc)…"
        case .exportMDC:           return "Export Backup (.mdc)…"
        case .printCalendar:       return "Print…"
        case .deselectAll:         return "Deselect All"
        case .goToYear:            return "Go to Current Year"
        case .goToMonth:           return "Go to Current Month"
        case .goToWeek:            return "Go to Current Week"
        case .goToDay:             return "Go to Current Day"
        case .newConversation:     return "New Conversation"
        case .currentConversation: return "Current Conversation"
        case .apiKeys:             return "Configure API Keys…"
        case .syncNow:             return "Sync Now"
        case .help:                return "\(Self.appName) Help"
        case .tutorial:            return "Welcome to \(Self.appName)"
        case .keyboardShortcuts:   return "Keyboard Shortcuts"
        case .closeWindow:         return "Close"
        case .minimize:            return "Minimize"
        }
    }

    public var shortcut: MenuShortcut? {
        switch self {
        case .openAssistant: return MenuShortcut("i")
        case .settings:      return MenuShortcut(",")
        case .hide:          return MenuShortcut("h")
        case .quit:          return MenuShortcut("q")
        case .printCalendar: return MenuShortcut("p")
        case .deselectAll:   return MenuShortcut("d")
        case .help:          return MenuShortcut("?")
        case .closeWindow:   return MenuShortcut("w")
        case .minimize:      return MenuShortcut("m")
        default:             return nil
        }
    }

    /// SF Symbol for the SwiftUI `Label` (AppKit ignores it). nil = no icon.
    public var icon: String? {
        switch self {
        case .openAssistant:       return "sparkles"
        case .importICS:           return "calendar.badge.plus"
        case .importMDC:           return "square.and.arrow.down"
        case .exportMDC:           return "square.and.arrow.up"
        case .deselectAll:         return "square.dashed"
        case .newConversation:     return "square.and.pencil"
        case .currentConversation: return "bubble.left"
        case .apiKeys:             return "key"
        case .syncNow:             return "arrow.triangle.2.circlepath"
        case .help:                return "questionmark.circle"
        case .tutorial:            return "graduationcap"
        case .keyboardShortcuts:   return "keyboard"
        default:                   return nil
        }
    }
}

// ── Standard responder-chain Edit items. SwiftUI provides these itself; AppKit wires the selectors. ──
public enum StandardItem: Sendable {
    case undo, redo, cut, copy, paste, selectAll
    public var title: String {
        switch self {
        case .undo: return "Undo"; case .redo: return "Redo"
        case .cut: return "Cut"; case .copy: return "Copy"; case .paste: return "Paste"
        case .selectAll: return "Select All"
        }
    }
    public var shortcut: MenuShortcut {
        switch self {
        case .undo: return MenuShortcut("z")
        case .redo: return MenuShortcut("z", [.command, .shift])
        case .cut:  return MenuShortcut("x"); case .copy: return MenuShortcut("c")
        case .paste: return MenuShortcut("v"); case .selectAll: return MenuShortcut("a")
        }
    }
    /// The AppKit responder selector name (SwiftUI routes these automatically).
    public var selector: String {
        switch self {
        case .undo: return "undo:"; case .redo: return "redo:"
        case .cut: return "cut:"; case .copy: return "copy:"; case .paste: return "paste:"
        case .selectAll: return "selectAll:"
        }
    }
}

// ── Rich controls that each adapter renders in its own idiom (pickers, dynamic submenus, toggles). ──
public enum MenuWidget: Sendable {
    case showHiddenToggle      // View ▸ Show Hidden Imported Events (checkmark)
    case currentTimezone       // View ▸ Current Timezone ▸ (picker)
    case altTimezone           // View ▸ Alternative Timezone ▸ (picker)
    case tagFilter             // View ▸ Filter by Tags ▸ (dynamic submenu)
    case fullScreen            // View ▸ Enter/Exit Full Screen (system)
    case assistantModel        // Assistant ▸ Model ▸ (picker)
    case syncStatus            // Sync ▸ "Last Sync: …" (disabled info row, dynamic)
}

// ── One node in a menu. ─────────────────────────────────────────────────────────────────────────
public enum MenuNode: Sendable {
    case item(MenuItemID)
    case standard(StandardItem)
    case widget(MenuWidget)
    case separator
}

// ── A whole menu, tagged with where it lands in each host. ──────────────────────────────────────
public enum MenuPlacement: Sendable { case app, file, edit, view, assistant, sync, window, help }

public struct MenuSection: Sendable {
    public let placement: MenuPlacement
    public let title: String            // the menu's title (also the AppKit submenu title)
    public let nodes: [MenuNode]
    public init(_ placement: MenuPlacement, _ title: String, _ nodes: [MenuNode]) {
        self.placement = placement; self.title = title; self.nodes = nodes
    }
}

public struct AppMenuCaps: Sendable {
    /// The host owns an assistant session (only the .app does) → show the AI item + Assistant menu.
    public var hasAssistant: Bool
    public init(hasAssistant: Bool) { self.hasAssistant = hasAssistant }
}

public enum AppMenu {
    /// THE menu-bar declaration. Both shells build their native menu bar by walking this.
    public static func sections(_ caps: AppMenuCaps) -> [MenuSection] {
        var out: [MenuSection] = []

        // App menu — About / AI / Settings / Hide / Quit. (SwiftUI supplies About·Settings·Hide·Quit
        // itself; its adapter renders only the AI item. AppKit builds the whole thing.)
        var app: [MenuNode] = [.item(.about), .separator]
        if caps.hasAssistant { app += [.item(.openAssistant), .separator] }
        app += [.item(.settings), .separator, .item(.hide), .item(.quit)]
        out.append(MenuSection(.app, AppName.app, app))

        // File — import/export + print.
        out.append(MenuSection(.file, "File", [
            .item(.importICS), .separator,
            .item(.importMDC), .item(.exportMDC), .separator,
            .item(.printCalendar),
        ]))

        // Edit — undo/redo, clipboard, (de)select. SwiftUI provides the clipboard + select-all itself;
        // its adapter renders only undo/redo (routed to the engine) and Deselect All.
        out.append(MenuSection(.edit, "Edit", [
            .standard(.undo), .standard(.redo), .separator,
            .standard(.cut), .standard(.copy), .standard(.paste), .separator,
            .standard(.selectAll), .item(.deselectAll),
        ]))

        // View — go-to-today, visibility toggles, timezone pickers, tag filter, full screen.
        out.append(MenuSection(.view, "View", [
            .item(.goToYear), .item(.goToMonth), .item(.goToWeek), .item(.goToDay), .separator,
            .widget(.showHiddenToggle), .separator,
            .widget(.currentTimezone), .widget(.altTimezone), .separator,
            .widget(.tagFilter), .separator,
            .widget(.fullScreen),
        ]))

        // Assistant (app only — the dev shell has no assistant session).
        if caps.hasAssistant {
            out.append(MenuSection(.assistant, "Assistant", [
                .item(.newConversation), .item(.currentConversation), .separator,
                .widget(.assistantModel), .separator,
                .item(.apiKeys),
            ]))
        }

        // Sync — last-synced info + manual refresh.
        out.append(MenuSection(.sync, "Sync", [
            .widget(.syncStatus), .item(.syncNow),
        ]))

        // Window — Close / Minimize (AppKit builds it; SwiftUI manages its own Window menu).
        out.append(MenuSection(.window, "Window", [
            .item(.closeWindow), .item(.minimize),
        ]))

        // Help — help window, tutorial, shortcut guide.
        out.append(MenuSection(.help, "Help", [
            .item(.help), .separator,
            .item(.tutorial), .item(.keyboardShortcuts),
        ]))

        return out
    }
}

private enum AppName { static let app = MenuItemID.appName }
