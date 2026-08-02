// The NATIVE NOTE tab for the pinned week/month panel (webview retirement phase 3, behind
// cc.nativeDash): the scope note (week:<sunday> / month:<YYYY-MM> storage keys) as either the
// LIVE NSTextView editor (NativeNoteEditor) or the rendered preview (MarkdownBlocksView, with
// working line-keyed todo checkboxes). Honors the same NotesMode binding the native
// Editor/Preview toggle drives; an EMPTY note opens in edit (the content-based default the
// webview used), applied whenever the panel re-keys to a different note.

import CalendarEngine
import CalendarRender
import SwiftUI

struct NativeNotePanel: View {
    let engine: CalendarEngine
    let scope: String // "day" | "week" | "month"
    let key: String
    let theme: Theme
    @Binding var noteMode: NotesMode

    /// Ends the editing session (created:-stamps) when the MODE TOGGLE leaves edit — the
    /// toggle lives in the DashChrome overlay writing this binding from outside, so the panel
    /// intercepts the change and stamps BEFORE the preview branch reads the note.
    @State private var session = NoteEditSession()
    @State private var pendingEditLine: Int? // ⌘-click in the preview → edit at this line

    var body: some View {
        let storageKey = scope == "day" ? key
            : scope == "week" ? "week:\(key)" : "month:\(key)"
        let text = engine.dailyNote(storageKey)
        Group {
            if noteMode == .edit {
                NativeNoteEditor(
                    storageKey: storageKey,
                    text: text,
                    theme: theme,
                    placeholder: scope == "day" ? "Daily Note (Markdown)…"
                        : scope == "week" ? "Weekly Note (Markdown)…" : "Monthly Note (Markdown)…",
                    onText: { engine.setDailyNote(storageKey, $0) },
                    // ⌘S = the web's Mod-s: stamp (done inside the editor) + flip to preview.
                    // Esc hands the keys back to the calendar, preview only if content exists.
                    onSave: { noteMode = .preview },
                    onExit: {
                        if !engine.dailyNote(storageKey)
                            .trimmingCharacters(in: .whitespaces).isEmpty { noteMode = .preview }
                        engine.dashNoteExit()
                    },
                    session: session,
                    focusLine: pendingEditLine,
                    onFocusLineHandled: { pendingEditLine = nil }
                )
            } else if text.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("No \(scope == "day" ? "daily" : scope == "week" ? "weekly" : "monthly") note yet — switch to Editor to write one.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.text.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 6)
            } else {
                ScrollView {
                    MarkdownBlocksView(text: text, accent: Theme.accent, theme: theme,
                                       onToggle: { line in
                                           // ⌘-click on a checkbox = "edit here", not a toggle
                                           // (the web ignored inputs on ⌘-click for the same
                                           // reason — modifier checked at the shared source).
                                           if NSEvent.modifierFlags.contains(.command) {
                                               pendingEditLine = line
                                               noteMode = .edit
                                               return
                                           }
                                           // Preview checkboxes flip the source line in place.
                                           let stamp = NativeDashPanel.todayIso() + "T"
                                               + NativeDashPanel.clockNow()
                                           if let next = TodoIndex.toggleTodoLine(
                                               text, line: line, stamp: stamp), next != text {
                                               engine.setDailyNote(storageKey, next)
                                           }
                                       },
                                       onLineEdit: { line in
                                           pendingEditLine = line
                                           noteMode = .edit
                                       })
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 10)
                }
                .scrollIndicators(.hidden)
            }
        }
        // Content-based default whenever the panel lands on a DIFFERENT note: empty → edit,
        // content → preview (same rule the webview applied on live-editor mounts).
        .onChange(of: noteMode) { old, new in
            if old == .edit, new != .edit { session.end?() } // toggle button → stamp first
        }
        .onChange(of: storageKey, initial: true) { _, newKey in
            noteMode = engine.dailyNote(newKey)
                .trimmingCharacters(in: .whitespaces).isEmpty ? .edit : .preview
        }
    }
}
