// Scene (and event bodies) → GraphicsContext. Immediate-mode drawing of the flat
// Item list produced by CalendarGeometry.buildScene, plus timed events on top.

import SwiftUI
import CalendarGeometry
import CalendarEngine

enum SceneRenderer {
    static func draw(input: SceneInput, events: [TimedEvent], in ctx: inout GraphicsContext, size: CGSize, theme: Theme) {
        let scene = buildScene(input)
        let items = scene.items.sorted { $0.z < $1.z }
        for it in items where it.opacity > 0.001 {
            var layer = ctx
            layer.opacity = Double(it.opacity)
            drawItem(it, into: &layer, vp: input.vp, theme: theme)
        }
        drawEvents(input: input, events: events, in: &ctx, theme: theme)
    }

    private static func drawItem(_ it: Item, into ctx: inout GraphicsContext, vp: Viewport, theme: Theme) {
        switch it.kind {
        case .row:
            ctx.fill(Path(it.rect), with: .color(theme.rowTint(it.color)))
            if let cols = it.cols, cols > 1 {
                let cw = it.w / CGFloat(cols)
                var p = Path()
                for c in 1..<cols {
                    let x = it.x + CGFloat(c) * cw
                    p.move(to: CGPoint(x: x, y: it.y)); p.addLine(to: CGPoint(x: x, y: it.y + it.h))
                }
                ctx.stroke(p, with: .color(theme.gridLine.opacity(0.5)), style: StrokeStyle(lineWidth: 0.5, dash: [1, 3]))
            }
            if it.inner {
                var p = Path()
                p.move(to: CGPoint(x: it.x, y: it.y)); p.addLine(to: CGPoint(x: it.x + it.w, y: it.y))
                ctx.stroke(p, with: .color(theme.gridLine.opacity(0.4)), style: StrokeStyle(lineWidth: 0.5, dash: [1, 3]))
            }
        case .gridline:
            var p = Path()
            if it.w >= it.h { // horizontal
                let y = it.y + it.h / 2
                p.move(to: CGPoint(x: it.x, y: y)); p.addLine(to: CGPoint(x: it.x + it.w, y: y))
            } else {          // vertical
                let x = it.x + it.w / 2
                p.move(to: CGPoint(x: x, y: it.y)); p.addLine(to: CGPoint(x: x, y: it.y + it.h))
            }
            ctx.stroke(p, with: .color(theme.gridLine), style: strokeStyle(it.lineStyle))
        case .dim:
            ctx.fill(Path(it.rect), with: .color(theme.dimFill))
        case .weekend:
            ctx.fill(Path(it.rect), with: .color(theme.weekendWash))
        case .hl:
            ctx.fill(Path(it.rect), with: .color(theme.highlight))
        case .today:
            ctx.fill(Path(it.rect), with: .color(theme.todayTint))
        case .now:
            ctx.fill(Path(it.rect), with: .color(theme.nowLine))
        case .cursor:
            ctx.fill(Path(it.rect), with: .color(theme.cursor))
        case .monthLabel:
            drawRotatedLabel(it, into: &ctx, theme: theme)
        case .dayLabel:
            drawDayLabel(it, into: &ctx, theme: theme)
        case .todayTag:
            drawText(it.text ?? "", it.rect, size: it.fontSize ?? 8, align: it.align, color: theme.nowLine, weight: .semibold, into: &ctx)
        case .weekdayTag:
            drawText(it.text ?? "", it.rect, size: it.fontSize ?? 9, align: it.align, color: theme.textMuted, weight: .medium, into: &ctx)
        case .nowLabel:
            drawText(it.text ?? "", it.rect, size: 11, align: it.align, color: theme.nowLine, weight: .semibold, into: &ctx)
        case .timeTag:
            drawText(it.text ?? "", it.rect, size: 11, align: it.align, color: theme.cursor, weight: .semibold, into: &ctx)
        case .event:
            break
        }
    }

    private static func drawDayLabel(_ it: Item, into ctx: inout GraphicsContext, theme: Theme) {
        guard let text = it.text else { return }
        let size = it.fontSize ?? 10
        if it.today {
            // red capsule + white text (approx the web's today capsule)
            let tw = min(it.w, CGFloat(text.count) * size * 0.7 + 12)
            let cap = CGRect(x: it.x + (it.w - tw) / 2, y: it.y, width: tw, height: it.h)
            ctx.fill(Path(roundedRect: cap, cornerRadius: it.h / 2), with: .color(theme.nowLine))
            drawText(text, cap, size: size, align: .center, color: .white, weight: .semibold, into: &ctx)
        } else {
            drawText(text, it.rect, size: size, align: it.align, color: theme.textMuted, into: &ctx)
        }
    }

    private static func drawRotatedLabel(_ it: Item, into ctx: inout GraphicsContext, theme: Theme) {
        guard let text = it.text else { return }
        var layer = ctx
        layer.translateBy(x: it.x + it.w / 2, y: it.y + it.h / 2)
        layer.rotate(by: .degrees(-90))
        let resolved = layer.resolve(Text(text).font(.system(size: it.fontSize ?? 13, weight: .semibold)).foregroundStyle(theme.text))
        layer.draw(resolved, at: .zero, anchor: .center)
    }

    // ── Events ────────────────────────────────────────────────────────────────────
    private static func drawEvents(input: SceneInput, events: [TimedEvent], in ctx: inout GraphicsContext, theme: Theme) {
        let tl = timelineInfo(input)
        guard tl.reveal > 0.05, tl.hourH > 0 else { return }
        var byDay: [Int: [TimedEvent]] = [:]
        for e in events {
            if let rd = relDomOf(input.focus, e.month, e.day) { byDay[rd, default: []].append(e) }
        }
        var clip = ctx
        clip.clip(to: Path(CGRect(x: Layout.labelW, y: tl.tlTop, width: input.vp.w - Layout.labelW, height: tl.tlBottom - tl.tlTop)))
        for (rd, evs) in byDay {
            let fade = dailyFade(rd, input) * tl.reveal
            if fade <= 0.02 { continue }
            let layout = layoutDay(evs)
            for e in evs {
                guard let r = eventRect(e, input.focus, tl, input.vp, layout[e.id]) else { continue }
                let rect = CGRect(x: r.minX, y: tl.tlTop - tl.scroll + r.minY, width: r.width, height: r.height)
                if rect.maxY < tl.tlTop || rect.minY > tl.tlBottom { continue }
                var layer = clip
                layer.opacity = Double(fade)
                layer.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(theme.eventFill(e.color)))
                if rect.height > 14 {
                    drawText(e.title, rect.insetBy(dx: 5, dy: 3), size: 10, align: .left, color: theme.eventText, weight: .medium, into: &layer, clipToRect: true)
                }
            }
        }
    }

    // ── Text + stroke helpers ──────────────────────────────────────────────────────
    private static func strokeStyle(_ s: LineStyle?) -> StrokeStyle {
        switch s {
        case .dashed: return StrokeStyle(lineWidth: 1, dash: [4, 3])
        case .dotted: return StrokeStyle(lineWidth: 1, dash: [1, 3])
        case .none: return StrokeStyle(lineWidth: 1)
        }
    }

    private static func drawText(_ s: String, _ rect: CGRect, size: CGFloat, align: TextAlign, color: Color, weight: Font.Weight = .regular, into ctx: inout GraphicsContext, clipToRect: Bool = false) {
        if s.isEmpty { return }
        let resolved = ctx.resolve(Text(s).font(.system(size: size, weight: weight)).foregroundStyle(color))
        let pt: CGPoint
        let anchor: UnitPoint
        switch align {
        case .center: pt = CGPoint(x: rect.midX, y: rect.midY); anchor = .center
        case .left: pt = CGPoint(x: rect.minX, y: rect.midY); anchor = .leading
        case .right: pt = CGPoint(x: rect.maxX, y: rect.midY); anchor = .trailing
        }
        if clipToRect {
            var layer = ctx
            layer.clip(to: Path(rect))
            layer.draw(resolved, at: pt, anchor: anchor)
        } else {
            ctx.draw(resolved, at: pt, anchor: anchor)
        }
    }
}
