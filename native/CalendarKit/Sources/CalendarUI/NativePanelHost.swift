// One native dashboard panel BODY: purely the active tab's content for a (scope, key) — NO
// motion logic lives here. Placement, slides, rides, and fades all come from the geometry's
// dashBodyPanels list (Frames.swift), the same brain the Canvas header draws from; CalendarView
// applies them as frame/offset/opacity. This view existing per (scope, key) is what makes the
// body a REAL member of the carousel instead of a floating mock-up tracking it.

import CalendarEngine
import CalendarRender
import SwiftUI

struct NativePanelHost: View, Equatable {
    let engine: CalendarEngine
    let scope: String // "week" | "month"
    let key: String
    let tab: DashTab
    let theme: Theme
    /// The data generation this render is for — the ONLY non-identity input that should force a
    /// re-evaluation (see ==). Passed by the caller from engine.todoDataStamp.
    var dataStamp: String = ""
    var settings: DashTodoSettings?
    var nav: NativeDashNavModel?
    @Binding var noteMode: NotesMode
    var onOpen: (String) -> Void
    var onJump: (String, Int?) -> Void = { _, _ in }

    /// The per-frame TimelineView re-creates this view every frame; the closures make SwiftUI
    /// assume it changed, so WITHOUT this the whole panel body (sections, dictionaries, gantt
    /// sorts) re-evaluated at 120Hz — the "severe lag". Equality = identity + data stamp; state
    /// the body READS from @Observable models (nav ring, settings) invalidates through
    /// observation-tracking regardless, and @State (hover, expansion, frozen structure) is
    /// internal. Use with .equatable() at the mount.
    static func == (a: NativePanelHost, b: NativePanelHost) -> Bool {
        a.scope == b.scope && a.key == b.key && a.tab == b.tab
            && a.dataStamp == b.dataStamp && a.noteMode == b.noteMode
    }

    var body: some View {
        switch tab {
        case .proj:
            NativeProjPanel(engine: engine, scope: scope, key: key, theme: theme,
                            onOpen: onOpen, onJump: onJump)
        case .note:
            NativeNotePanel(engine: engine, scope: scope, key: key, theme: theme,
                            noteMode: $noteMode, nav: nav)
        case .todo:
            NativeDashPanel(engine: engine, scope: scope, key: key, theme: theme,
                            settings: settings, nav: nav, onOpen: onOpen, onJump: onJump)
        }
    }
}
