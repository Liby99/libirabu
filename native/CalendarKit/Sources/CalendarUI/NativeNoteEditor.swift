// The NATIVE markdown note editor (webview retirement phase 3) — an NSTextView with lightweight
// in-place markdown highlighting, replacing CodeMirror for the dashboard notepads. Notes here are
// small (the store's largest is under 1KB), so the highlighter re-attributes the WHOLE document
// per change — attribute-only edits, so the selection and undo stack are untouched. The key
// monitor already yields to NSText first responders, so typing lands here like any field editor.
//
// V1 gaps (documented): no entity autocomplete (@person/#tag/project: completions) yet — that
// rides NSTextView's completion API in a follow-up.
// created:-stamps ARE wired (session-end semantics, matching the CodeMirror editor): top-level
// task lines missing created: get " created:YYYY-MM-DDTHH:mm" appended when the editing
// SESSION ends — focus loss, panel re-key, or teardown — and only if the user actually edited
// this note since it loaded (sessionDirty), so opening/previewing never back-stamps old items.

import AppKit
import CalendarEngine
import CalendarRender
import SwiftUI

struct NativeNoteEditor: NSViewRepresentable {
    let storageKey: String // the note's key: "YYYY-MM-DD" / "week:…" / "month:…"
    let text: String // the engine's current note body
    let theme: Theme
    var placeholder: String
    var onText: (String) -> Void // every change → engine.setDailyNote (engine coalesces persist)
    /// ⌘S / Esc — the web editor's session-enders: stamp created:, then flip to preview /
    /// hand focus back (parity with noteEditor.ts's Mod-s / Escape keymap).
    var onSave: () -> Void = {}
    var onExit: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.stampCreatedIfDirty() // teardown (mode flip / drawer close) ends the session
    }

    /// NSTextView subclass owning the editor-local key equivalents. performKeyEquivalent (not
    /// the app key monitor): the monitor deliberately steps aside for text first responders,
    /// and ⌘S must work exactly and only while this editor is focused.
    final class EditorTextView: NSTextView {
        var onSaveKey: (() -> Void)?
        var onEscKey: (() -> Void)?

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers?.lowercased() == "s" {
                onSaveKey?()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        override func cancelOperation(_ sender: Any?) { // Esc
            onEscKey?()
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = EditorTextView()
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.textContainerInset = NSSize(width: 2, height: 6)
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        tv.delegate = context.coordinator
        tv.onSaveKey = { [weak co = context.coordinator] in
            co?.stampCreatedIfDirty()
            co?.parent.onSave()
        }
        tv.onEscKey = { [weak co = context.coordinator] in
            co?.stampCreatedIfDirty()
            co?.parent.onExit()
        }
        tv.string = text
        context.coordinator.textView = tv
        context.coordinator.key = storageKey
        context.coordinator.highlight()

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let co = context.coordinator
        // Re-key = the previous note's editing session ENDS: stamp it through the OLD parent's
        // onText (still bound to the old storage key) BEFORE adopting the new identity.
        if co.key != storageKey {
            co.stampCreatedIfDirty()
        }
        co.parent = self
        guard let tv = co.textView else { return }
        // Adopt external text when the note IDENTITY changed (panel re-keyed), or the engine's
        // copy diverged while the editor isn't the one typing (a checkbox toggle elsewhere
        // rewrote this note). Never clobber the user's in-flight keystrokes: our own edits round
        // back as `text` == lastSent.
        if co.key != storageKey {
            co.key = storageKey
            co.lastSent = nil
            co.sessionDirty = false // a host-driven swap starts a fresh session
            tv.string = text
            co.highlight()
            tv.scroll(.zero)
        } else if text != tv.string, text != co.lastSent {
            tv.string = text
            co.highlight()
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeNoteEditor
        weak var textView: NSTextView?
        var key = ""
        var lastSent: String? // the last body we pushed up — its echo must not re-set the view
        var sessionDirty = false // the user edited THIS note since load / last stamp

        init(_ parent: NativeNoteEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            let s = tv.string
            lastSent = s
            sessionDirty = true
            parent.onText(s)
            highlight()
        }

        func textDidEndEditing(_ notification: Notification) {
            stampCreatedIfDirty() // focus left the editor → the session is over
        }

        /// The CodeMirror editor's stampCreated(), ported: append " created:YYYY-MM-DDTHH:mm"
        /// to top-level task lines that lack one — only when the session actually edited the
        /// note. Runs the rewrite through the same onText path as typing, so persistence,
        /// gen bumps, and the native panels all see it like any other edit.
        func stampCreatedIfDirty() {
            guard sessionDirty, let tv = textView else { return }
            sessionDirty = false // clear FIRST: the rewrite below re-fires textDidChange
            let body = tv.string
            let lines = TodoIndex.linesNeedingCreated(body)
            guard !lines.isEmpty else { return }
            let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute],
                                                    from: Date())
            let stamp = String(format: " created:%04d-%02d-%02dT%02d:%02d",
                               c.year ?? 2000, c.month ?? 1, c.day ?? 1,
                               c.hour ?? 0, c.minute ?? 0)
            var rows = body.components(separatedBy: "\n")
            for n in lines where n >= 1 && n <= rows.count { // 1-based line numbers
                var line = rows[n - 1]
                while line.hasSuffix(" ") || line.hasSuffix("\t") { line.removeLast() }
                rows[n - 1] = line + stamp
            }
            let next = rows.joined(separator: "\n")
            guard next != body else { return }
            let sel = tv.selectedRange()
            tv.string = next
            tv.setSelectedRange(NSRange(location: min(sel.location, (next as NSString).length),
                                        length: 0))
            lastSent = next
            parent.onText(next)
            highlight()
            sessionDirty = false // the programmatic rewrite must not re-arm the session
        }

        // ── Highlighting: full-document, attribute-only (selection + undo untouched) ─────────
        private static let headRe = Re2(#"^#{1,6} .*$"#)
        private static let taskRe = Re2(#"^\s*(?:[-*+]|\d+[.)])\s+\[([ xX])\]"#)
        private static let doneLineRe = Re2(#"^\s*(?:[-*+]|\d+[.)])\s+\[[xX]\].*$"#)
        private static let tokenRe = Re2(
            #"(^|\s)(due:\S+|start:\S+|tz:\S+|color:\S+|done:\S+|created:\S+|followup:\S+|p:!{1,5}|#[A-Za-z0-9_][\w-]*|@[A-Za-z0-9_][\w:-]*|project:[A-Za-z0-9_-]+)(?=\s|$)"#)
        private static let linkRe = Re2(#"\[[^\]]*\]\([^)\s]+\)"#)

        func highlight() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let s = tv.string as NSString
            let all = NSRange(location: 0, length: s.length)
            let base = NSColor(parent.theme.text)
            let dim = base.withAlphaComponent(0.45)
            let accent = NSColor(Theme.accent)
            storage.beginEditing()
            storage.setAttributes([
                .font: NSFont.systemFont(ofSize: 12.5),
                .foregroundColor: base,
            ], range: all)
            s.enumerateSubstrings(in: all, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
                let line = s.substring(with: lineRange)
                if Coordinator.headRe.matches(line) {
                    storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13),
                                         range: lineRange)
                }
                if Coordinator.doneLineRe.matches(line) {
                    storage.addAttributes([
                        .foregroundColor: dim,
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    ], range: lineRange)
                }
                for r in Coordinator.taskRe.ranges(line) {
                    storage.addAttribute(.foregroundColor, value: accent,
                                         range: NSRange(location: lineRange.location + r.location,
                                                        length: r.length))
                }
                for r in Coordinator.tokenRe.ranges(line) {
                    storage.addAttribute(.foregroundColor, value: dim,
                                         range: NSRange(location: lineRange.location + r.location,
                                                        length: r.length))
                }
                for r in Coordinator.linkRe.ranges(line) {
                    storage.addAttribute(.foregroundColor, value: accent,
                                         range: NSRange(location: lineRange.location + r.location,
                                                        length: r.length))
                }
            }
            storage.endEditing()
        }
    }
}

/// Tiny NSRegularExpression wrapper for the highlighter (anchors evaluated per line).
private struct Re2 {
    let rx: NSRegularExpression
    init(_ pattern: String) {
        // Compile-time literals, exercised by every highlight pass.
        // swiftlint:disable:next force_try
        rx = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    func matches(_ s: String) -> Bool {
        rx.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    func ranges(_ s: String) -> [NSRange] {
        rx.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length))
            .map(\.range)
    }
}
