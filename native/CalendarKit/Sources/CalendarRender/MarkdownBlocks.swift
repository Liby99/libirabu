// Native, selectable markdown blocks — the shared renderer for note previews (webview retirement
// phase 2; PhoneMarkdown promoted from the iPhone target and extended). Line-oriented blocks —
// headings, todo rows (checkbox glyph + token CHIPS: due/priority/#tag/@person, the
// remarkTodoTokens equivalent), bullet/ordered lists, blockquotes, fenced code, paragraphs —
// with inline spans (links/bold/italic/code) through AttributedString's markdown parser, so
// links are TAPPABLE and every run is SELECTABLE. Grammar sized to actual usage: the real store
// has zero math and zero tables (docs/webview-retirement-design.md §6).

import CalendarEngine
import SwiftUI

/// The house checkbox for todo rows everywhere native (dashboard lists, gantt labels, note
/// previews): a ROUNDED square, stroked grey when open, filled with the ACCENT (red) and a white
/// check when done — matching the webview's styling, not SF Symbols' sharp squares.
public struct DashCheckbox: View {
    let checked: Bool
    let size: CGFloat
    var action: (() -> Void)?

    public init(checked: Bool, size: CGFloat = 15, action: (() -> Void)? = nil) {
        self.checked = checked; self.size = size; self.action = action
    }

    public var body: some View {
        // The webview's .cc-dtodo-check: 15px box, 5px radius, 1.5px accent-grey border;
        // checked = the ACCENT fill with a white check.
        let box = ZStack {
            if checked {
                RoundedRectangle(cornerRadius: size * 0.33)
                    .fill(Theme.accent)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.55, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                RoundedRectangle(cornerRadius: size * 0.33)
                    .strokeBorder(Color.secondary.opacity(0.55), lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: 0.12), value: checked) // fill/border transition
        if let action {
            Button(action: action) { box.contentShape(Rectangle()) }
                .buttonStyle(PressScaleStyle()) // :active scale, like the CSS
        } else {
            box
        }
    }
}

/// The checkbox's press feedback (.cc-dtodo-check:active): a quick 0.9 scale while held.
private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

public struct MarkdownBlocksView: View {
    let text: String
    let accent: Color // checked todos + quote bars pick this up
    let theme: Theme
    var onToggle: ((Int) -> Void)? // 1-based source line of a tapped todo checkbox; nil = read-only

    public init(text: String, accent: Color, theme: Theme, onToggle: ((Int) -> Void)? = nil) {
        self.text = text; self.accent = accent; self.theme = theme; self.onToggle = onToggle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks()) { b in
                blockView(b)
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

    /// Line-oriented parse: code fences accumulate verbatim; every other line maps to one block.
    private func blocks() -> [Block] {
        var out: [Block] = []
        var codeLines: [String]? = nil
        var codeStart = 0
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
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
            if codeLines != nil { codeLines!.append(raw); continue }
            if line.isEmpty { continue }
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
