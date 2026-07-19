// The delete-confirmation modal (keyboard-first dialog + backdrop) and the modal overlay
// plumbing that hosts it. Split from CalendarView.swift (file diet).

import SwiftUI
import AppKit
import CalendarGeometry
import CalendarEngine

/// The custom delete-confirmation modal. A dimmed backdrop + a centered card with the question and a
/// horizontal row of buttons. Keyboard focus (the dashed ring) is driven by `pending.focus` via the key
/// monitor; every button is also mouse-clickable. Esc → Cancel is handled by the monitor; clicking the
/// backdrop cancels too.
struct DeleteConfirmDialog: View {
    let pending: PendingDelete
    let theme: Theme
    var onChoose: (DeleteChoice) -> Void

    var body: some View {
        ZStack {
            // Full-window scrim: a light dim that (with the CatcherView's modal guards) swallows all mouse
            // to the canvas. The subtle blur itself is applied to the calendar content, not here. Tap cancels.
            Color.black.opacity(0.1).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onChoose(.cancel) }
            // The glass card — same frosted-glass + border + shadow treatment as the ⌘K shortcut guide.
            VStack(spacing: 14) {
                Text(pending.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text)
                if let note = pending.note {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textMuted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                        // Take the FULL wrapped height for that width — without this, the card's outer
                        // `.fixedSize()` measures the note as one line and clips the buttons below it.
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    ForEach(Array(pending.choices.enumerated()), id: \.offset) { idx, choice in
                        DeleteDialogButton(label: choice.label(recurring: pending.recurring),
                                           destructive: !choice.isCancel,
                                           focused: pending.focus == idx,   // nil focus → no ring shown yet
                                           theme: theme) { onChoose(choice) }
                    }
                }
            }
            .padding(.horizontal, 40).padding(.vertical, 26)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(theme.sep.opacity(0.5), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
            .fixedSize()
        }
    }
}

/// Batch-delete confirm for a multi-selection: title + mixed-content summary note + Cancel / Delete.
struct BatchDeleteDialog: View {
    let summary: CalendarEngine.BatchDeleteSummary
    let theme: Theme
    var onDelete: () -> Void
    var onCancel: () -> Void
    var body: some View {
        ZStack {
            Color.black.opacity(0.1).ignoresSafeArea().contentShape(Rectangle()).onTapGesture { onCancel() }
            VStack(spacing: 14) {
                Text(summary.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Text(summary.note).font(.system(size: 12)).foregroundStyle(theme.textMuted)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    DeleteDialogButton(label: "Cancel", destructive: false, focused: false, theme: theme) { onCancel() }
                    DeleteDialogButton(label: "Delete", destructive: true, focused: true, theme: theme) { onDelete() }
                }
            }
            // Fixed CONTENT width, intrinsic (grow-to-fit) height: the note wraps at this width and the
            // card grows downward for however many lines the summary needs — no overflow. (A bare
            // `.fixedSize()` here would force the ideal width too, measuring the note as one long line.)
            .frame(width: 340)
            .padding(.horizontal, 40).padding(.vertical, 26)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(theme.sep.opacity(0.5), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
        }
    }
}

/// The floating "rename all" field for a multi-selection: typing sets every selected title live.
struct BatchRenameField: View {
    let ui: CalendarUIState
    let engine: CalendarEngine
    let theme: Theme
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 8) {
            Text("Rename \(engine.selectedIds.count) events")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textMuted)
            TextField("Name", text: $text)
                .textFieldStyle(.plain).font(.custom("Comic Sans MS", size: 14)).foregroundStyle(theme.text)
                .frame(width: 240).focused($focused)
                .onChange(of: text) { _, v in engine.batchSetTitle(v) }   // live: all selected titles
                .onSubmit { ui.batchRenaming = false }
                .onExitCommand { ui.batchRenaming = false }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.sep.opacity(0.5), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 6)
        .onAppear { focused = true }
    }
}

/// One button in the delete dialog: a rounded pill that shows a dashed ring (matching the app's keyboard
/// focus style) when it's the focused choice, red text for destructive actions.
private struct DeleteDialogButton: View {
    let label: String
    let destructive: Bool
    let focused: Bool
    let theme: Theme
    var action: () -> Void
    @State private var hover = false

    private var accent: Color { destructive ? theme.eventBorder("red") : theme.text }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(accent)
                .padding(.horizontal, 18).padding(.vertical, 9)
                .frame(minWidth: 76)
        }
        .buttonStyle(.plain)
        .background(Capsule(style: .continuous).fill(theme.text.opacity(hover ? 0.14 : 0.07)))
        // Focus ring: a dashed capsule, offset slightly outward, shown only for the arrow-focused button.
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(focused ? accent : .clear,
                              style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .padding(-3)
        )
        .onHover { hover = $0; if $0 { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() } }
    }
}

/// The blocking-modal overlays: the delete-confirm dialog (with its blur + modal-flag plumbing) and the
/// onboarding tutorial carousel. Bundled into a ViewModifier so CalendarView's `body` chain stays short
/// enough for the Swift type-checker.
struct ModalOverlays: ViewModifier {
    let ui: CalendarUIState
    let engine: CalendarEngine
    let theme: Theme
    var onDelete: (DeleteChoice) -> Void
    // Right-click event callout hooks (the callout itself rides on this bundle so CalendarView's
    // body chain gains no new links — see EventMenuOverlay).
    var onRename: (String) -> Void = { _ in }
    var onCopy: () -> Void = {}
    var onPaste: () -> Void = {}
    var clipKind: () -> String? = { nil }

    /// The canvas input gate reflects EVERY blocking dialog this modifier hosts.
    private func syncModalGate() { engine.inputModalUp = ui.pendingDelete != nil || ui.notice != nil }

    func body(content: Content) -> some View {
        content
            // Gentle blur on the calendar while a blocking dialog (delete confirm / notice) is up
            // (before the dialog overlay, so the dialog stays sharp).
            .blur(radius: ui.pendingDelete != nil || ui.notice != nil ? 2.5 : 0)
            .overlay {
                if let pd = ui.pendingDelete {
                    DeleteConfirmDialog(pending: pd, theme: theme, onChoose: onDelete)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: ui.pendingDelete)
            .onChange(of: ui.pendingDelete == nil) { _, _ in syncModalGate() }
            // One-button informational notice (e.g. "Printing Week view is not supported right now.").
            .overlay {
                if let msg = ui.notice {
                    NoticeDialog(message: msg, theme: theme, onDismiss: { ui.notice = nil; engine.wake() })
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: ui.notice)
            .onChange(of: ui.notice == nil) { _, _ in syncModalGate() }
            // Batch-delete confirm (multi-selection).
            .overlay {
                if let s = ui.pendingBatchDelete {
                    BatchDeleteDialog(summary: s, theme: theme,
                                      onDelete: { engine.performBatchDelete(); ui.pendingBatchDelete = nil; engine.wake() },
                                      onCancel: { ui.pendingBatchDelete = nil })
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: ui.pendingBatchDelete)
            // Floating "rename all" field (multi-selection).
            .overlay {
                if ui.batchRenaming {
                    BatchRenameField(ui: ui, engine: engine, theme: theme).transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: ui.batchRenaming)
            .overlay {   // tutorial carousel — topmost
                if ui.showTutorial {
                    TutorialView(theme: theme, ui: ui, onClose: { ui.showTutorial = false })
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: ui.showTutorial)
            .onReceive(NotificationCenter.default.publisher(for: .showTutorial)) { _ in
                ui.tutorialIndex = 0; ui.showTutorial = true; engine.wake()
            }
            // File ▸ Print… (⌘P): YEAR view prints via the system panel; other levels get a notice.
            .onReceive(NotificationCenter.default.publisher(for: .requestPrint)) { _ in
                if engine.chrome.level == 0 {
                    PrintYear.run(engine: engine, window: NSApp.keyWindow ?? NSApp.mainWindow)
                } else {
                    let name = ["Year", "Month", "Week", "Day"][max(0, min(3, engine.chrome.level))]
                    ui.notice = "Printing \(name) view is not supported right now."
                    engine.wake()
                }
            }
            // Right-click event callout (kept in this bundle for the type-checker's budget).
            .modifier(EventMenuOverlay(ui: ui, engine: engine, theme: theme,
                                       onRename: onRename, onCopy: onCopy,
                                       onPaste: onPaste, clipKind: clipKind))
    }
}

/// A one-button informational modal in the delete dialog's visual language (same scrim, glass card, and
/// capsule button). Enter/Esc (routed like the delete dialog's keys) or OK/tap-outside dismiss.
struct NoticeDialog: View {
    let message: String
    let theme: Theme
    var onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.1).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
            VStack(spacing: 14) {
                Text(message)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
                DeleteDialogButton(label: "OK", destructive: false, focused: true, theme: theme) { onDismiss() }
            }
            .padding(.horizontal, 40).padding(.vertical, 26)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(theme.sep.opacity(0.5), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
            .fixedSize()
        }
    }
}
