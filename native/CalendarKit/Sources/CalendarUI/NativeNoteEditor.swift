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

/// A tiny handle the HOST keeps so it can end the editing session from outside the
/// responder chain — the Editor/Preview toggle lives in a separate overlay (DashChrome)
/// writing the shared noteMode binding, so the panel must be able to say "stamp NOW,
/// before the preview renders" instead of waiting for the unmount hook.
@MainActor final class NoteEditSession {
    var end: (() -> Void)?
}

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
    var session: NoteEditSession? = nil // host-side session-ender (mode-toggle stamping)
    /// Live entity index for @project:/@person:/bare-@/#tag completions (the web's
    /// completionIndex). nil → entity completion off; DATE completion always works.
    var completionIndex: (() -> (projects: [String], people: [String], tags: [String]))?
    /// Context anchor offered after `due:` — "this day time" in a daily note, "this event
    /// time" in the drawer (the web's dueAnchor).
    var dueAnchor: (() -> (label: String, value: String)?)?
    /// ⌘-click line focus: when set, the editor selects this 1-based line, scrolls it visible
    /// and takes focus (once per value; the host clears it via onFocusLineHandled).
    var focusLine: Int? = nil
    var onFocusLineHandled: () -> Void = {}

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
        var placeholderText = ""
        var themeText: NSColor = .labelColor

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

        // ── Active line: a slight full-width wash behind the caret's line (the ruler bolds
        // its number to match). Selection changes trigger redraw via the coordinator.
        override func drawBackground(in rect: NSRect) {
            super.drawBackground(in: rect)
            guard let lm = layoutManager, let tc = textContainer else { return }
            let ns = string as NSString
            var frag: NSRect
            let sel = min(selectedRange().location, ns.length)
            if ns.length == 0 || (sel >= ns.length && ns.hasSuffix("\n")) {
                frag = lm.extraLineFragmentRect
                if frag.height <= 0 { return }
            } else {
                var line = ns.lineRange(for: NSRange(location: sel, length: 0))
                // Exclude the trailing newline: its glyph maps into the NEXT fragment's
                // bounding box, which washed the line below too (the reported artifact).
                if line.length > 0, ns.character(at: NSMaxRange(line) - 1) == 0x0A {
                    line.length -= 1
                }
                if line.length == 0 { // blank line: no glyph box — use its fragment directly
                    let gr = lm.glyphRange(forCharacterRange: NSRange(location: line.location, length: 1),
                                           actualCharacterRange: nil)
                    frag = lm.lineFragmentRect(forGlyphAt: min(gr.location, max(0, lm.numberOfGlyphs - 1)),
                                               effectiveRange: nil)
                } else {
                    let gr = lm.glyphRange(forCharacterRange: line, actualCharacterRange: nil)
                    frag = lm.boundingRect(forGlyphRange: gr, in: tc)
                }
            }
            var r = frag
            r.origin.x = 0
            r.size.width = bounds.width
            r.origin.y += textContainerInset.height
            themeText.withAlphaComponent(0.05).setFill()
            r.intersection(rect).fill()
        }

        // ── Placeholder (CodeMirror's cmPlaceholder): grey hint while the note is empty ──
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard string.isEmpty, !placeholderText.isEmpty else { return }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NativeNoteEditor.monoFont(),
                .foregroundColor: themeText.withAlphaComponent(0.35),
            ]
            let size = (placeholderText as NSString).size(withAttributes: attrs)
            (placeholderText as NSString).draw(
                at: NSPoint(x: textContainerInset.width + 3,
                            y: textContainerInset.height
                                + (NativeNoteEditor.lineHeight - size.height) / 2),
                withAttributes: attrs)
        }

        override func didChangeText() {
            super.didChangeText()
            needsDisplay = true // placeholder appears/disappears with emptiness
        }

        // ── ⌥↑ / ⌥↓ line rearrangement (defaultKeymap's moveLineUp/Down) ──
        override func keyDown(with event: NSEvent) {
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods == .option, event.keyCode == 126 { moveLines(up: true); return }
            if mods == .option, event.keyCode == 125 { moveLines(up: false); return }
            super.keyDown(with: event)
        }

        /// Swap the line block containing the selection with its neighbor, keeping the
        /// selection glued to the moved text — CodeMirror's moveLineUp/Down semantics.
        private func moveLines(up: Bool) {
            let ns = string as NSString
            let sel = selectedRange()
            let block = ns.lineRange(for: sel) // full line(s) incl. trailing \n
            if up {
                guard block.location > 0 else { NSSound.beep(); return }
                let prev = ns.lineRange(for: NSRange(location: block.location - 1, length: 0))
                let blockText = ns.substring(with: block)
                let prevText = ns.substring(with: prev)
                // Both keep their own trailing newlines EXCEPT when the moving block is the
                // last line (no \n) — normalize so the join stays well-formed.
                var newBlock = blockText, newPrev = prevText
                if !newBlock.hasSuffix("\n") {
                    newBlock += "\n"
                    newPrev = String(newPrev.dropLast(newPrev.hasSuffix("\n") ? 1 : 0))
                }
                let whole = NSRange(location: prev.location, length: prev.length + block.length)
                replace(whole, with: newBlock + newPrev,
                        selectDelta: prev.location - block.location, sel: sel)
            } else {
                let end = block.location + block.length
                guard end < ns.length else { NSSound.beep(); return }
                let next = ns.lineRange(for: NSRange(location: end, length: 0))
                var blockText = ns.substring(with: block)
                var nextText = ns.substring(with: next)
                if !nextText.hasSuffix("\n") { // moving past the (newline-less) last line
                    nextText += "\n"
                    blockText = String(blockText.dropLast())
                }
                let whole = NSRange(location: block.location, length: block.length + next.length)
                replace(whole, with: nextText + blockText,
                        selectDelta: next.length, sel: sel)
            }
        }

        private func replace(_ range: NSRange, with str: String, selectDelta: Int, sel: NSRange) {
            guard shouldChangeText(in: range, replacementString: str) else { return }
            textStorage?.replaceCharacters(in: range, with: str)
            didChangeText()
            setSelectedRange(NSRange(location: sel.location + selectDelta, length: sel.length))
            scrollRangeToVisible(selectedRange())
        }

        // ── Autocomplete (the web's entity + date sources on NSTextView's machinery) ──
        /// The partial AFTER the trigger sigil (after "@", "#", "@project:", "due:", …) — what
        /// an accepted completion replaces, exactly like the web's `from` offsets.
        override var rangeForUserCompletion: NSRange {
            NativeNoteEditor.completionTrigger(in: self)?.partialRange
                ?? super.rangeForUserCompletion
        }

        override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange,
                                       movement: Int, isFinal flag: Bool) {
            // Labeled options render as "label → value"; only the VALUE is inserted.
            let insert = word.range(of: " → ").map { String(word[$0.upperBound...]) } ?? word
            super.insertCompletion(insert, forPartialWordRange: charRange,
                                   movement: movement, isFinal: flag)
            guard flag, movement != NSCancelTextMovement else { return }
            if insert.hasSuffix(":") { // "project:" / "person:" reopeners → offer the keys now
                DispatchQueue.main.async { [weak self] in self?.complete(nil) }
            }
        }

        // ── ⌘-click a markdown/bare link opens it (the web's openLinks handler) ──
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.command) {
                let pt = convert(event.locationInWindow, from: nil)
                let idx = characterIndexForInsertion(at: pt)
                if let url = NativeNoteEditor.linkAt(string, index: idx) {
                    NSWorkspace.shared.open(url)
                    return
                }
            }
            super.mouseDown(with: event)
        }
    }

    /// The house editor face: Menlo (user preference), CodeMirror's 13px.
    static func monoFont(bold: Bool = false) -> NSFont {
        NSFont(name: bold ? "Menlo-Bold" : "Menlo", size: 12.5)
            ?? .monospacedSystemFont(ofSize: 12.5, weight: bold ? .bold : .regular)
    }

    /// ONE line grid for everything (content, typing attributes, ruler): a FIXED fragment
    /// height with the glyphs re-centered via baselineOffset. TextKit parks glyphs at the
    /// BOTTOM of an enlarged fragment (that was the "text hugs the bottom of its highlight" +
    /// "numbers misaligned" + "last line a different height" cluster — the extra/typing
    /// fragments never even got the paragraph style). Fixed + centered kills the whole class.
    static let lineHeight: CGFloat = 19
    static let baselineShift: CGFloat = {
        let lm = NSLayoutManager()
        return ((lineHeight - lm.defaultLineHeight(for: monoFont())) / 2).rounded()
    }()

    static func editorParagraphStyle() -> NSMutableParagraphStyle {
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = lineHeight
        para.maximumLineHeight = lineHeight
        return para
    }

    static func baseAttributes(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: monoFont(), .foregroundColor: color,
         .paragraphStyle: editorParagraphStyle(), .baselineOffset: baselineShift]
    }

    // ── Autocomplete engine (ports noteEditor.ts's entitySource + dateSource) ──────────────

    enum TriggerKind {
        case project, person, bareAt, tag
        case date(key: String) // due / start / created / done
    }

    struct Trigger {
        let kind: TriggerKind
        let partialRange: NSRange // the text an accepted completion replaces
        let partial: String
    }

    /// The completion trigger at the caret, scanning the line prefix — mirrors the web's
    /// matchBefore patterns (order matters: namespaced @ before bare @).
    static func completionTrigger(in tv: NSTextView) -> Trigger? {
        let ns = tv.string as NSString
        let caret = tv.selectedRange().location
        guard caret <= ns.length else { return nil }
        let line = ns.lineRange(for: NSRange(location: min(caret, max(0, ns.length - 1)), length: 0))
        let prefix = ns.substring(with: NSRange(location: line.location, length: caret - line.location))
        func match(_ pattern: String, _ kind: (String) -> TriggerKind, sigilLen: Int) -> Trigger? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: prefix,
                                        range: NSRange(location: 0, length: (prefix as NSString).length))
            else { return nil }
            let full = m.range
            let partialLoc = line.location + full.location + sigilLen
            let partial = (prefix as NSString).substring(
                from: full.location + sigilLen)
            return Trigger(kind: kind(partial),
                           partialRange: NSRange(location: partialLoc, length: caret - partialLoc),
                           partial: partial)
        }
        if let t = match(#"@project:[\w-]*$"#, { _ in .project }, sigilLen: 9) { return t }
        if let t = match(#"@person:[\w-]*$"#, { _ in .person }, sigilLen: 8) { return t }
        if let t = match(#"@[\w-]*$"#, { _ in .bareAt }, sigilLen: 1) { return t }
        if let t = match(#"#[\w-]*$"#, { _ in .tag }, sigilLen: 1) { return t }
        if let re = try? NSRegularExpression(pattern: #"(due|start|created|done):[\w/-]*$"#),
           let m = re.firstMatch(in: prefix,
                                 range: NSRange(location: 0, length: (prefix as NSString).length)) {
            let key = (prefix as NSString).substring(with: m.range(at: 1))
            let sigil = key.count + 1
            let partialLoc = line.location + m.range.location + sigil
            return Trigger(kind: .date(key: key),
                           partialRange: NSRange(location: partialLoc, length: caret - partialLoc),
                           partial: (prefix as NSString).substring(from: m.range.location + sigil))
        }
        return nil
    }

    /// Options for a trigger. Labeled date options render "label → concrete"; the editor
    /// inserts only the concrete part. Entity options insert verbatim.
    static func completionOptions(for t: Trigger,
                                  index: (projects: [String], people: [String], tags: [String])?,
                                  dueAnchor: (label: String, value: String)?) -> [String] {
        func filtered(_ xs: [String]) -> [String] {
            t.partial.isEmpty ? xs
                : xs.filter { $0.lowercased().hasPrefix(t.partial.lowercased()) }
        }
        switch t.kind {
        case .project: return filtered(index?.projects ?? [])
        case .person: return filtered(index?.people ?? [])
        case .tag: return filtered(index?.tags ?? [])
        case .bareAt:
            var opts = filtered(index?.people ?? [])
            for ns in ["project:", "person:"] where t.partial.isEmpty || ns.hasPrefix(t.partial.lowercased()) {
                opts.append(ns)
            }
            return opts
        case let .date(key):
            return dateOptions(key: key, partial: t.partial, dueAnchor: dueAnchor)
        }
    }

    /// noteEditor.ts's dateSource: loose forms → concrete dates. due/start are date-only and
    /// future-oriented; created/done carry minute times and resolve within this year.
    static func dateOptions(key: String, partial: String,
                            dueAnchor: (label: String, value: String)?) -> [String] {
        let now = Date()
        let cal = Calendar.current
        let wantTime = key == "created" || key == "done"
        let future = key == "due" || key == "start"
        func iso(_ d: Date) -> String {
            let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
            let day = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
            return wantTime ? day + String(format: "T%02d:%02d", c.hour!, c.minute!) : day
        }
        var opts: [String] = []
        func push(_ label: String, _ d: Date) { opts.append("\(label) → \(iso(d))") }
        let p = partial.lowercased()
        if let d = parseLooseDate(p, now: now, future: future), !p.isEmpty {
            push(partial, d) // the typed freeform, concretized, on top
        }
        if future, !p.isEmpty, p.allSatisfy(\.isLetter) {
            let wd = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
            let today = cal.component(.weekday, from: now) - 1
            for (i, w) in wd.enumerated() where w.hasPrefix(p) {
                let ahead = ((i - today) + 7) % 7
                push(String(w.prefix(3)),
                     cal.date(byAdding: .day, value: ahead == 0 ? 7 : ahead, to: now)!)
            }
        }
        let statics: [(String, Date)] = [
            ("now", now), ("today", now),
            ("tomorrow", cal.date(byAdding: .day, value: 1, to: now)!),
            ("3d", cal.date(byAdding: .day, value: 3, to: now)!),
            ("1w", cal.date(byAdding: .day, value: 7, to: now)!),
        ]
        for (l, d) in statics where (p.isEmpty || l.hasPrefix(p)) && l != p {
            push(l, d)
        }
        if key == "due", let anchor = dueAnchor,
           p.isEmpty || anchor.label.lowercased().hasPrefix(p) {
            opts.append("\(anchor.label) → \(anchor.value)")
        }
        return opts
    }

    /// "3d"/"2w"/"1m", "july-5"/"jul5", "7/5" → a concrete Date (the web's parseLooseDate).
    static func parseLooseDate(_ s: String, now: Date, future: Bool) -> Date? {
        let cal = Calendar.current
        if let m = s.wholeMatch(of: #/(\d+)(d|w|m)/#) {
            let n = Int(m.1) ?? 0
            switch m.2 {
            case "d": return cal.date(byAdding: .day, value: n, to: now)
            case "w": return cal.date(byAdding: .day, value: 7 * n, to: now)
            default: return cal.date(byAdding: .month, value: n, to: now)
            }
        }
        let months = ["january", "february", "march", "april", "may", "june", "july",
                      "august", "september", "october", "november", "december"]
        func resolve(_ month: Int, _ day: Int) -> Date? {
            guard (1 ... 12).contains(month), (1 ... 31).contains(day) else { return nil }
            let year = cal.component(.year, from: now)
            var c = DateComponents(year: year, month: month, day: day)
            guard var d = cal.date(from: c) else { return nil }
            if future, d.timeIntervalSince(now) < -86_400 {
                c.year = year + 1
                d = cal.date(from: c) ?? d
            }
            return d
        }
        if let m = s.wholeMatch(of: #/([a-z]{3,9})[-/ ]?(\d{1,2})/#) {
            guard let mi = months.firstIndex(where: { $0.hasPrefix(m.1) }) else { return nil }
            return resolve(mi + 1, Int(m.2) ?? 0)
        }
        if let m = s.wholeMatch(of: #/(\d{1,2})[-/](\d{1,2})/#) {
            return resolve(Int(m.1) ?? 0, Int(m.2) ?? 0)
        }
        return nil
    }

    /// The markdown/bare URL under `index`, if any (the web's linkAt, line-local scan).
    static func linkAt(_ text: String, index: Int) -> URL? {
        let ns = text as NSString
        guard index <= ns.length else { return nil }
        let line = ns.lineRange(for: NSRange(location: min(index, max(0, ns.length - 1)), length: 0))
        let lineText = ns.substring(with: line)
        let rel = index - line.location
        let re = try? NSRegularExpression(
            pattern: #"\[[^\]]*\]\(([^)\s]+)\)|(?:https?://|www\.)[^\s)]+"#)
        guard let re else { return nil }
        let lineNS = lineText as NSString
        for m in re.matches(in: lineText, range: NSRange(location: 0, length: lineNS.length)) {
            guard m.range.contains(rel) || m.range.location == rel else { continue }
            var raw = m.range(at: 1).location != NSNotFound
                ? lineNS.substring(with: m.range(at: 1))
                : lineNS.substring(with: m.range)
            if !raw.contains("://") { raw = "https://" + raw }
            return URL(string: raw)
        }
        return nil
    }

    /// Line numbers in the left ruler — same Menlo face and per-fragment BASELINE alignment
    /// as the content (identical font ⇒ identical line pitch); the current line's number is
    /// bold + brighter, matching the text view's active-line wash; trailing empty lines get
    /// numbers via the layout manager's extra line fragment; the separator hairline spans only
    /// the numbered region, not the whole panel.
    final class LineNumberRuler: NSRulerView {
        weak var tv: NSTextView?

        init(textView: NSTextView, scroll: NSScrollView) {
            tv = textView
            super.init(scrollView: scroll, orientation: .verticalRuler)
            clientView = textView
            ruleThickness = 34
            NotificationCenter.default.addObserver(
                self, selector: #selector(invalidate),
                name: NSText.didChangeNotification, object: textView)
            NotificationCenter.default.addObserver(
                self, selector: #selector(invalidate),
                name: NSTextView.didChangeSelectionNotification, object: textView)
        }

        @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

        @objc private func invalidate() { needsDisplay = true }

        // No super.draw: NSRulerView's default chrome paints a full-height background +
        // separator; we own the drawing entirely.
        override func draw(_ dirtyRect: NSRect) {
            drawHashMarksAndLabels(in: dirtyRect)
        }

        override func drawHashMarksAndLabels(in rect: NSRect) {
            guard let tv, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            let visible = tv.visibleRect
            let inset = tv.textContainerInset.height
            let ns = tv.string as NSString
            let font = NativeNoteEditor.monoFont()
            let boldFont = NativeNoteEditor.monoFont(bold: true)
            let base = (tv as? EditorTextView)?.themeText ?? .labelColor
            let dimC = base.withAlphaComponent(0.28)
            let hiC = base.withAlphaComponent(0.8)
            // Highlight EVERY line the selection touches (multi-line selections included).
            let sel = tv.selectedRange()
            let selStart = min(sel.location, ns.length)
            let selEnd = min(NSMaxRange(sel), ns.length)
            var firstLine = 1
            if ns.length > 0 {
                ns.substring(to: selStart).unicodeScalars.forEach { if $0 == "\n" { firstLine += 1 } }
            }
            var lastLine = firstLine
            if selEnd > selStart {
                ns.substring(with: NSRange(location: selStart, length: selEnd - selStart))
                    .unicodeScalars.forEach { if $0 == "\n" { lastLine += 1 } }
                // A selection ENDING at a line start doesn't touch that next line.
                if selEnd > 0, ns.character(at: selEnd - 1) == 0x0A { lastLine -= 1 }
            }
            var sepTop: CGFloat = .greatestFiniteMagnitude
            var sepBottom: CGFloat = 0

            // Draw one number, vertically CENTERED in its fragment — the content glyphs are
            // centered on the same fixed grid (baselineOffset), so center == aligned.
            func draw(_ n: Int, fragTop: CGFloat, fragHeight: CGFloat) {
                let cur = n >= firstLine && n <= lastLine
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: cur ? boldFont : font,
                    .foregroundColor: cur ? hiC : dimC,
                ]
                let label = "\(n)" as NSString
                let size = label.size(withAttributes: attrs)
                let top = fragTop + inset - visible.minY
                let y = top + (fragHeight - size.height) / 2
                label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y), withAttributes: attrs)
                sepTop = min(sepTop, top)
                sepBottom = max(sepBottom, top + fragHeight)
            }

            var charIdx = 0
            var lineNo = 1
            while ns.length > 0, charIdx < ns.length {
                let lineRange = ns.lineRange(for: NSRange(location: charIdx, length: 0))
                let gr = lm.glyphRange(forCharacterRange: NSRange(location: lineRange.location, length: 0),
                                       actualCharacterRange: nil)
                let gi = min(gr.location, max(0, lm.numberOfGlyphs - 1))
                let frag = lm.lineFragmentRect(forGlyphAt: gi, effectiveRange: nil)
                draw(lineNo, fragTop: frag.minY, fragHeight: frag.height)
                charIdx = NSMaxRange(lineRange)
                lineNo += 1
            }
            // The trailing empty line (doc ends with \n) and the empty document both live in
            // the EXTRA line fragment — always numbered, so the caret's line has its number.
            if ns.length == 0 || ns.hasSuffix("\n") {
                let extra = lm.extraLineFragmentRect
                if extra.height > 0 {
                    draw(lineNo, fragTop: extra.minY, fragHeight: extra.height)
                }
            }
            // Separator: across the numbered span INCLUDING wrapped continuation fragments —
            // a long wrapped line only draws its number on the FIRST fragment, so sepBottom
            // alone stopped short when the last line wrapped. The layout's used extent (plus
            // the extra fragment) is the true bottom of the text.
            let extra = lm.extraLineFragmentRect
            let usedMax = max(lm.usedRect(for: tc).maxY, extra.height > 0 ? extra.maxY : 0)
            sepBottom = max(sepBottom, usedMax + inset - visible.minY)
            // Separator TRIAL-HIDDEN (user request, 2026-08-01): keep the geometry live so
            // flipping `sepAlpha` back is a one-number change if the bare look doesn't land.
            let sepAlpha: CGFloat = 0 // was 0.12
            if sepBottom > 0, sepAlpha > 0 {
                let clampedTop = max(0, sepTop)
                let clampedBottom = min(bounds.height, sepBottom + 2)
                base.withAlphaComponent(sepAlpha).setFill()
                NSRect(x: ruleThickness - 1, y: clampedTop, width: 1,
                       height: max(0, clampedBottom - clampedTop)).fill()
            }
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
        tv.textContainerInset = NSSize(width: 10, height: 6) // gap after the ruler hairline
        tv.placeholderText = placeholder
        tv.themeText = NSColor(theme.text)
        tv.typingAttributes = NativeNoteEditor.baseAttributes(NSColor(theme.text))
        tv.defaultParagraphStyle = NativeNoteEditor.editorParagraphStyle()
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
        session?.end = { [weak co = context.coordinator] in co?.stampCreatedIfDirty() }
        tv.string = text
        context.coordinator.textView = tv
        context.coordinator.key = storageKey
        context.coordinator.highlight()

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.hasVerticalRuler = true
        scroll.verticalRulerView = LineNumberRuler(textView: tv, scroll: scroll)
        scroll.rulersVisible = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let co = context.coordinator
        session?.end = { [weak co] in co?.stampCreatedIfDirty() } // keep the handle fresh
        // Re-key = the previous note's editing session ENDS: stamp it through the OLD parent's
        // onText (still bound to the old storage key) BEFORE adopting the new identity.
        if co.key != storageKey {
            co.stampCreatedIfDirty()
        }
        co.parent = self
        guard let tv = co.textView else { return }
        (tv as? EditorTextView)?.placeholderText = placeholder
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
        // ⌘-click "edit here": select the requested line, reveal it, take focus. Off the
        // update pass (window/first-responder work), deduped per request.
        if let line = focusLine, co.handledFocusLine != line {
            co.handledFocusLine = line
            let handled = onFocusLineHandled
            DispatchQueue.main.async { [weak tv, weak co] in
                guard let tv else { return }
                let ns = tv.string as NSString
                var loc = 0, n = 1
                var range = NSRange(location: 0, length: 0)
                while true {
                    let lineEnd = ns.range(of: "\n", range: NSRange(location: loc, length: ns.length - loc))
                    let end = lineEnd.location == NSNotFound ? ns.length : lineEnd.location
                    if n == line { range = NSRange(location: loc, length: end - loc); break }
                    if lineEnd.location == NSNotFound { range = NSRange(location: end, length: 0); break }
                    loc = lineEnd.location + 1
                    n += 1
                }
                tv.window?.makeFirstResponder(tv)
                tv.setSelectedRange(range)
                tv.scrollRangeToVisible(range)
                co?.handledFocusLine = nil
                handled()
            }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeNoteEditor
        weak var textView: NSTextView?
        var key = ""
        var lastSent: String? // the last body we pushed up — its echo must not re-set the view
        var sessionDirty = false // the user edited THIS note since load / last stamp
        var handledFocusLine: Int? // last ⌘-click focus request already applied (dedup)

        init(_ parent: NativeNoteEditor) {
            self.parent = parent
        }

        /// CodeMirror's insertNewlineContinueMarkup + indentMore/indentLess, natively:
        /// Enter inside a todo/bullet/ordered/quote line continues the marker ("- [ ] " fresh
        /// and unchecked, numbers incremented); Enter on an EMPTY marker clears it (ends the
        /// list); Tab/⇧Tab indent/outdent the selected line(s) by two spaces.
        func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.insertNewline(_:)):
                return continueMarkup(tv)
            case #selector(NSResponder.insertTab(_:)):
                return indent(tv, out: false)
            case #selector(NSResponder.insertBacktab(_:)):
                return indent(tv, out: true)
            default:
                return false
            }
        }

        private static let markerRe = try! NSRegularExpression(
            pattern: #"^(\s*)(?:([-*+])\s+\[[ xX]\]\s*|([-*+])\s+|(\d+)([.)])\s+|(>)\s*)(.*)$"#)

        private func continueMarkup(_ tv: NSTextView) -> Bool {
            let ns = tv.string as NSString
            let sel = tv.selectedRange()
            let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
            var lineText = ns.substring(with: line)
            if lineText.hasSuffix("\n") { lineText.removeLast() }
            let lineNS = lineText as NSString
            guard let m = Self.markerRe.firstMatch(
                in: lineText, range: NSRange(location: 0, length: lineNS.length))
            else { return false } // plain line → default newline
            let rest = lineNS.substring(with: m.range(at: 7))
            let indent = lineNS.substring(with: m.range(at: 1))
            // Empty item + Enter = end the list: clear the marker, leave a blank line.
            if rest.trimmingCharacters(in: .whitespaces).isEmpty, sel.length == 0,
               sel.location >= line.location + lineNS.length {
                let content = NSRange(location: line.location,
                                      length: min(lineNS.length, line.length))
                guard tv.shouldChangeText(in: content, replacementString: indent) else { return true }
                tv.textStorage?.replaceCharacters(in: content, with: indent)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: line.location + (indent as NSString).length,
                                            length: 0))
                return true
            }
            var prefix: String
            if m.range(at: 2).location != NSNotFound { // todo → fresh unchecked box
                prefix = indent + lineNS.substring(with: m.range(at: 2)) + " [ ] "
            } else if m.range(at: 3).location != NSNotFound { // bullet
                prefix = indent + lineNS.substring(with: m.range(at: 3)) + " "
            } else if m.range(at: 4).location != NSNotFound { // ordered → n+1
                let n = (Int(lineNS.substring(with: m.range(at: 4))) ?? 0) + 1
                prefix = indent + String(n) + lineNS.substring(with: m.range(at: 5)) + " "
            } else { // quote
                prefix = indent + "> "
            }
            let insert = "\n" + prefix
            guard tv.shouldChangeText(in: sel, replacementString: insert) else { return true }
            tv.textStorage?.replaceCharacters(in: sel, with: insert)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: sel.location + (insert as NSString).length,
                                        length: 0))
            tv.scrollRangeToVisible(tv.selectedRange())
            return true
        }

        private func indent(_ tv: NSTextView, out: Bool) -> Bool {
            let ns = tv.string as NSString
            let sel = tv.selectedRange()
            let block = ns.lineRange(for: sel)
            let text = ns.substring(with: block)
            var lines = text.components(separatedBy: "\n")
            let trailing = lines.last == "" // block ends with \n → empty tail element
            if trailing { lines.removeLast() }
            var firstDelta = 0
            var total = 0
            for i in lines.indices {
                if out {
                    let drop = min(2, lines[i].prefix(2).prefix(while: { $0 == " " }).count)
                    lines[i] = String(lines[i].dropFirst(drop))
                    if i == 0 { firstDelta = -drop }
                    total -= drop
                } else {
                    lines[i] = "  " + lines[i]
                    if i == 0 { firstDelta = 2 }
                    total += 2
                }
            }
            let next = lines.joined(separator: "\n") + (trailing ? "\n" : "")
            guard next != text else { return true }
            guard tv.shouldChangeText(in: block, replacementString: next) else { return true }
            tv.textStorage?.replaceCharacters(in: block, with: next)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: max(block.location, sel.location + firstDelta),
                                        length: max(0, sel.length + total - firstDelta)))
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            let s = tv.string
            lastSent = s
            sessionDirty = true
            parent.onText(s)
            highlight()
            // Auto-open the completion popup while typing inside a trigger (the web's
            // live autocompletion) — only when there's something to show (an empty list
            // would beep). Acceptance re-fires textDidChange: `completing` gates the
            // reopen so an accepted entity doesn't immediately pop the list again
            // (the "project:"/"person:" reopeners bypass via insertCompletion).
            guard !completing, tv.window?.firstResponder === tv,
                  let t = NativeNoteEditor.completionTrigger(in: tv),
                  !NativeNoteEditor.completionOptions(for: t,
                                                      index: parent.completionIndex?(),
                                                      dueAnchor: parent.dueAnchor?() ?? nil)
                  .isEmpty
            else { return }
            completing = true
            tv.complete(nil)
            completing = false
        }

        var completing = false

        func textView(_ tv: NSTextView, completions _: [String],
                      forPartialWordRange charRange: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            guard let t = NativeNoteEditor.completionTrigger(in: tv),
                  t.partialRange == charRange else { return [] }
            index?.pointee = 0
            return NativeNoteEditor.completionOptions(for: t,
                                                      index: parent.completionIndex?(),
                                                      dueAnchor: parent.dueAnchor?() ?? nil)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            textView?.needsDisplay = true // active-line wash follows the caret
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
        // Inline spans (the web's mdHighlight tags): **strong**, *em*/_em_, ~~strike~~,
        // `code`, and "> " quote lines in grey italic — markers stay visible (source view),
        // styled dim like CodeMirror's processingInstruction tag.
        private static let headRe = Re2(#"^#{1,6} .*$"#)
        private static let taskRe = Re2(#"^\s*(?:[-*+]|\d+[.)])\s+\[([ xX])\]"#)
        private static let doneLineRe = Re2(#"^\s*(?:[-*+]|\d+[.)])\s+\[[xX]\].*$"#)
        private static let tokenRe = Re2(
            #"(^|\s)(due:\S+|start:\S+|tz:\S+|color:\S+|done:\S+|created:\S+|followup:\S+|p:!{1,5}|#[A-Za-z0-9_][\w-]*|@[A-Za-z0-9_][\w:-]*|project:[A-Za-z0-9_-]+)(?=\s|$)"#)
        private static let linkRe = Re2(#"\[[^\]]*\]\([^)\s]+\)"#)
        private static let boldRe = Re2(#"\*\*[^*\n]+\*\*|__[^_\n]+__"#)
        private static let emRe = Re2(#"(?<![*_\w])(\*|_)(?![*_\s])[^*_\n]+\1(?![*_\w])"#)
        private static let strikeSpanRe = Re2(#"~~[^~\n]+~~"#)
        private static let codeSpanRe = Re2(#"`[^`\n]+`"#)
        private static let quoteLineRe = Re2(#"^\s*> .*$"#)

        func highlight() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let s = tv.string as NSString
            let all = NSRange(location: 0, length: s.length)
            let base = NSColor(parent.theme.text)
            let dim = base.withAlphaComponent(0.45)
            let accent = NSColor(Theme.accent)
            storage.beginEditing()
            storage.setAttributes(NativeNoteEditor.baseAttributes(base), range: all)
            s.enumerateSubstrings(in: all, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
                let line = s.substring(with: lineRange)
                if Coordinator.headRe.matches(line) {
                    storage.addAttribute(.font, value: NativeNoteEditor.monoFont(bold: true),
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
                let at = { (r: NSRange) in
                    NSRange(location: lineRange.location + r.location, length: r.length)
                }
                if Coordinator.quoteLineRe.matches(line) {
                    storage.addAttributes([
                        .foregroundColor: base.withAlphaComponent(0.6),
                        .obliqueness: 0.18, // Menlo has no true italic face — synthesized slant
                    ], range: lineRange)
                }
                for r in Coordinator.boldRe.ranges(line) {
                    storage.addAttribute(.font, value: NativeNoteEditor.monoFont(bold: true),
                                         range: at(r))
                }
                for r in Coordinator.emRe.ranges(line) {
                    storage.addAttribute(.obliqueness, value: 0.18, range: at(r))
                }
                for r in Coordinator.strikeSpanRe.ranges(line) {
                    storage.addAttribute(.strikethroughStyle,
                                         value: NSUnderlineStyle.single.rawValue, range: at(r))
                }
                for r in Coordinator.codeSpanRe.ranges(line) {
                    storage.addAttributes([
                        .foregroundColor: base.withAlphaComponent(0.85),
                        .backgroundColor: base.withAlphaComponent(0.07),
                    ], range: at(r))
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
