// Keyboard navigation state for the NATIVE dashboard TODO panel (pinned week/month) — the native
// stand-in for the webview's CK.nav* bridge, driven by the SAME engine key system (DashCmd via
// onDashCommand): ⌘B focuses the list, ↑/↓ move the row cursor, Space toggles, Enter opens, Esc
// leaves. The panel registers its VISIBLE rows (display order, frozen-structure order) each
// render; CalendarView's command handler acts on the current row through the model.

import CalendarEngine
import Foundation
import Observation

@MainActor @Observable final class NativeDashNavModel {
    var active = false // the TODO stop is keyboard-focused → the row ring shows
    var cursor = 0 // index into `rows` (display order)
    /// The visible rows, registered by the panel per render (LIVE todos, frozen order).
    /// @ObservationIgnored: registration happens per frame — it must not invalidate views;
    /// the ring keys on `active`/`cursor` only.
    @ObservationIgnored var rows: [ParsedTodo] = []

    var currentRow: ParsedTodo? {
        rows.indices.contains(cursor) ? rows[cursor] : nil
    }

    func focus() {
        active = true
        cursor = 0
    }

    func blur() {
        active = false
    }

    func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        cursor = max(0, min(rows.count - 1, cursor + delta))
    }
}
