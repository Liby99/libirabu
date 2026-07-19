// Canvas fast path for PLAIN stickers (Performance Mode, year/month zoom).
//
// The flamegraph (docs: bench/results.log + the month-swipe profiling session) showed ~66% of
// main-thread frame time in SwiftUI's view-graph re-layout of the sticker views — ForEach list
// maintenance + per-sticker layout chains — while the Canvas passes cost ~0.5ms/frame. At year/
// month zoom EVERY visible event is a sticker (hundreds), and a PLAIN sticker's flat rendering is
// tiny: an (uneven-)rounded fill + a 1pt accent bar + optional badge glyphs + (bands only) a title.
// So plain stickers are drawn here, in one Canvas, and only ACTIVE stickers (hover/selected/
// accompanied/editing) remain real SwiftUI views — they keep glass, borders, spill scrims, and
// activation animations. Week/day zoom keeps the full view path (rich multi-line text, few boxes).
//
// Pixel parity: every constant below is read from BandStyle / EventActivation / Theme — the same
// sources the view stickers use — so the flat rendering matches the SwiftUI output. The one known
// difference: a plain→hover transition swaps Canvas→view instantly, so the 0.18s tint fade-in
// starts from the flat fill rather than cross-fading (invisible in Performance Mode, where idle
// and hover fills differ only by 0.05 tint).

import CalendarGeometry
import SwiftUI

/// Flat-rendering payload for a plain BAND sticker (mirrors BandSticker's Performance-Mode path).
struct BandDraw {
    let ev: BandEvent
    let gap: CGFloat? // px to the nearest later-starting bar — title clips before it (nil = unbounded)
    let clipBox: Bool // shorter same-start bar on top → title clips to its own box
    let clipStart: Bool // continues off-screen left → square left corners, no accent bar
    let clipEnd: Bool // continues off-screen right → square right corners
    let warn: Bool // fully-overlapping-events marker
    let badges: EventBadges
}

/// Flat-rendering payload for a plain TIMED sticker at month zoom (showText=false: no title/time —
/// mirrors EventSticker's month-view rendering: fill + accent bar + in-flow badge row).
struct TimedDraw {
    let ev: TimedEvent
    let clipTop: Bool // cross-midnight: continues from the previous day
    let clipBottom: Bool // …into the next day
    let badges: EventBadges
}

enum StickerDraw { case band(BandDraw), timed(TimedDraw) }

/// One Canvas-drawable sticker: geometry + the flat payload.
struct CanvasSticker {
    let rect: CGRect
    let fade: Double
    let z: Double
    let draw: StickerDraw
}

@MainActor enum StickerCanvas {
    /// Draw a clip-group of stickers in z order (matches the view path's zIndex ordering).
    static func draw(_ items: [CanvasSticker], in ctx: inout GraphicsContext, theme: Theme) {
        for it in items.sorted(by: { $0.z < $1.z }) {
            switch it.draw {
            case let .band(b): drawBand(b, rect: it.rect, fade: it.fade, ctx: &ctx, theme: theme)
            case let .timed(t): drawTimed(t, rect: it.rect, fade: it.fade, ctx: &ctx, theme: theme)
            }
        }
    }

    // ── Band: fill + accent bar + (badges above title, 3px overlapped) + warn triangle ──────────
    private static func drawBand(_ b: BandDraw, rect: CGRect, fade: Double,
                                 ctx: inout GraphicsContext, theme: Theme) {
        guard fade > 0.001, rect.width > 0.5 else { return }
        var layer = ctx
        layer.opacity = fade
        let border = theme.eventBorder(b.ev.color)
        let color = theme.eventColor(b.ev.color)
        let r = BandStyle.cornerRadius
        let leftR: CGFloat = b.clipStart ? 0 : r, rightR: CGFloat = b.clipEnd ? 0 : r
        layer.fill(
            Path(roundedRect: rect, cornerRadii: RectangleCornerRadii(
                topLeading: leftR, bottomLeading: leftR, bottomTrailing: rightR, topTrailing: rightR
            )),
            with: .color(color.opacity(BandStyle.tintIdle * theme.eventTintScale))
        )
        let barWidth = BandStyle.accentWidth // plain is never accentWide
        if !b.clipStart {
            let bar = CGRect(x: rect.minX + BandStyle.accentInset, y: rect.minY + BandStyle.accentInset,
                             width: barWidth, height: max(0, rect.height - 2 * BandStyle.accentInset))
            layer.fill(Path(roundedRect: bar, cornerRadius: barWidth / 2), with: .color(border))
        }
        let lead = b.clipStart ? BandStyle.accentInset + BandStyle.barTextGap
            : BandStyle.accentInset + barWidth + BandStyle.barTextGap
        // Title width limit (plain never expands): own box for a stacked shorter bar, else up to the
        // next later-starting bar, else unbounded overflow — same rules as BandSticker.
        let clipW: CGFloat? = b.clipBox ? max(0, rect.width - lead - BandStyle.titleTrailing)
            : b.gap.map { max(12, $0 - 10) }
        let font = Font.custom(BandStyle.titleFontName, size: BandStyle.titleSize)
        let resolved = resolvedText(b.ev.title, font, 0, theme.text, &layer)
        let tSize = resolved.measure(in: CGSize(width: 4000, height: 200))
        // Badge row (7px glyph row) sits above the title, pulled 3px into it (VStack spacing -3).
        let badgeH: CGFloat = b.badges.isEmpty ? 0 : 8
        let blockH = b.badges.isEmpty ? tSize.height : badgeH - 3 + tSize.height
        let y0 = rect.midY - blockH / 2
        if !b.badges.isEmpty {
            drawBadges(b.badges, at: CGPoint(x: rect.minX + lead, y: y0 + badgeH / 2),
                       color: border, ctx: &layer)
        }
        let titleMidY = y0 + (b.badges.isEmpty ? 0 : badgeH - 3) + tSize.height / 2
        if let clipW {
            // Tail-truncated inside the width limit: the single-line-height rect leaves no room for a
            // wrap, so layout truncates with the ellipsis (default .tail) exactly like the view's
            // truncationMode(.tail).frame(width:).
            layer.draw(Text(b.ev.title).font(font).foregroundStyle(theme.text),
                       in: CGRect(x: rect.minX + lead, y: titleMidY - tSize.height / 2,
                                  width: clipW, height: tSize.height))
        } else {
            layer.draw(resolved, at: CGPoint(x: rect.minX + lead, y: titleMidY), anchor: .leading)
        }
        if b.warn {
            let tri = layer.resolve(Text(Image(systemName: "exclamationmark.triangle.fill"))
                .font(.system(size: 10)).foregroundStyle(.yellow))
            layer.draw(tri, at: CGPoint(x: rect.minX + 2, y: rect.minY + 1), anchor: .topLeading)
        }
    }

    // ── Timed (month zoom, no text): fill + accent bar (dotted when hidden) + badge row ─────────
    private static func drawTimed(_ t: TimedDraw, rect: CGRect, fade: Double,
                                  ctx: inout GraphicsContext, theme: Theme) {
        guard fade > 0.001, rect.width > 0.5 else { return }
        var layer = ctx
        layer.opacity = fade
        // Hidden (revealed hidden import): neutral gray fill/badges; only the dotted bar keeps color.
        let hidden = t.badges.contains(.hidden)
        let barColor = theme.eventBorder(t.ev.color)
        let border = hidden ? theme.textMuted : barColor
        let color = hidden ? theme.text : theme.eventColor(t.ev.color)
        let r = BandStyle.cornerRadius
        let topR: CGFloat = t.clipTop ? 0 : r, botR: CGFloat = t.clipBottom ? 0 : r
        layer.fill(
            Path(roundedRect: rect, cornerRadii: RectangleCornerRadii(
                topLeading: topR, bottomLeading: botR, bottomTrailing: botR, topTrailing: topR
            )),
            with: .color(color.opacity(BandStyle.tintIdle * theme.eventTintScale))
        )
        let barWidth = BandStyle.accentWidth
        let barVInset = min(BandStyle.accentInset, max(0, (rect.height - BandStyle.accentInset * 2) / 2))
        let topIn: CGFloat = t.clipTop ? 0 : barVInset, botIn: CGFloat = t.clipBottom ? 0 : barVInset
        let bar = CGRect(x: rect.minX + BandStyle.accentInset, y: rect.minY + topIn,
                         width: barWidth, height: max(0, rect.height - topIn - botIn))
        if hidden {
            // DottedBar: round dots down the bar's line (dot ⌀ = width, spacing ≈ 2.2×).
            var p = Path()
            p.move(to: CGPoint(x: bar.midX, y: bar.minY + barWidth / 2))
            p.addLine(to: CGPoint(x: bar.midX, y: max(bar.minY + barWidth, bar.maxY - barWidth / 2)))
            layer.stroke(p, with: .color(barColor),
                         style: StrokeStyle(lineWidth: barWidth, lineCap: .round, dash: [0.01, barWidth * 2.2]))
        } else {
            let cap = barWidth / 2
            layer.fill(
                Path(roundedRect: bar, cornerRadii: RectangleCornerRadii(
                    topLeading: t.clipTop ? 0 : cap, bottomLeading: t.clipBottom ? 0 : cap,
                    bottomTrailing: t.clipBottom ? 0 : cap, topTrailing: t.clipTop ? 0 : cap
                )),
                with: .color(barColor)
            )
        }
        if !t.badges.isEmpty {
            // In-flow at the top (the month-view EventSticker layout: leading pad after the bar, 3px top).
            let x = rect.minX + BandStyle.accentInset + barWidth + BandStyle.barTextGap
            drawBadges(t.badges, at: CGPoint(x: x, y: rect.minY + 3 + 4), color: border, ctx: &layer)
        }
    }

    /// The badge glyph row: 6.5pt bold SF Symbols, 2px apart, left-anchored at `at.x`, centered on `at.y`.
    /// Symbols are drawn as image-interpolated Text (Text(Image(…))) — the Canvas-idiomatic way to give
    /// an SF Symbol a font size/weight + foreground color, and it reuses the resolved-text cache.
    private static func drawBadges(_ badges: EventBadges, at: CGPoint, color: Color,
                                   ctx: inout GraphicsContext) {
        var x = at.x
        let font = Font.system(size: 6.5, weight: .bold)
        for sym in badgeSymbols(badges) {
            let t = ctx.resolve(Text(Image(systemName: sym)).font(font).foregroundStyle(color))
            let sz = t.measure(in: CGSize(width: 100, height: 100))
            ctx.draw(t, at: CGPoint(x: x, y: at.y), anchor: .leading)
            x += sz.width + 2
        }
    }
}
