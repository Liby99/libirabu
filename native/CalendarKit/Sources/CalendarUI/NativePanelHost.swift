// One native dashboard panel BODY: purely the active tab's content for a (scope, key) — NO
// motion logic lives here. Placement, slides, rides, and fades all come from the geometry's
// dashBodyPanels list (Frames.swift), the same brain the Canvas header draws from; CalendarView
// applies them as frame/offset/opacity. This view existing per (scope, key) is what makes the
// body a REAL member of the carousel instead of a floating mock-up tracking it.

import CalendarEngine
import CalendarRender
import SwiftUI

struct NativePanelHost: View {
    let engine: CalendarEngine
    let scope: String // "week" | "month"
    let key: String
    let tab: DashTab
    let theme: Theme
    @Binding var noteMode: NotesMode
    var onOpen: (String) -> Void

    var body: some View {
        switch tab {
        case .proj:
            NativeProjPanel(engine: engine, scope: scope, key: key, theme: theme, onOpen: onOpen)
        case .note:
            NativeNotePanel(engine: engine, scope: scope, key: key, theme: theme,
                            noteMode: $noteMode)
        case .todo:
            NativeDashPanel(engine: engine, scope: scope, key: key, theme: theme, onOpen: onOpen)
        }
    }
}
