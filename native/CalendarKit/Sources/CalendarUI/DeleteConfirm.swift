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

    func body(content: Content) -> some View {
        content
            // Gentle blur on the calendar while the delete dialog is up (before the dialog overlay, so the
            // dialog stays sharp).
            .blur(radius: ui.pendingDelete != nil ? 2.5 : 0)
            .overlay {
                if let pd = ui.pendingDelete {
                    DeleteConfirmDialog(pending: pd, theme: theme, onChoose: onDelete)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: ui.pendingDelete)
            .onChange(of: ui.pendingDelete == nil) { _, gone in engine.inputModalUp = !gone }
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
    }
}
