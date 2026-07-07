// Scene (and chrome + events) → GraphicsContext.
//
// Layer order matters, mirroring the web's z-index stack:
//   1. scene items z<5        rows / washes / highlights / today tint (may overflow left)
//   2. gutter mask (z5)       opaque left strip — hides week-view left overflow
//   3. scene items 5..<14     gridlines, month labels, hour labels, now-line, tags
//   4. events                 clipped to the grid area, above the hour gridlines
//   5. track names            gutter track-name labels (above the gutter mask)
//   6. daily dashboard (z14)  opaque right panel — hides the other days in day view
//   7. scene items z>=14       daily now-line / cursor / labels above the dashboard

import SwiftUI
import CalendarGeometry
import CalendarEngine

enum SceneRenderer {
    static func draw(input: SceneInput, events: [TimedEvent], tracks: [String], in ctx: inout GraphicsContext, size: CGSize, theme: Theme) {
        let items = buildScene(input).items.sorted { $0.z < $1.z }

        func drawBand(_ lo: Int, _ hi: Int) {
            for it in items where it.z >= lo && it.z < hi && it.opacity > 0.001 {
                var layer = ctx
                layer.opacity = Double(it.opacity)
                drawItem(it, into: &layer, theme: theme)
            }
        }

        drawBand(Int.min, 5)
        drawGutter(input, &ctx, theme)
        drawBand(5, 14)
        drawEvents(input: input, events: events, in: &ctx, theme: theme)
        drawTrackNames(input, tracks, &ctx, theme)
        drawDashboard(input, &ctx, theme)
        drawBand(14, Int.max)
    }

    // ── Per-item ────────────────────────────────────────────────────────────────
    private static func drawItem(_ it: Item, into ctx: inout GraphicsContext, theme: Theme) {
        switch it.kind {
        case .row: drawRow(it, &ctx, theme)
        case .gridline: drawGridline(it, &ctx, theme)
        case .dim:
            ctx.fill(Path(it.rect), with: .color(theme.dimFill))
            // faint 45° hatch
            var hatch = ctx
            hatch.clip(to: Path(it.rect))
            var p = Path()
            var x = it.x - it.h
            while x < it.x + it.w {
                p.move(to: CGPoint(x: x, y: it.y + it.h)); p.addLine(to: CGPoint(x: x + it.h, y: it.y))
                x += 6
            }
            hatch.stroke(p, with: .color(theme.accentGrey.opacity(0.5)), lineWidth: 0.5)
        case .weekend:
            ctx.fill(Path(it.rect), with: .color(theme.weekendWash))
        case .hl:
            ctx.fill(Path(roundedRect: it.rect, cornerRadius: 3), with: .color(theme.highlight))
        case .today:
            ctx.fill(Path(roundedRect: it.rect, cornerRadius: 3), with: .color(theme.todayTint))
        case .now:
            ctx.fill(Path(it.rect), with: .color(theme.nowLine))
            drawEndDots(it, &ctx, color: theme.nowLine, bg: theme.bg)
        case .cursor:
            ctx.fill(Path(it.rect), with: .color(theme.cursor))
            drawEndDots(it, &ctx, color: theme.cursor, bg: theme.bg)
        case .monthLabel: drawMonthLabel(it, &ctx, theme)
        case .dayLabel: drawDayLabel(it, &ctx, theme)
        case .todayTag:
            drawText(it.text ?? "", it.rect, size: it.fontSize ?? 8, align: it.align, color: theme.nowLine, weight: .bold, tracking: 1.2, into: &ctx)
        case .weekdayTag:
            drawPillText(it.text ?? "", it.rect, size: it.fontSize ?? 9, color: theme.text, theme: theme, into: &ctx)
        case .nowLabel:
            drawStackedLabel(it, cap: "CURRENT TIME", size: 13, color: theme.nowLine, border: theme.nowLine, theme: theme, into: &ctx)
        case .timeTag:
            drawPillText(it.text ?? "", it.rect, size: 11, color: theme.cursor, theme: theme, into: &ctx, border: theme.cursor)
        case .event: break
        }
    }

    // Row: dotted vertical day-cell separators + (inner lanes) a dotted top border.
    // No fill — color comes only from events.
    private static func drawRow(_ it: Item, _ ctx: inout GraphicsContext, _ theme: Theme) {
        let cols = it.cols ?? 31
        if cols > 1 {
            let cw = it.w / CGFloat(cols)
            var p = Path()
            for c in 0...cols {
                let x = it.x + CGFloat(c) * cw
                p.move(to: CGPoint(x: x, y: it.y)); p.addLine(to: CGPoint(x: x, y: it.y + it.h))
            }
            ctx.stroke(p, with: .color(theme.cellGrid), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        }
        if it.inner {
            var p = Path()
            p.move(to: CGPoint(x: it.x, y: it.y)); p.addLine(to: CGPoint(x: it.x + it.w, y: it.y))
            ctx.stroke(p, with: .color(theme.cellGrid), style: StrokeStyle(lineWidth: 1, dash: [1, 2]))
        }
    }

    private static func drawGridline(_ it: Item, _ ctx: inout GraphicsContext, _ theme: Theme) {
        let vertical = it.h >= it.w
        var p = Path()
        if vertical {
            let x = it.x + it.w / 2
            p.move(to: CGPoint(x: x, y: it.y)); p.addLine(to: CGPoint(x: x, y: it.y + it.h))
        } else {
            let y = it.y + it.h / 2
            p.move(to: CGPoint(x: it.x, y: y)); p.addLine(to: CGPoint(x: it.x + it.w, y: y))
        }
        // solid = the strong line color; dashed/dotted = same but patterned (fainter reads via item opacity)
        ctx.stroke(p, with: .color(it.lineStyle == nil ? theme.sep : theme.gridLine), style: strokeStyle(it.lineStyle))
    }

    private static func drawEndDots(_ it: Item, _ ctx: inout GraphicsContext, color: Color, bg: Color) {
        let cy = it.y + it.h / 2
        for cx in [it.x, it.x + it.w] {
            let r: CGFloat = 4
            let dot = Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
            ctx.fill(dot, with: .color(bg))
            ctx.stroke(dot, with: .color(color), lineWidth: 1.5)
        }
    }

    private static func drawDayLabel(_ it: Item, _ ctx: inout GraphicsContext, _ theme: Theme) {
        guard let text = it.text else { return }
        let size = it.fontSize ?? 10
        if it.today {
            let tw = min(it.w, CGFloat(text.count) * size * 0.72 + 12)
            let cap = CGRect(x: it.x + (it.w - tw) / 2, y: it.y + max(0, (it.h - size * 1.5) / 2), width: tw, height: min(it.h, size * 1.5))
            ctx.fill(Path(roundedRect: cap, cornerRadius: cap.height / 2), with: .color(theme.nowLine))
            drawText(text, cap, size: size, align: .center, color: .white, weight: .bold, into: &ctx)
        } else {
            drawText(text, it.rect, size: size, align: it.align, color: theme.textMuted, into: &ctx)
        }
    }

    private static func drawMonthLabel(_ it: Item, _ ctx: inout GraphicsContext, _ theme: Theme) {
        guard let text = it.text else { return }
        // vertical text (writing-mode: vertical-lr → reads top→bottom), lowercase.
        var layer = ctx
        layer.translateBy(x: it.x + it.w / 2, y: it.y + it.h / 2)
        layer.rotate(by: .degrees(90))
        let resolved = layer.resolve(Text(text.lowercased()).font(.system(size: it.fontSize ?? 13, weight: .medium)).tracking(1).foregroundStyle(theme.text))
        layer.draw(resolved, at: .zero, anchor: .center)
        // right dotted border + bottom border of the name cell
        var b = Path()
        b.move(to: CGPoint(x: it.x + it.w, y: it.y)); b.addLine(to: CGPoint(x: it.x + it.w, y: it.y + it.h))
        ctx.stroke(b, with: .color(theme.accentGrey), style: StrokeStyle(lineWidth: 1, dash: [1, 2]))
    }

    // ── Chrome: gutter mask, dashboard mask, track names ─────────────────────────
    private static func drawGutter(_ input: SceneInput, _ ctx: inout GraphicsContext, _ theme: Theme) {
        // opaque left strip that occludes lane/column content sliding under it (week view)
        ctx.fill(Path(CGRect(x: 0, y: 0, width: Layout.labelW, height: input.vp.h)), with: .color(theme.bg))
    }

    private static func drawDashboard(_ input: SceneInput, _ ctx: inout GraphicsContext, _ theme: Theme) {
        let reveal = clamp(input.z - 2, 0, 1)
        if reveal <= 0.001 { return }
        let f = frameFor(input.focus, input)
        // right edge of the chosen day column → left edge of the dashboard
        let dashLeft = max(Layout.labelW, f.x0 + CGFloat(input.daily.dom) * f.dayW)
        if dashLeft >= input.vp.w { return }
        var layer = ctx
        layer.opacity = Double(reveal)
        layer.fill(Path(CGRect(x: dashLeft, y: 0, width: input.vp.w - dashLeft, height: input.vp.h)), with: .color(theme.bg))
        // two thin bars at the band top/bottom, matching the timeline dividers
        let barX = dashLeft + 25
        for y in [Layout.topPad, Layout.topPad + Layout.monthH] {
            var p = Path()
            p.move(to: CGPoint(x: barX, y: y)); p.addLine(to: CGPoint(x: input.vp.w - 18, y: y))
            layer.stroke(p, with: .color(theme.sep.opacity(0.58)), lineWidth: 1)
        }
        // day title
        if let r = resolveDate(input.focus, input.daily.dom) {
            let title = "\(WD3[dayOfWeek(input.year, r.month, r.day)])  \(MONTH_LONG[r.month]) \(r.day)"
            drawText(title, CGRect(x: barX, y: Layout.topPad + 6, width: input.vp.w - barX - 18, height: 26),
                     size: 18, align: .left, color: theme.text, weight: .medium, into: &layer)
        }
    }

    private static func drawTrackNames(_ input: SceneInput, _ tracks: [String], _ ctx: inout GraphicsContext, _ theme: Theme) {
        let left = Layout.mnameW
        let width = Layout.labelW - Layout.mnameW - Layout.rightPad
        for m in 0..<12 {
            let f = frameFor(m, input, anim: input.monthAnim)
            if f.opacity < 0.05 || f.bandY + 4 * f.trackH < -4 || f.bandY > input.vp.h + 4 { continue }
            var layer = ctx
            layer.opacity = Double(f.opacity)
            for i in 0..<4 {
                let y = f.bandY + CGFloat(i) * f.trackH
                if i > 0 {
                    var sep = Path()
                    sep.move(to: CGPoint(x: left, y: y)); sep.addLine(to: CGPoint(x: left + width, y: y))
                    layer.stroke(sep, with: .color(theme.cellGrid), style: StrokeStyle(lineWidth: 1, dash: [1, 2]))
                }
                let name = i < tracks.count ? tracks[i] : ""
                drawText(name, CGRect(x: left + 6, y: y, width: width - 8, height: f.trackH),
                         size: 12, align: .left, color: theme.text, into: &layer, clipToRect: true)
            }
        }
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

    private static func drawPillText(_ s: String, _ rect: CGRect, size: CGFloat, color: Color, theme: Theme, into ctx: inout GraphicsContext, border: Color? = nil) {
        if s.isEmpty { return }
        let resolved = ctx.resolve(Text(s).font(.system(size: size, weight: .semibold)).foregroundStyle(color))
        let m = ctx.resolve(Text(s).font(.system(size: size, weight: .semibold)))
        let ts = m.measure(in: CGSize(width: 200, height: 40))
        let pillW = ts.width + 10, pillH = ts.height + 4
        let px = rect.maxX - pillW  // right-anchored-ish; good enough for tags
        let pill = CGRect(x: max(rect.minX, px), y: rect.midY - pillH / 2, width: pillW, height: pillH)
        ctx.fill(Path(roundedRect: pill, cornerRadius: 5), with: .color(theme.bg.opacity(0.82)))
        if let border { ctx.stroke(Path(roundedRect: pill, cornerRadius: 5), with: .color(border), lineWidth: 1) }
        ctx.draw(resolved, at: CGPoint(x: pill.midX, y: pill.midY), anchor: .center)
    }

    private static func drawStackedLabel(_ it: Item, cap: String, size: CGFloat, color: Color, border: Color, theme: Theme, into ctx: inout GraphicsContext) {
        let rect = it.rect
        ctx.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(theme.bg.opacity(0.82)))
        ctx.stroke(Path(roundedRect: rect, cornerRadius: 5), with: .color(border.opacity(0.6)), lineWidth: 1.5)
        let align = it.align
        drawText(cap, CGRect(x: rect.minX + 4, y: rect.minY + 3, width: rect.width - 8, height: 9), size: 7.5, align: align, color: theme.textMuted, into: &ctx)
        drawText(it.text ?? "", CGRect(x: rect.minX + 4, y: rect.minY + 12, width: rect.width - 8, height: rect.height - 14), size: size, align: align, color: color, weight: .bold, into: &ctx)
    }

    private static func drawText(_ s: String, _ rect: CGRect, size: CGFloat, align: TextAlign, color: Color, weight: Font.Weight = .regular, tracking: CGFloat = 0, into ctx: inout GraphicsContext, clipToRect: Bool = false) {
        if s.isEmpty { return }
        let resolved = ctx.resolve(Text(s).font(.system(size: size, weight: weight)).tracking(tracking).foregroundStyle(color))
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
