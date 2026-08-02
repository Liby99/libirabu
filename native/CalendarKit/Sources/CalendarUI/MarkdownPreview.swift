// The refined markdown PREVIEW engine (user spec): ONE selectable NSTextView document — so the
// whole rendered note can be dragged over and copied like a page, which no SwiftUI Text stack
// can do — with bigger type, breathing room, accent links, padded quote blocks, GFM tables
// (NSTextTable), and syntax-highlighted code fences for the house languages (c, c++, rust, py,
// js, ts, ocaml, lean, haskell, java, julia). Interactivity is preserved: todo checkboxes are
// tappable attachments (cc-todo:// links), and ⌘-click anywhere jumps to the source line.
// UTF-8 is native throughout (NSAttributedString). MarkdownBlocksView stays for the phone.

import AppKit
import CalendarEngine
import CalendarRender
import SwiftUI

struct MarkdownPreview: NSViewRepresentable {
    let text: String
    let theme: Theme
    var onToggle: ((Int) -> Void)? // 1-based source line of a tapped todo checkbox
    var onLineEdit: ((Int) -> Void)? // ⌘-click → edit at this source line

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = PreviewTextView()
        tv.isEditable = false
        tv.isSelectable = true // the whole document selects/copies like a page
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 2, height: 6)
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        tv.linkTextAttributes = [.cursor: NSCursor.pointingHand] // colors are ours (accent)
        tv.delegate = context.coordinator
        context.coordinator.textView = tv
        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        context.coordinator.rebuild(self)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.rebuild(self)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownPreview
        weak var textView: PreviewTextView?
        private var renderedKey = "\u{0}"

        init(_ parent: MarkdownPreview) { self.parent = parent }

        func rebuild(_ p: MarkdownPreview) {
            parent = p
            guard let tv = textView else { return }
            let key = p.text + "|" + NSColor(p.theme.text).description
            guard key != renderedKey else { return }
            renderedKey = key
            let doc = MarkdownDoc.render(p.text, theme: p.theme, interactive: p.onToggle != nil)
            tv.lineMap = doc.lineMap
            tv.onCmdClickLine = p.onLineEdit
            tv.textStorage?.setAttributedString(doc.string)
        }

        func textView(_ tv: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = link as? URL ?? (link as? String).flatMap(URL.init(string:))
            guard let url else { return false }
            if url.scheme == "cc-todo", let line = Int(url.host ?? "") {
                parent.onToggle?(line)
                return true
            }
            return false // real links → AppKit opens them
        }
    }
}

/// ⌘-click → source line (via the renderer's line map); plain clicks select as usual.
final class PreviewTextView: NSTextView {
    var lineMap: [(range: NSRange, line: Int)] = []
    var onCmdClickLine: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let onCmdClickLine {
            let pt = convert(event.locationInWindow, from: nil)
            let idx = characterIndexForInsertion(at: pt)
            if let hit = lineMap.last(where: { $0.range.location <= idx }) {
                onCmdClickLine(hit.line)
                return
            }
        }
        super.mouseDown(with: event)
    }
}

// ── The document builder ─────────────────────────────────────────────────────────────────────

enum MarkdownDoc {
    struct Rendered {
        let string: NSAttributedString
        let lineMap: [(range: NSRange, line: Int)]
    }

    // Type scale (the "bigger, better" pass): body 13.5, headings 19/16.5/15/14.
    static let bodySize: CGFloat = 13.5
    static func bodyFont(_ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: bodySize, weight: weight)
    }

    static func headingFont(_ level: Int) -> NSFont {
        switch level {
        case 1: .systemFont(ofSize: 19, weight: .bold)
        case 2: .systemFont(ofSize: 16.5, weight: .bold)
        case 3: .systemFont(ofSize: 15, weight: .semibold)
        default: .systemFont(ofSize: 14, weight: .semibold)
        }
    }

    static let codeFont = NSFont(name: "Menlo", size: 12.5)
        ?? .monospacedSystemFont(ofSize: 12.5, weight: .regular)

    static func render(_ text: String, theme: Theme, interactive: Bool) -> Rendered {
        var out = NSMutableAttributedString()
        var lineMap: [(NSRange, Int)] = []
        let base = NSColor(theme.text)
        let accent = NSColor(Theme.accent)

        let (managedRaw, userText) = ManagedNote.splitNote(text)
        if !managedRaw.isEmpty {
            appendManaged(managedRaw, to: &out, base: base, accent: accent, theme: theme)
        }
        let startLine = managedRaw.isEmpty ? 1 : userStartLine(userText, in: text)
        appendBlocks(userText, startLine: startLine, to: &out, lineMap: &lineMap,
                     base: base, accent: accent, theme: theme, interactive: interactive)
        return Rendered(string: out, lineMap: lineMap)
    }

    private static func userStartLine(_ user: String, in text: String) -> Int {
        guard !user.isEmpty, let r = text.range(of: user, options: .backwards) else { return 1 }
        return text[..<r.lowerBound].reduce(into: 1) { if $1 == "\n" { $0 += 1 } }
    }

    // ── Block walk ───────────────────────────────────────────────────────────────────────────

    private static func appendBlocks(_ source: String, startLine: Int,
                                     to out: inout NSMutableAttributedString,
                                     lineMap: inout [(NSRange, Int)],
                                     base: NSColor, accent: NSColor, theme: Theme,
                                     interactive: Bool) {
        let lines = source.components(separatedBy: "\n")
        var i = 0
        var codeLang = ""
        var codeLines: [String]? = nil
        var codeStart = 0

        func mark(_ from: Int, line: Int) {
            lineMap.append((NSRange(location: from, length: out.length - from), line))
        }

        while i < lines.count {
            let srcLine = startLine + i
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)
            let from = out.length
            defer { i += 1 }

            if let open = codeLines {
                if line.hasPrefix("```") {
                    appendCode(open.joined(separator: "\n"), lang: codeLang, to: &out,
                               base: base, theme: theme)
                    mark(from, line: codeStart)
                    codeLines = nil
                } else {
                    codeLines!.append(raw)
                }
                continue
            }
            if line.hasPrefix("```") {
                codeLang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                codeLines = []
                codeStart = srcLine
                continue
            }
            if line.isEmpty { continue }

            // GFM table: a pipe row followed by the separator row.
            if line.hasPrefix("|"), i + 1 < lines.count,
               lines[i + 1].trimmingCharacters(in: .whitespaces)
               .range(of: #"^\|?[\s:|-]+\|?$"#, options: .regularExpression) != nil,
               lines[i + 1].contains("-") {
                var rows: [[String]] = [tableCells(line)]
                var j = i + 2
                while j < lines.count {
                    let r = lines[j].trimmingCharacters(in: .whitespaces)
                    if r.hasPrefix("|") { rows.append(tableCells(r)); j += 1 } else { break }
                }
                appendTable(rows, to: &out, base: base, accent: accent, theme: theme)
                mark(from, line: srcLine)
                i = j - 1
                continue
            }

            if let (done, rest) = todoLine(line) {
                appendTodo(rest, done: done, line: srcLine, indent: indentDepth(raw),
                           to: &out, base: base, accent: accent, interactive: interactive)
            } else if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                let body = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                let para = paragraph(spacingBefore: out.length == 0 ? 2 : 11, spacing: 5)
                out.append(inline(body, font: headingFont(level), color: base,
                                  accent: accent, para: para))
                out.append(newline(para))
            } else if let rest = strip(line, ["- ", "* ", "+ "]) {
                appendListItem("•", rest, indent: indentDepth(raw), to: &out,
                               base: base, accent: accent)
            } else if let m = line.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                appendListItem(String(line[..<m.upperBound]).trimmingCharacters(in: .whitespaces),
                               String(line[m.upperBound...]), indent: indentDepth(raw),
                               to: &out, base: base, accent: accent)
            } else if let rest = strip(line, ["> "]) {
                appendQuote(rest, to: &out, base: base, accent: accent, theme: theme)
            } else {
                let para = paragraph(spacing: 6)
                out.append(inline(line, font: bodyFont(), color: base, accent: accent, para: para))
                out.append(newline(para))
            }
            mark(from, line: srcLine)
        }
        if let open = codeLines { // unterminated fence
            let from = out.length
            appendCode(open.joined(separator: "\n"), lang: codeLang, to: &out,
                       base: base, theme: theme)
            mark(from, line: codeStart)
        }
    }

    // ── Block renderers ──────────────────────────────────────────────────────────────────────

    private static func appendTodo(_ text: String, done: Bool, line: Int, indent: Int,
                                   to out: inout NSMutableAttributedString,
                                   base: NSColor, accent: NSColor, interactive: Bool) {
        let para = paragraph(spacing: 4)
        let ind = CGFloat(indent) * 18
        para.firstLineHeadIndent = ind
        para.headIndent = ind + 22
        let att = NSTextAttachment()
        att.image = checkboxImage(checked: done, accent: accent, grey: base.withAlphaComponent(0.45))
        att.bounds = CGRect(x: 0, y: -3.5, width: 15, height: 15)
        let box = NSMutableAttributedString(attachment: att)
        if interactive {
            box.addAttributes([.link: URL(string: "cc-todo://\(line)")!,
                               .cursor: NSCursor.pointingHand],
                              range: NSRange(location: 0, length: box.length))
        }
        box.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: box.length))
        out.append(box)
        out.append(NSAttributedString(string: "  ", attributes: [
            .font: bodyFont(), .paragraphStyle: para,
        ]))
        let tok = TodoIndex.tokenizeLine(text)
        let body = inline(tok.text, font: bodyFont(), color: done ? base.withAlphaComponent(0.45) : base,
                          accent: accent, para: para)
        if done {
            let m = NSMutableAttributedString(attributedString: body)
            m.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                           range: NSRange(location: 0, length: m.length))
            out.append(m)
        } else {
            out.append(body)
        }
        // Token PILLS — the web previewer's .cc-todo-tok badges, as rendered attachments:
        // mono micro-pills with per-kind hues, faint uppercase prefixes on value tokens,
        // priority white-on-red at level 4+, teal followup; all dimmed on a completed task.
        let alpha: CGFloat = done ? 0.55 : 1
        func pill(_ spec: ChipSpec) {
            let att = NSTextAttachment()
            let img = chipImage(spec, alpha: alpha)
            att.image = img
            att.bounds = CGRect(x: 0, y: -3, width: img.size.width, height: img.size.height)
            let a = NSMutableAttributedString(string: " ", attributes: [.font: bodyFont(),
                                                                        .paragraphStyle: para])
            a.append(NSAttributedString(attachment: att))
            a.addAttribute(.paragraphStyle, value: para,
                           range: NSRange(location: 0, length: a.length))
            out.append(a)
        }
        let grey = ChipSpec.greyStyle(base: base)
        if let p = tok.priority {
            pill(ChipSpec.priority(level: p, accent: accent))
        }
        if let due = tok.due { pill(grey.with(prefix: "DUE", text: due)) }
        if let st = tok.start { pill(grey.with(prefix: "FROM", text: st)) }
        if let d = tok.done { pill(grey.with(prefix: "DONE", text: d, extraDim: true)) }
        if let f = tok.followup { pill(ChipSpec.followup(f)) }
        for tag in tok.tags { pill(ChipSpec.tag("#" + tag, accent: accent)) }
        for person in tok.entities["person"] ?? [] { pill(ChipSpec.person("@" + person)) }
        for proj in tok.entities["project"] ?? [] { pill(ChipSpec.project("@" + proj)) }
        out.append(newline(para))
    }

    private static func appendListItem(_ marker: String, _ text: String, indent: Int,
                                       to out: inout NSMutableAttributedString,
                                       base: NSColor, accent: NSColor) {
        let para = paragraph(spacing: 4)
        let ind = CGFloat(indent) * 18
        para.firstLineHeadIndent = ind
        para.headIndent = ind + 18
        out.append(NSAttributedString(string: marker + "  ", attributes: [
            .font: bodyFont(), .foregroundColor: base.withAlphaComponent(0.5),
            .paragraphStyle: para,
        ]))
        out.append(inline(text, font: bodyFont(), color: base, accent: accent, para: para))
        out.append(newline(para))
    }

    private static func appendQuote(_ text: String, to out: inout NSMutableAttributedString,
                                    base: NSColor, accent: NSColor, theme: Theme) {
        // The "> " block: bordered left edge + REAL top/bottom padding (user spec).
        let block = NSTextBlock()
        block.setBorderColor(accent.withAlphaComponent(0.55), for: .minX)
        block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
        block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .maxY)
        block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
        block.backgroundColor = base.withAlphaComponent(0.03)
        block.setContentWidth(100, type: .percentageValueType) // else the block collapses → 1-char lines
        let para = paragraph(spacing: 7)
        para.textBlocks = [block]
        out.append(inline(text, font: bodyFont(), color: base.withAlphaComponent(0.65),
                          accent: accent, para: para))
        out.append(newline(para))
    }

    private static func appendCode(_ code: String, lang: String,
                                   to out: inout NSMutableAttributedString,
                                   base: NSColor, theme: Theme) {
        let block = NSTextBlock()
        block.backgroundColor = base.withAlphaComponent(0.055)
        for edge in [NSRectEdge.minX, .maxX, .minY, .maxY] {
            block.setWidth(edge == .minX || edge == .maxX ? 10 : 8,
                           type: .absoluteValueType, for: .padding, edge: edge)
        }
        block.setContentWidth(100, type: .percentageValueType) // same collapse guard as quotes
        let para = paragraph(spacing: 8)
        para.textBlocks = [block]
        para.lineSpacing = 1.5
        let highlighted = CodeHighlight.highlight(code, lang: lang, base: base, font: codeFont)
        let m = NSMutableAttributedString(attributedString: highlighted)
        m.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: m.length))
        out.append(m)
        out.append(newline(para))
    }

    private static func appendTable(_ rows: [[String]], to out: inout NSMutableAttributedString,
                                    base: NSColor, accent: NSColor, theme: Theme) {
        guard let cols = rows.map(\.count).max(), cols > 0 else { return }
        let table = NSTextTable()
        table.numberOfColumns = cols
        table.setContentWidth(100, type: .percentageValueType)
        for (r, row) in rows.enumerated() {
            for c in 0 ..< cols {
                let cell = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1,
                                            startingColumn: c, columnSpan: 1)
                cell.setBorderColor(base.withAlphaComponent(0.18))
                cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                for edge in [NSRectEdge.minX, .maxX] {
                    cell.setWidth(8, type: .absoluteValueType, for: .padding, edge: edge)
                }
                for edge in [NSRectEdge.minY, .maxY] {
                    cell.setWidth(4.5, type: .absoluteValueType, for: .padding, edge: edge)
                }
                if r == 0 { cell.backgroundColor = base.withAlphaComponent(0.06) }
                let para = paragraph(spacing: 0)
                para.textBlocks = [cell]
                let text = c < row.count ? row[c] : ""
                out.append(inline(text, font: r == 0 ? bodyFont(.semibold) : bodyFont(),
                                  color: base, accent: accent, para: para))
                out.append(newline(para))
            }
        }
    }

    private static func appendManaged(_ raw: String, to out: inout NSMutableAttributedString,
                                      base: NSColor, accent: NSColor, theme: Theme) {
        let parsed = ManagedNote.parseManaged(raw)
        if !parsed.fields.isEmpty {
            let table = NSTextTable()
            table.numberOfColumns = 2
            for (r, f) in parsed.fields.enumerated() {
                for c in 0 ... 1 {
                    let cell = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1,
                                                startingColumn: c, columnSpan: 1)
                    cell.setWidth(c == 0 ? 0 : 6, type: .absoluteValueType, for: .padding, edge: .minX)
                    cell.setWidth(2.5, type: .absoluteValueType, for: .padding, edge: .minY)
                    cell.setWidth(2.5, type: .absoluteValueType, for: .padding, edge: .maxY)
                    if c == 0 { cell.setContentWidth(96, type: .absoluteValueType) }
                    let para = paragraph(spacing: 0)
                    para.textBlocks = [cell]
                    if c == 0 {
                        out.append(NSAttributedString(string: f.label, attributes: [
                            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                            .foregroundColor: base.withAlphaComponent(0.5),
                            .paragraphStyle: para,
                        ]))
                    } else if let href = f.href, let url = URL(string: href) {
                        out.append(NSAttributedString(string: f.value, attributes: [
                            .font: bodyFont(), .foregroundColor: accent,
                            .underlineStyle: NSUnderlineStyle.single.rawValue,
                            .link: url, .cursor: NSCursor.pointingHand,
                            .paragraphStyle: para,
                        ]))
                    } else {
                        out.append(NSAttributedString(string: f.value, attributes: [
                            .font: bodyFont(), .foregroundColor: base.withAlphaComponent(0.85),
                            .paragraphStyle: para,
                        ]))
                    }
                    out.append(newline(para))
                }
            }
        }
        if !parsed.description.isEmpty {
            var lineMapScratch: [(NSRange, Int)] = []
            appendBlocks(parsed.description, startLine: -100_000, to: &out,
                         lineMap: &lineMapScratch, base: base, accent: accent,
                         theme: theme, interactive: false) // vendor text: no line actions
        }
    }

    // ── Inline + helpers ─────────────────────────────────────────────────────────────────────

    /// Inline spans through Foundation's markdown parser, re-attributed for AppKit: bold,
    /// italic, ~~strike~~, `code` (Menlo + wash), [links](…) in the ACCENT color, underlined.
    static func inline(_ s: String, font: NSFont, color: NSColor, accent: NSColor,
                       para: NSParagraphStyle) -> NSAttributedString {
        let parsed = (try? AttributedString(
            markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color, .paragraphStyle: para,
            ]
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.stronglyEmphasized) {
                attrs[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if intent.contains(.emphasized) {
                attrs[.obliqueness] = 0.16
            }
            if intent.contains(.strikethrough) {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if intent.contains(.code) {
                attrs[.font] = NSFont(name: "Menlo", size: font.pointSize - 1.5)
                    ?? .monospacedSystemFont(ofSize: font.pointSize - 1.5, weight: .regular)
                attrs[.backgroundColor] = color.withAlphaComponent(0.08)
            }
            if let link = run.link {
                attrs[.link] = link
                attrs[.foregroundColor] = accent
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attrs[.cursor] = NSCursor.pointingHand
            }
            out.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return out
    }

    private static func paragraph(spacingBefore: CGFloat = 0, spacing: CGFloat)
        -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = spacingBefore
        p.paragraphSpacing = spacing
        p.lineSpacing = 1.5
        return p
    }

    private static func newline(_ para: NSParagraphStyle) -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: [.paragraphStyle: para])
    }

    private static func todoLine(_ line: String) -> (Bool, String)? {
        for p in ["- [ ] ", "* [ ] ", "+ [ ] "] where line.hasPrefix(p) {
            return (false, String(line.dropFirst(p.count)))
        }
        for p in ["- [x] ", "- [X] ", "* [x] ", "* [X] ", "+ [x] ", "+ [X] "] where line.hasPrefix(p) {
            return (true, String(line.dropFirst(p.count)))
        }
        return nil
    }

    private static func strip(_ line: String, _ prefixes: [String]) -> String? {
        for p in prefixes where line.hasPrefix(p) {
            return String(line.dropFirst(p.count))
        }
        return nil
    }

    private static func indentDepth(_ raw: String) -> Int {
        raw.prefix(while: { $0 == " " || $0 == "\t" })
            .reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
    }

    private static func tableCells(_ line: String) -> [String] {
        var l = line
        if l.hasPrefix("|") { l.removeFirst() }
        if l.hasSuffix("|") { l.removeLast() }
        return l.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // ── Token pills (the web's .cc-todo-tok badges) ─────────────────────────────────────────
    struct ChipSpec {
        var prefix: String? // faint uppercase key ("DUE", "FROM", "↪ FOLLOWUP")
        var text: String
        var fg: NSColor
        var border: NSColor
        var bg: NSColor
        var bold = false
        var extraDim = false

        static func greyStyle(base: NSColor) -> ChipSpec {
            ChipSpec(prefix: nil, text: "", fg: base.withAlphaComponent(0.8),
                     border: base.withAlphaComponent(0.25), bg: base.withAlphaComponent(0.06))
        }

        func with(prefix: String, text: String, extraDim: Bool = false) -> ChipSpec {
            var c = self
            c.prefix = prefix
            c.text = text
            c.extraDim = extraDim
            return c
        }

        static func priority(level: Int, accent: NSColor) -> ChipSpec {
            level >= 4
                ? ChipSpec(prefix: nil, text: String(repeating: "!", count: level),
                           fg: .white, border: accent, bg: accent, bold: true)
                : ChipSpec(prefix: nil, text: String(repeating: "!", count: level),
                           fg: accent, border: accent.withAlphaComponent(0.45),
                           bg: accent.withAlphaComponent(0.12), bold: true)
        }

        static func followup(_ v: String) -> ChipSpec {
            let teal = NSColor(calibratedRed: 0x2F / 255, green: 0x8A / 255, blue: 0x8A / 255, alpha: 1)
            return ChipSpec(prefix: "↪ FOLLOWUP", text: v, fg: teal,
                            border: teal.withAlphaComponent(0.42), bg: teal.withAlphaComponent(0.11))
        }

        static func tag(_ t: String, accent: NSColor) -> ChipSpec {
            ChipSpec(prefix: nil, text: t, fg: accent,
                     border: accent.withAlphaComponent(0.38), bg: accent.withAlphaComponent(0.09))
        }

        static func person(_ t: String) -> ChipSpec {
            let hue = NSColor(calibratedRed: 0x7F / 255, green: 0x95 / 255, blue: 0xD8 / 255, alpha: 1)
            return ChipSpec(prefix: nil, text: t, fg: hue,
                            border: hue.withAlphaComponent(0.5), bg: hue.withAlphaComponent(0.12))
        }

        static func project(_ t: String) -> ChipSpec {
            let hue = NSColor(calibratedRed: 0x7F / 255, green: 0xAE / 255, blue: 0x6B / 255, alpha: 1)
            return ChipSpec(prefix: nil, text: t, fg: hue,
                            border: hue.withAlphaComponent(0.5), bg: hue.withAlphaComponent(0.12))
        }
    }

    private static var chipCache: [String: NSImage] = [:]
    static func chipImage(_ spec: ChipSpec, alpha: CGFloat) -> NSImage {
        let key = "\(spec.prefix ?? "")|\(spec.text)|\(spec.fg.description)|\(spec.bg.description)|\(spec.bold)|\(spec.extraDim)|\(alpha)"
        if let hit = chipCache[key] { return hit }
        let mono = NSFont(name: spec.bold ? "Menlo-Bold" : "Menlo", size: 10)
            ?? .monospacedSystemFont(ofSize: 10, weight: spec.bold ? .bold : .regular)
        let prefixFont = NSFont(name: "Menlo-Bold", size: 8.2) ?? mono
        let a = alpha * (spec.extraDim ? 0.7 : 1)
        let fg = spec.fg.withAlphaComponent(spec.fg.alphaComponent * a)
        let textAttrs: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: fg]
        let prefixAttrs: [NSAttributedString.Key: Any] = [
            .font: prefixFont, .foregroundColor: fg.withAlphaComponent(fg.alphaComponent * 0.6),
        ]
        let textSize = (spec.text as NSString).size(withAttributes: textAttrs)
        let prefixSize = spec.prefix.map { ($0 as NSString).size(withAttributes: prefixAttrs) }
        let gap: CGFloat = prefixSize != nil ? 3.5 : 0
        let padX: CGFloat = 6.5
        let h: CGFloat = 15.5
        let w = padX * 2 + (prefixSize?.width ?? 0) + gap + textSize.width
        let img = NSImage(size: NSSize(width: ceil(w), height: h), flipped: false) { _ in
            let rect = NSRect(x: 0.5, y: 0.5, width: ceil(w) - 1, height: h - 1)
            let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2,
                                    yRadius: rect.height / 2)
            spec.bg.withAlphaComponent(spec.bg.alphaComponent * a).setFill()
            path.fill()
            spec.border.withAlphaComponent(spec.border.alphaComponent * a).setStroke()
            path.lineWidth = 1
            path.stroke()
            var x = padX
            if let p = spec.prefix, let ps = prefixSize {
                (p as NSString).draw(at: NSPoint(x: x, y: (h - ps.height) / 2),
                                     withAttributes: prefixAttrs)
                x += ps.width + gap
            }
            (spec.text as NSString).draw(at: NSPoint(x: x, y: (h - textSize.height) / 2),
                                         withAttributes: textAttrs)
            return true
        }
        if chipCache.count > 512 { chipCache.removeAll() }
        chipCache[key] = img
        return img
    }

    // ── Checkbox images (the house DashCheckbox look, as attachments) ──
    private static var checkboxCache: [String: NSImage] = [:]
    private static func checkboxImage(checked: Bool, accent: NSColor, grey: NSColor) -> NSImage {
        let key = "\(checked)|\(accent.description)|\(grey.description)"
        if let hit = checkboxCache[key] { return hit }
        let img = NSImage(size: NSSize(width: 15, height: 15), flipped: false) { _ in
            let r = NSRect(x: 0.75, y: 0.75, width: 13.5, height: 13.5)
            let path = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
            if checked {
                accent.setFill()
                path.fill()
                let check = NSBezierPath()
                check.move(to: NSPoint(x: 4, y: 7.6))
                check.line(to: NSPoint(x: 6.4, y: 5.2))
                check.line(to: NSPoint(x: 11, y: 10))
                check.lineWidth = 1.8
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                NSColor.white.setStroke()
                check.stroke()
            } else {
                grey.setStroke()
                path.lineWidth = 1.5
                path.stroke()
            }
            return true
        }
        checkboxCache[key] = img
        return img
    }
}
