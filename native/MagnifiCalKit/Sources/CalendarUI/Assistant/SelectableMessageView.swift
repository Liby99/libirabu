// One assistant message's markdown as a single selectable NSTextView, hosted INSIDE the
// SwiftUI bubble (chrome, placement, and animations stay SwiftUI — see ConversationView).
// SwiftUI's textSelection is an island per Text block, so the old per-block stack couldn't
// extend a selection past a paragraph; one text view per message makes the WHOLE message —
// paragraphs, lists, code fences — a single continuous selection. (Selection ACROSS messages
// via a single-document transcript with drawn bubbles was tried 2026-10 and reverted:
// bubble placement/animation fidelity won.)

import AppKit
import SwiftUI

struct SelectableMessageView: NSViewRepresentable {
    let text: String
    let theme: Theme
    /// Sent-bubble mode: plain white body text (no markdown render) and a white selection
    /// wash readable on the accent fill; assistant mode selects in the accent wash.
    var userStyle: Bool = false

    final class Coordinator {
        var renderedKey = "\u{0}"
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MessageTextView {
        let tv = MessageTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        // The LIVE container tracks the view's real frame — sizeThatFits must never touch it
        // (see the scratch measurer below): SwiftUI probes with extreme widths during animated
        // relayout (a chip expanding), and a probe left behind as the container width wrapped
        // every bubble's text into a ~50px column while the bubble kept its ideal frame.
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.linkTextAttributes = [.cursor: NSCursor.pointingHand] // colors are the document's own
        apply(to: tv, context: context)
        return tv
    }

    func updateNSView(_ tv: MessageTextView, context: Context) {
        apply(to: tv, context: context)
    }

    private func apply(to tv: MessageTextView, context: Context) {
        let key = "\(text.count)|\(text.hashValue)|\(theme.dark)|\(userStyle)"
        guard key != context.coordinator.renderedKey else { return }
        context.coordinator.renderedKey = key
        // Selection wash per bubble: accent over the assistant's gray, white over the sent
        // bubble's accent fill (the system blue read wrong on both).
        tv.selectedTextAttributes = [
            .backgroundColor: userStyle
                ? NSColor.white.withAlphaComponent(0.45)
                : NSColor(Theme.accent).withAlphaComponent(0.24),
        ]
        if userStyle {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacing = 2
            tv.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 14.5),
                .foregroundColor: NSColor.white,
                .paragraphStyle: p,
            ]))
            tv.decor = []
            tv.needsDisplay = true
            return
        }
        let doc = MarkdownDoc.render(text, theme: theme, interactive: false)
        // Trim trailing newlines: their empty line fragment pads the measured height and
        // stretches the bubble below the last line.
        let body = NSMutableAttributedString(attributedString: doc.string)
        while body.length > 0, (body.string as NSString).character(at: body.length - 1) == 10 {
            body.deleteCharacters(in: NSRange(location: body.length - 1, length: 1))
        }
        tv.textStorage?.setAttributedString(body)
        tv.decor = doc.decor.filter { $0.range.location + $0.range.length <= body.length }
        let base = NSColor(theme.text)
        tv.codeBG = base.withAlphaComponent(0.07)
        tv.quoteBG = base.withAlphaComponent(0.05)
        tv.quoteBar = NSColor(Theme.accent).withAlphaComponent(0.55)
        tv.ruleColor = NSColor(theme.accentGrey).withAlphaComponent(0.6)
        tv.needsDisplay = true
    }

    /// Self-sizing that HUGS the text like the old Text stack did: lay out at the proposed
    /// width, then answer with the text's actually-used size — a short "Done!" keeps a small
    /// bubble instead of a container-wide one. Measures on a SCRATCH layout stack so layout
    /// probes can never corrupt the live view's wrap width (the live container follows the
    /// frame SwiftUI finally assigns, via widthTracksTextView).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MessageTextView,
                      context _: Context) -> CGSize? {
        guard let w = proposal.width, w > 0, let storage = nsView.textStorage else { return nil }
        let used = Self.measure(storage, width: w)
        return CGSize(width: min(w, ceil(used.width)), height: ceil(used.height))
    }

    // One shared measuring stack (main-actor only, like all layout here).
    private static let scratch: (storage: NSTextStorage, lm: NSLayoutManager, tc: NSTextContainer) = {
        let storage = NSTextStorage()
        let lm = NSLayoutManager()
        let tc = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        storage.addLayoutManager(lm)
        return (storage, lm, tc)
    }()

    private static func measure(_ text: NSAttributedString, width: CGFloat) -> NSRect {
        let s = scratch
        if abs(s.tc.containerSize.width - width) > 0.5 {
            s.tc.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        if !s.storage.isEqual(to: text) {
            s.storage.setAttributedString(text)
        }
        s.lm.ensureLayout(for: s.tc)
        return s.lm.usedRect(for: s.tc)
    }
}

/// Non-editable text view with MarkdownDoc's block decor (code/quote washes, hr lines) —
/// the lean sibling of PreviewTextView's pass; a chat message renders no managed blocks or
/// attachment cards. Links open natively (no delegate needed).
final class MessageTextView: NSTextView {
    var decor: [(range: NSRange, kind: MarkdownDoc.DecorKind)] = []

    /// Triple-click selects the WHOLE message: the bubble is the natural unit here, not the
    /// paragraph (NSTextView's .selectByParagraph default). Double-click word selection and
    /// drag granularities are untouched.
    override func selectionRange(forProposedRange proposedCharRange: NSRange,
                                 granularity: NSSelectionGranularity) -> NSRange {
        if granularity == .selectByParagraph {
            return NSRange(location: 0, length: (string as NSString).length)
        }
        return super.selectionRange(forProposedRange: proposedCharRange, granularity: granularity)
    }
    var codeBG: NSColor = .black.withAlphaComponent(0.055)
    var quoteBG: NSColor = .black.withAlphaComponent(0.035)
    var quoteBar: NSColor = .systemRed
    var ruleColor: NSColor = .separatorColor

    override func draw(_ dirtyRect: NSRect) {
        if let lm = layoutManager, textContainer != nil {
            let origin = textContainerOrigin
            for d in decor {
                let gr = lm.glyphRange(forCharacterRange: d.range, actualCharacterRange: nil)
                guard gr.length > 0 else { continue }
                var union = NSRect.null
                lm.enumerateLineFragments(forGlyphRange: gr) { frag, _, _, _, _ in
                    union = union.union(frag)
                }
                guard !union.isNull else { continue }
                var r = union.offsetBy(dx: origin.x, dy: origin.y)
                switch d.kind {
                case .code:
                    r = NSRect(x: r.minX - 6, y: r.minY - 4,
                               width: min(r.width + 12, bounds.width - r.minX + 4), height: r.height + 8)
                    codeBG.setFill()
                    NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
                case .quote:
                    r = NSRect(x: r.minX - 8, y: r.minY - 4,
                               width: min(r.width + 14, bounds.width - r.minX + 4), height: r.height + 8)
                    quoteBG.setFill()
                    NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
                    quoteBar.setFill()
                    NSRect(x: r.minX, y: r.minY, width: 3, height: r.height).fill()
                case .rule:
                    ruleColor.setFill()
                    NSRect(x: r.minX, y: r.midY - 0.5,
                           width: max(0, bounds.width - r.minX), height: 1).fill()
                case .managed:
                    break
                }
            }
        }
        super.draw(dirtyRect)
    }
}
