// The NATIVE markdown note editor (webview retirement phase 3) — an NSTextView with lightweight
// in-place markdown highlighting, replacing CodeMirror for the dashboard notepads. Notes here are
// small (the store's largest is under 1KB), so the highlighter re-attributes the WHOLE document
// per change — attribute-only edits, so the selection and undo stack are untouched. The key
// monitor already yields to NSText first responders, so typing lands here like any field editor.
//
// V1 gaps (documented): no entity autocomplete (@person/#tag/project: completions) yet — that
// rides NSTextView's completion API in a follow-up; created:-stamp-on-session-end not wired.

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

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NSTextView()
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
        co.parent = self
        guard let tv = co.textView else { return }
        // Adopt external text when the note IDENTITY changed (panel re-keyed), or the engine's
        // copy diverged while the editor isn't the one typing (a checkbox toggle elsewhere
        // rewrote this note). Never clobber the user's in-flight keystrokes: our own edits round
        // back as `text` == lastSent.
        if co.key != storageKey {
            co.key = storageKey
            co.lastSent = nil
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

        init(_ parent: NativeNoteEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            let s = tv.string
            lastSent = s
            parent.onText(s)
            highlight()
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
