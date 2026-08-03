// RETIRED (audit round, 2026-08-02): the SwiftUI Text-stack markdown preview, superseded by
// MarkdownPreview (one selectable NSTextView document — tables, code highlighting, whole-note
// selection). Zero references remained in the build (the "stays for the phone" plan never
// materialized; PhoneMarkdown has its own renderer). Relocated per the never-delete rule.
// ModifierWatch (the shared ⌘-state monitor) moved with it — MarkdownBlocksView was its only
// consumer. DashCheckbox/PressScaleStyle stayed live in Sources/CalendarRender/MarkdownBlocks.swift.

import CalendarEngine
import SwiftUI
#if canImport(AppKit)
    import AppKit

    /// Live ⌘-key state for the preview's edit-here capture layer. One shared flagsChanged
    /// monitor; @Observable so views re-render exactly when the modifier flips. macOS only —
    /// the phone build has no ⌘-click affordance.
    @MainActor @Observable public final class ModifierWatch {
        public static let shared = ModifierWatch()
        public private(set) var command = false
        private var monitor: Any?

        private init() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
                self?.command = e.modifierFlags.contains(.command)
                return e
            }
        }
    }
#endif

public struct MarkdownBlocksView: View {
    let text: String
    let accent: Color // checked todos + quote bars pick this up
    let theme: Theme
    var onToggle: ((Int) -> Void)? // 1-based source line of a tapped todo checkbox; nil = read-only
    /// ⌘-click on a block → "edit here": reports the block's 1-based source line (the web
    /// preview's data-srcline → onEditAt flow). nil = plain preview.
    var onLineEdit: ((Int) -> Void)?

    public init(text: String, accent: Color, theme: Theme, onToggle: ((Int) -> Void)? = nil,
                onLineEdit: ((Int) -> Void)? = nil) {
        self.text = text; self.accent = accent; self.theme = theme; self.onToggle = onToggle
        self.onLineEdit = onLineEdit
    }

    public var body: some View {
        #if canImport(AppKit)
            let cmdDown = onLineEdit != nil && ModifierWatch.shared.command
        #else
            let cmdDown = false
        #endif
        let (managedRaw, userText) = ManagedNote.splitNote(text)
        VStack(alignment: .leading, spacing: 8) {
            if !managedRaw.isEmpty {
                managedBlock(managedRaw)
            }
            ForEach(managedRaw.isEmpty ? blocks()
                : blocks(of: userText, startLine: userStartLine(userText))) { b in
                    if let onLineEdit {
                        // Edit-here capture: while ⌘ is HELD, a full-width transparent layer sits
                        // over the whole row and takes the click — anywhere on the line, any block
                        // kind (paragraphs, headers, todos, code). A tap gesture on the text alone
                        // loses to text-selection handling and only covers the glyph width; the
                        // conditional overlay wins the hit-test outright and vanishes when ⌘ lifts,
                        // so plain clicks (selection, checkboxes, links) are untouched.
                        blockView(b)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay {
                                if cmdDown {
                                    Rectangle().fill(Color.black.opacity(0.0001))
                                        .onTapGesture { onLineEdit(b.id) }
                                }
                            }
                    } else {
                        blockView(b)
                    }
                }
        }
        .textSelection(.enabled)
    }

    // ── Block model ──────────────────────────────────────────────────────────────────────────

    private enum Kind {
        case heading(Int)
        case todo(done: Bool, tok: TodoLineTokens, indent: Int)
        case bullet(indent: Int)
        case ordered(Int, indent: Int)
        case quote
        case code // whole fenced block, text = joined lines
        case para
    }

    private struct Block: Identifiable {
        let id: Int // the 1-based source line (code blocks: the fence line) — todo toggles key on it
        let kind: Kind
        let text: String
    }

    private func blocks() -> [Block] {
        blocks(of: text, startLine: 1)
    }

    /// The 1-based line where the user postfix begins in the STORED note — keeps checkbox
    /// toggles and ⌘-click line ids true to the underlying string when a managed block leads.
    private func userStartLine(_ user: String) -> Int {
        guard !user.isEmpty, let r = text.range(of: user, options: .backwards) else { return 1 }
        return text[..<r.lowerBound].reduce(into: 1) {
            if $1 == "\n" {
                $0 += 1
            }
        }
    }

    /// An imported event's managed block: the web's read-only key/value table (provenance,
    /// meeting link, organizer, attendees, …) on a soft card, plus the free-text description
    /// rendered as plain markdown below (line actions off — vendor text maps to no user line).
    @ViewBuilder private func managedBlock(_ raw: String) -> some View {
        let parsed = ManagedNote.parseManaged(raw)
        VStack(alignment: .leading, spacing: 3) {
            ForEach(parsed.fields.indices, id: \.self) { i in
                let f = parsed.fields[i]
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(f.label)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(theme.text.opacity(0.5))
                        .frame(width: 76, alignment: .leading)
                    if let href = f.href, let url = URL(string: href) {
                        Link(f.value, destination: url)
                            .font(.system(size: 12))
                            .foregroundStyle(accent)
                            .lineLimit(2)
                    } else {
                        Text(f.value)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.text.opacity(0.85))
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(theme.text.opacity(0.05)))
        if !parsed.description.isEmpty {
            MarkdownBlocksView(text: parsed.description, accent: accent, theme: theme)
        }
    }

    /// Line-oriented parse: code fences accumulate verbatim; every other line maps to one block.
    private func blocks(of source: String, startLine: Int) -> [Block] {
        var out: [Block] = []
        var codeLines: [String]? = nil
        var codeStart = 0
        for (i0, raw) in source.components(separatedBy: "\n").enumerated() {
            let i = i0 + startLine - 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = codeLines {
                    out.append(Block(id: codeStart, kind: .code, text: lines.joined(separator: "\n")))
                    codeLines = nil
                } else {
                    codeLines = []; codeStart = i + 1
                }
                continue
            }
            if codeLines != nil {
                codeLines!.append(raw); continue
            }
            if line.isEmpty {
                continue
            }
            let indent = min(6, raw.prefix(while: { $0 == " " || $0 == "\t" })
                .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2)
            if let (done, rest) = todoLine(line) {
                out.append(Block(id: i + 1, kind: .todo(done: done, tok: TodoIndex.tokenizeLine(rest),
                                                        indent: indent), text: rest))
            } else if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                out.append(Block(id: i + 1, kind: .heading(level),
                                 text: line.drop(while: { $0 == "#" })
                                     .trimmingCharacters(in: .whitespaces)))
            } else if let rest = strip(line, ["- ", "* ", "+ "]) {
                out.append(Block(id: i + 1, kind: .bullet(indent: indent), text: rest))
            } else if let dot = line.firstIndex(of: "."), let n = Int(line[line.startIndex ..< dot]),
                      line.index(after: dot) < line.endIndex, line[line.index(after: dot)] == " " {
                out.append(Block(id: i + 1, kind: .ordered(n, indent: indent),
                                 text: String(line[line.index(dot, offsetBy: 2)...])))
            } else if let rest = strip(line, ["> "]) {
                out.append(Block(id: i + 1, kind: .quote, text: rest))
            } else {
                out.append(Block(id: i + 1, kind: .para, text: line))
            }
        }
        if let lines = codeLines { // unterminated fence — show what's there
            out.append(Block(id: codeStart, kind: .code, text: lines.joined(separator: "\n")))
        }
        return out
    }

    private func todoLine(_ line: String) -> (Bool, String)? {
        for p in ["- [ ] ", "* [ ] ", "+ [ ] "] where line.hasPrefix(p) {
            return (false, String(line.dropFirst(p.count)))
        }
        for p in ["- [x] ", "- [X] ", "* [x] ", "* [X] ", "+ [x] ", "+ [X] "] where line.hasPrefix(p) {
            return (true, String(line.dropFirst(p.count)))
        }
        return nil
    }

    private func strip(_ line: String, _ prefixes: [String]) -> String? {
        for p in prefixes where line.hasPrefix(p) {
            return String(line.dropFirst(p.count))
        }
        return nil
    }

    /// Inline spans through Foundation's markdown parser: [links](…) (tappable), **bold**,
    /// *italic*, `code`.
    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }

    // ── Rendering ────────────────────────────────────────────────────────────────────────────

    @ViewBuilder private func blockView(_ b: Block) -> some View {
        switch b.kind {
        case let .heading(level):
            Text(inline(b.text))
                .font(level <= 1 ? .title3.weight(.semibold)
                    : level == 2 ? .headline
                    : .subheadline.weight(.semibold))
                .padding(.top, 4)
        case let .todo(done, tok, indent):
            todoRow(b, done: done, tok: tok, indent: indent)
        case let .bullet(indent):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").font(.callout).foregroundStyle(.secondary)
                Text(inline(b.text)).font(.callout)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case let .ordered(n, indent):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(n).").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Text(inline(b.text)).font(.callout)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .quote:
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(accent.opacity(0.6))
                    .frame(width: 3)
                Text(inline(b.text)).font(.callout).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code:
            Text(verbatim: b.text)
                .font(.system(.caption, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.text.opacity(0.06)))
        case .para:
            Text(inline(b.text)).font(.callout)
        }
    }

    /// A todo row: checkbox glyph (tappable when onToggle is wired), the token-stripped text,
    /// then the token CHIPS — priority bangs, due, #tags, @people — the badge rendering the web
    /// preview got from remarkTodoTokens.
    private func todoRow(_ b: Block, done: Bool, tok: TodoLineTokens, indent: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            DashCheckbox(checked: done, size: 14,
                         action: onToggle.map { f in { f(b.id) } })
            (todoText(tok, done: done) + chips(tok))
                .font(.callout)
        }
        .padding(.leading, CGFloat(indent) * 14)
    }

    private func todoText(_ tok: TodoLineTokens, done: Bool) -> Text {
        Text(inline(tok.text))
            .strikethrough(done, color: .secondary)
            .foregroundStyle(done ? Color.secondary : Color.primary)
    }

    private func chips(_ tok: TodoLineTokens) -> Text {
        var t = Text(verbatim: "")
        if let p = tok.priority {
            t = t + Text(verbatim: "  \(String(repeating: "!", count: p))")
                .font(.caption.weight(.bold)).foregroundStyle(accent)
        }
        if let due = tok.due {
            t = t + Text(verbatim: "  due:\(due)").font(.caption).foregroundStyle(.secondary)
        }
        if let f = tok.followup {
            t = t + Text(verbatim: "  ↪\(f)").font(.caption).foregroundStyle(.secondary)
        }
        for tag in tok.tags {
            t = t + Text(verbatim: "  #\(tag)").font(.caption).foregroundStyle(.secondary)
        }
        for person in tok.entities["person"] ?? [] {
            t = t + Text(verbatim: "  @\(person)").font(.caption).foregroundStyle(.secondary)
        }
        return t
    }
}
