// The right-click event callout — a compact popover (the same NSPopover chrome as the assistant
// callout, so it can overflow the window edge): a quick color row (the web's MENU_COLORS subset)
// above normal menu rows with their hotkeys. Actions are injected by CalendarView so every row
// reuses the exact path its hotkey takes (drawer open, inline rename, ⌘C copy, delete dialog…).

import SwiftUI
import CalendarGeometry
import CalendarEngine

/// Presents the callout: an invisible anchor at the clicked box shows the popover (NSPopover —
/// its own window, so it may overflow the app window edge). `arrowEdge: .trailing` puts it on
/// the RIGHT of the event; AppKit flips it left on its own when the screen runs out (the
/// fullscreen right-edge case). A separate modifier so CalendarView's body chain stays within
/// the type-checker's budget.
struct EventMenuOverlay: ViewModifier {
    var ui: CalendarUIState
    let engine: CalendarEngine
    let theme: Theme
    let onRename: (String) -> Void
    let onCopy: () -> Void

    private var shown: Binding<Bool> {
        Binding<Bool>(get: { ui.eventMenu != nil }, set: { (v: Bool) in if !v { ui.eventMenu = nil } })
    }

    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            if let menu = ui.eventMenu {
                Color.clear
                    .frame(width: max(4.0, menu.anchor.width), height: max(4.0, menu.anchor.height))
                    .offset(x: menu.anchor.minX, y: menu.anchor.minY)
                    .popover(isPresented: shown, arrowEdge: .trailing) {
                        EventContextCallout(
                            engine: engine, id: menu.id, theme: theme,
                            onDetails: { ui.openEventId = sourceId(of: menu.id) },
                            onRename: { onRename(menu.id) },
                            onCopy: { onCopy() },
                            onRepeat: { ui.openRepeatOnOpen = true; ui.openEventId = sourceId(of: menu.id) },
                            onPromote: { engine.togglePromote(menu.id) },
                            onDelete: {
                                if let t = engine.deleteTargetForSelection() {
                                    ui.requestDelete(id: t.id, occKey: t.occKey, recurring: t.recurring,
                                                     imported: t.imported, alreadyHidden: t.alreadyHidden,
                                                     kind: engine.kind(of: t.id) ?? .timed)
                                }
                            },
                            onClose: { ui.eventMenu = nil })
                    }
            }
        }
    }
}

struct EventContextCallout: View {
    let engine: CalendarEngine
    let id: String                 // the clicked BOX id (a ghost is fine; actions resolve the source)
    let theme: Theme
    let onDetails: () -> Void
    let onRename: () -> Void
    let onCopy: () -> Void
    let onRepeat: () -> Void
    let onPromote: () -> Void
    let onDelete: () -> Void
    let onClose: () -> Void

    private var imported: Bool { engine.isImported(id) }
    private var kind: CalendarEngine.ItemKind? { engine.kind(of: id) }
    private var promoted: Bool { engine.promoteTrack(id) != nil }
    private var currentColor: String {
        if let o = engine.colorOverride(id) { return o }
        return engine.event(sourceId(of: id))?.color
            ?? engine.band(sourceId(of: id))?.color
            ?? engine.deadline(sourceId(of: id))?.color ?? "default"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            colorRow.padding(.horizontal, 6).padding(.top, 2).padding(.bottom, 6)
            Divider().padding(.bottom, 3)
            row("Details", icon: "info.circle", key: "Space", action: onDetails)
            if !imported {   // imported bodies are read-only (rename/repeat live in Calendar.app)
                row("Rename", icon: "pencil", key: "⏎", action: onRename)
            }
            row("Copy", icon: "doc.on.doc", key: "⌘C", action: onCopy)
            if !imported {
                row("Repeat…", icon: "repeat", key: nil, action: onRepeat)
            }
            if kind == .timed {   // promote is an overlay, so imported timed events can too
                row(promoted ? "Unpromote" : "Promote", icon: promoted ? "arrow.uturn.down" : "arrow.up.to.line",
                    key: "⌘U", action: onPromote)
            }
            Divider().padding(.vertical, 3)
            row(imported ? "Hide" : "Delete", icon: imported ? "eye.slash" : "trash", key: "⌫",
                destructive: true, action: onDelete)
        }
        .padding(6)
        .frame(width: 198)
    }

    // ── Quick colors: the web's MENU_COLORS subset of the drawer's full palette ──
    private var colorRow: some View {
        HStack(spacing: 7) {
            ForEach(MENU_COLORS, id: \.self) { key in
                Circle()
                    .fill(theme.eventBorder(key))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(theme.text, lineWidth: key == currentColor ? 2 : 0))
                    .contentShape(Circle())
                    .onHover { hovering in
                        if hovering { engine.setColorPreview(id, key) } else { engine.clearColorPreview(key) }
                    }
                    .onTapGesture { commitColor(key); onClose() }
                    .help(key)
            }
            Spacer(minLength: 0)
        }
    }

    private func commitColor(_ v: String) {
        // Mirrors the drawer: imported events keep a local color overlay; own items edit the body.
        let sid = sourceId(of: id)
        if imported { engine.setColorOverride(sid, v); return }
        switch kind {
        case .timed: engine.update(sid) { $0.color = v }
        case .band: engine.updateBand(sid) { $0.color = v }
        case .deadline: engine.updateDeadline(sid) { $0.color = v }
        default: break
        }
    }

    // ── One menu row: icon + label, hotkey right-aligned, hover highlight ──
    private func row(_ label: String, icon: String, key: String?,
                     destructive: Bool = false, action: @escaping () -> Void) -> some View {
        MenuRow(label: label, icon: icon, key: key, destructive: destructive, theme: theme) {
            action(); onClose()
        }
    }
}

private struct MenuRow: View {
    let label: String
    let icon: String
    let key: String?
    let destructive: Bool
    let theme: Theme
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11.5))
                    .frame(width: 15)
                Text(label).font(.system(size: 12.5))
                Spacer(minLength: 12)
                if let key {
                    Text(key).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(destructive ? Color.red : theme.text)
            .padding(.horizontal, 7).padding(.vertical, 4.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? theme.text.opacity(0.09) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
