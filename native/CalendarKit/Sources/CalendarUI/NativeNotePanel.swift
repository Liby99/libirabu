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
    var nav: NativeDashNavModel? // note-jump line landings + ⌘E focus requests

    /// The engine's entity index (JSON for the webview bridge), decoded for the native
    /// completion source. Tiny payload; the engine caches per editGen with coalesced refresh.
    static func entityIndex(_ engine: CalendarEngine)
        -> (projects: [String], people: [String], tags: [String]) {
        struct Idx: Decodable { var projects: [String]?; var people: [String]?; var tags: [String]? }
        let idx = (try? JSONDecoder().decode(Idx.self,
                                             from: Data(engine.entityIndexJSON().utf8)))
        return (idx?.projects ?? [], idx?.people ?? [], idx?.tags ?? [])
    }

    /// Ends the editing session (created:-stamps) when the MODE TOGGLE leaves edit — the
    /// toggle lives in the DashChrome overlay writing this binding from outside, so the panel
    /// intercepts the change and stamps BEFORE the preview branch reads the note.
    @State private var session = NoteEditSession()
    @State private var pendingEditLine: Int? // ⌘-click in the preview → edit at this line
    @State private var editorFocusSeq = 0 // bumped → the editor takes keyboard focus
    @State private var appliedDefaultKey = "" // arrival default applied for this note already

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
                    completionIndex: { NativeNotePanel.entityIndex(engine) },
                    dueAnchor: { scope == "day" ? ("this day", key) : nil },
                    focusLine: pendingEditLine,
                    onFocusLineHandled: { pendingEditLine = nil },
                    focusPulse: editorFocusSeq
                )
            } else if text.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("No \(scope == "day" ? "daily" : scope == "week" ? "weekly" : "monthly") note yet — switch to Editor to write one.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.text.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 6)
            } else {
                // The refined preview engine: one selectable NSTextView document (tables,
                // code highlighting, token pills; whole-content copy). ⌘-click → edit at line;
                // checkbox taps flip the source line in place.
                MarkdownPreview(text: text, theme: theme,
                                onToggle: { line in
                                    if NSEvent.modifierFlags.contains(.command) {
                                        pendingEditLine = line
                                        noteMode = .edit
                                        return
                                    }
                                    let stamp = NativeDashPanel.todayIso() + "T"
                                        + NativeDashPanel.clockNow()
                                    if let next = TodoIndex.toggleTodoLine(
                                        text, line: line, stamp: stamp), next != text {
                                        engine.setDailyNote(storageKey, next)
                                        // The engine is NOT @Observable — panels refresh only
                                        // when the render loop ticks and the new noteGen flows
                                        // into the host's dataStamp. A checkbox click at rest
                                        // (clock asleep) otherwise shows nothing until the
                                        // next slide/zoom wakes the loop.
                                        engine.wake()
                                    }
                                },
                                onLineEdit: { line in
                                    pendingEditLine = line
                                    noteMode = .edit
                                })
            }
        }
        // Content-based default whenever the panel lands on a DIFFERENT note: empty → edit,
        // content → preview (same rule the webview applied on live-editor mounts).
        .onChange(of: noteMode) { old, new in
            if old == .edit, new != .edit { session.end?() } // toggle button → stamp first
        }
        // A todo-row note jump landed here (Enter or click on a note-sourced row): flip to
        // edit with the source line selected + focused — the web's onJumpDay line flow.
        .onChange(of: nav?.noteJump, initial: true) { _, jump in
            guard let jump, jump.key == storageKey else { return }
            nav?.noteJump = nil
            noteMode = .edit
            pendingEditLine = jump.line
            editorFocusSeq += 1
        }
        // ⌘E / Enter on the NOTE stop: the ACTIVE (settled) panel's editor takes the keyboard.
        .onChange(of: nav?.noteFocusSeq) { _, _ in
            guard nav?.activePanel == "\(scope)|\(key)" || scope == "day" else { return }
            noteMode = .edit
            editorFocusSeq += 1
        }
        .onChange(of: storageKey, initial: true) { _, _ in
            engine.prewarmEntityIndex() // completion index warm before the first "@"
        }
        // THE UNIFIED ARRIVAL RULE: when this panel BECOMES the active dashboard (swipe
        // settle, zoom landing, launch), the mode defaults by CONTENT — empty note → editor
        // (nothing to preview), content → preview (reading is the common case). Applied once
        // per note, ONLY by the active panel — mount-time application let parked/pre-built
        // neighbor panels clobber the shared mode from offscreen. Explicit intents win:
        // a pending note-jump (which forces edit-at-line) suppresses the default, and tab
        // flips within the SAME dashboard keep whatever mode you were in.
        .onChange(of: nav?.activePanel, initial: true) { _, active in
            guard active == "\(scope)|\(key)" || nav == nil,
                  appliedDefaultKey != storageKey else { return }
            appliedDefaultKey = storageKey
            guard nav?.noteJump?.key != storageKey else { return } // the jump forces edit
            noteMode = engine.dailyNote(storageKey)
                .trimmingCharacters(in: .whitespaces).isEmpty ? .edit : .preview
        }
    }
}
