// SwiftUI menu pieces shared by the CalendarApp Commands adapter. Everything here reads titles /
// shortcuts / icons from the AppMenu spec so the .app's menu bar can't drift from the dev shell's.
// The View-menu payload (go-to-today, show-hidden, timezone pickers, tag filter) lives here too, so
// both the item set AND the widgets are defined once.

import SwiftUI
import CalendarEngine

// ── Shortcut conversion (spec → SwiftUI) ────────────────────────────────────────────────────────
public extension MenuShortcut {
    var swiftUIKey: KeyEquivalent { KeyEquivalent(key) }
    var swiftUIModifiers: EventModifiers {
        var m: EventModifiers = []
        if mods.contains(.command) { m.insert(.command) }
        if mods.contains(.shift)   { m.insert(.shift) }
        if mods.contains(.control) { m.insert(.control) }
        if mods.contains(.option)  { m.insert(.option) }
        return m
    }
}

/// Applies a MenuShortcut as a `.keyboardShortcut`, or nothing when the item has none.
public struct OptionalShortcut: ViewModifier {
    let s: MenuShortcut?
    public init(s: MenuShortcut?) { self.s = s }
    public func body(content: Content) -> some View {
        if let s { content.keyboardShortcut(s.swiftUIKey, modifiers: s.swiftUIModifiers) }
        else { content }
    }
}

/// A menu button for a "plain" item whose action is pure (engine call / notification post — no window
/// opening). Label, icon, and shortcut all come from the spec. Used for Print, Deselect All, the
/// Go-to-Current group, Sync Now, Tutorial, and Keyboard Shortcuts.
public struct MenuActionButton: View {
    let id: MenuItemID
    let engine: CalendarEngine
    public init(_ id: MenuItemID, engine: CalendarEngine) { self.id = id; self.engine = engine }
    public var body: some View {
        Button {
            runMenuItem(id, MenuContext(engine: { engine }, open: { _ in }))
        } label: { menuLabel(id) }
        .modifier(OptionalShortcut(s: id.shortcut))
    }
}

// ── File menu: multiple-calendars payload (shared) ──────────────────────────────────────────────
/// The calendar ("document") controls at the top of the File menu: the open-calendar row, New/Remove,
/// the Recently-Opened submenu, and Rename. New/Remove/Rename post notifications → CalendarView shows a
/// dialog; the recents switch directly. Mirrors AppMenu.sections(...)'s File `currentCalendar`/`recentCalendars`.
public struct CalendarMenuContent: View {
    let engine: CalendarEngine
    public init(engine: CalendarEngine) { self.engine = engine }
    public var body: some View {
        Text("Calendar: \(engine.activeCalendarName)")   // disabled info row (plain Text isn't actionable)
        MenuActionButton(.newCalendar, engine: engine)
        MenuActionButton(.removeCalendar, engine: engine).disabled(!engine.canRemoveCalendar)
        Menu {
            let recents = engine.recentCalendars
            if recents.isEmpty {
                Text("No other calendars")
            } else {
                ForEach(recents) { c in Button(c.name) { engine.switchCalendar(to: c.id) } }
            }
        } label: { Label("Recently Opened Calendars", systemImage: "clock.arrow.circlepath") }
        MenuActionButton(.renameCalendar, engine: engine)
    }
}

// ── View menu payload (shared) ──────────────────────────────────────────────────────────────────
/// The full contents of the View menu, minus the system-provided Enter/Exit Full Screen (SwiftUI adds
/// that itself). Ordering mirrors AppMenu.sections(...)'s `.view` section.
public struct ViewMenuContent: View {
    let engine: CalendarEngine
    @AppStorage(PrefKeys.showHiddenImported) private var showHidden = false
    @AppStorage(PrefKeys.mainTz) private var mainTz = CalendarTimezones.autoId
    @AppStorage(PrefKeys.altTz) private var altTz = "none"
    public init(engine: CalendarEngine) { self.engine = engine }

    public var body: some View {
        MenuActionButton(.goToYear, engine: engine)
        MenuActionButton(.goToMonth, engine: engine)
        MenuActionButton(.goToWeek, engine: engine)
        MenuActionButton(.goToDay, engine: engine)
        Divider()
        // Checkmark tracks the pin; the set-closure routes through the engine so the panel slide
        // animates (a bare @AppStorage write would snap it). Disabled where the toggle no-ops.
        Toggle(isOn: Binding(get: { engine.dashPinned }, set: { _ in engine.toggleDashPin() })) {
            Label("Weekly/Monthly Dashboard", systemImage: "sidebar.trailing")
        }
        .keyboardShortcut("b", modifiers: .command)
        .disabled(!(1 ... 2).contains(engine.chrome.level))
        Toggle(isOn: $showHidden) { Label("Show Hidden Imported Events", systemImage: "eye.slash") }
        Divider()
        Picker(selection: $mainTz) {
            ForEach(CalendarTimezones.all) { Text($0.label).tag($0.id) }
        } label: { Label("Current Timezone", systemImage: "clock") }
        Picker(selection: $altTz) {
            Text("None").tag("none")
            ForEach(CalendarTimezones.all.filter { $0.id != CalendarTimezones.autoId }) { Text($0.label).tag($0.id) }
        } label: { Label("Alternative Timezone", systemImage: "globe") }
        Divider()
        // A menu can't host a stay-open checklist on macOS, so this just toggles the tag-filter popover
        // (anchored to its toolbar button in CalendarView) via a notification — same in both shells.
        Button { NotificationCenter.default.post(name: .toggleTagFilter, object: nil) } label: {
            Label("Filter by Tags…", systemImage: "tag")
        }
        .keyboardShortcut("g", modifiers: .command)
    }
}
