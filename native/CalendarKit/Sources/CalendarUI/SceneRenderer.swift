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

enum SceneRenderer {
    // The renderer draws three Canvas passes; the frosted gutter/dashboard masks are
    // SwiftUI material views layered BETWEEN drawMid and drawAbove (see CalendarView).
    //
    //   drawBelow  — everything the masks hide: grid, washes, today, hover, day labels
    //   (events overlay)
    //   drawMid    — deadlines (above events, below masks)
    //   (frosted gutter mask · frosted dashboard mask)
    //   drawAbove  — chrome that sits ON the masks: gutter labels/borders, track names,
    //                now-line/cursor, dashboard title + bars

    // now-line / mouse cursor + their labels — drawn in the top pass, above everything.
    private static func isForeground(_ k: ItemKind) -> Bool {
        switch k { case .now, .nowLabel, .cursor, .timeTag: return true; default: return false }
    }

    // Two disjoint regions. Content items clip to the content rect; gutter items
    // (it.gutter) clip to the gutter rect — so neither can be drawn over the other,
    // and no occlusion/background is needed.
    private static func contentRect(_ input: SceneInput) -> CGRect {
        let right = input.z > 2 ? dashboardLeft(input) : input.vp.w
        return CGRect(x: Layout.labelW, y: 0, width: max(0, right - Layout.labelW), height: input.vp.h)
    }
    private static func gutterRect(_ input: SceneInput) -> CGRect {
        // Extends left over the padding so the gutter hover can reach the window edge.
        CGRect(x: -Layout.padLeft, y: 0, width: Layout.labelW + Layout.padLeft, height: input.vp.h)
    }

    /// Below the events: content-region scene items (grid, washes, today, grid hover,
    /// day labels), clipped to the content area.
    static func drawBelow(input: SceneInput, in ctx: inout GraphicsContext, theme: Theme) {
        var clipped = ctx; clipped.clip(to: Path(contentRect(input)))
        for it in buildScene(input).items.sorted(by: { $0.z < $1.z })
        where it.opacity > 0.001 && !it.gutter && !isForeground(it.kind) {
            var layer = clipped; layer.opacity = Double(it.opacity); drawItem(it, into: &layer, theme: theme)
        }
    }

    /// Above the events, below the chrome: deadlines (self-clip to the content area).
    static func drawMid(input: SceneInput, deadlines: [Deadline], selected: String?, in ctx: inout GraphicsContext, theme: Theme) {
        drawDeadlines(input, deadlines, selected, &ctx, theme)
    }

    /// Chrome, each clipped to its own region so it can't collide with content:
    /// gutter items + track names (gutter region), now-line/cursor (content region),
    /// then the dashboard title.
    static func drawAbove(input: SceneInput, tracks: [[String]], in ctx: inout GraphicsContext, theme: Theme) {
        let items = buildScene(input).items.sorted { $0.z < $1.z }
        // gutter region: month name, hour labels, gutter borders, gutter hover + tracks
        var gut = ctx; gut.clip(to: Path(gutterRect(input)))
        for it in items where it.gutter && it.opacity > 0.001 {
            var layer = gut; layer.opacity = Double(it.opacity); drawItem(it, into: &layer, theme: theme)
        }
        drawTrackNames(input, tracks, &gut, theme)
        // content region: now-line + mouse cursor
        var content = ctx; content.clip(to: Path(contentRect(input)))
        for it in items where isForeground(it.kind) && it.opacity > 0.001 {
            var layer = content; layer.opacity = Double(it.opacity); drawItem(it, into: &layer, theme: theme)
        }
        drawDashboardChrome(input, &ctx, theme)
        drawYearPull(input, &ctx, theme)
        drawScrollDebug(input, &ctx, theme)
    }

    // DEBUG: visualize the year-scroll boundaries + flip threshold. Toggle with debugScroll.
    static var debugScroll = false
    private static func drawScrollDebug(_ input: SceneInput, _ ctx: inout GraphicsContext, _ theme: Theme) {
        guard debugScroll, input.z < 0.5 else { return }
        let vp = input.vp
        let maxY = yearMaxScroll(vp)
        let thr = Layout.yearFlipOver
        func hline(_ y: CGFloat, _ color: Color, dash: Bool = false, w: CGFloat = 1) {
            var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: vp.w, y: y))
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: w, dash: dash ? [5, 4] : []))
        }
        // rest boundaries (blue), flip thresholds (red dashed), live content edges (green)
        hline(Layout.yearTop, .blue)
        hline(Layout.yearTop + thr, .red, dash: true)
        hline(vp.h - Layout.bottomPad, .blue)
        hline(vp.h - Layout.bottomPad - thr, .red, dash: true)
        hline(Layout.yearTop - input.scrollY, .green, w: 2)                    // content top
        hline(Layout.yearTop - input.scrollY + yearContentH(), .green, w: 2)   // content bottom
        let over = input.scrollY < 0 ? -input.scrollY : max(0, input.scrollY - maxY)
        let hud = String(format: "scrollY %.0f   max %.0f   over %.0f   thr %.0f   armed %@",
                         input.scrollY, maxY, over, thr, (input.yearPull?.armed ?? false) ? "YES" : "no")
        drawText(hud, CGRect(x: Layout.labelW + 8, y: 3, width: 520, height: 16),
                 size: 11, align: .left, color: .green, into: &ctx)
    }

    // Pull-to-change-year hint shown in the overscroll gap (year view). The target year
    // with a caption that flips to "Release to switch" once past the flip threshold.
    private static func drawYearPull(_ input: SceneInput, _ ctx: inout GraphicsContext, _ theme: Theme) {
        guard input.z < 0.5, let p = input.yearPull, p.over > 4 else { return }
        let reveal = min(1, p.over / 40)
        // Center on the whole window, not the content area: geometry x=0 sits padLeft
        // from the window's left edge, so the window center is (vp.w - padLeft)/2.
        let cx = (input.vp.w - Layout.padLeft) / 2
        // Hug the content edge you're pulling (top of Jan / bottom of Dec) rather than
        // floating up by the window edge — clamped so it's always fully on-screen.
        let contentTop = Layout.yearTop - input.scrollY
        let contentBottom = contentTop + yearContentH()
        let cy = p.atTop ? max(21, contentTop - 24) : min(input.vp.h - 21, contentBottom + 24)
        var layer = ctx
        layer.opacity = Double(reveal)
        drawText("\(p.targetYear)", CGRect(x: cx - 100, y: cy - 17, width: 200, height: 22),
                 size: 18, align: .center, color: theme.text, weight: .semibold, into: &layer)
        let cap = p.armed ? "Release to switch" : (p.atTop ? "Previous year" : "Next year")
        drawText(cap, CGRect(x: cx - 120, y: cy + 5, width: 240, height: 14),
                 size: 10, align: .center, color: p.armed ? theme.nowLine : theme.text.opacity(0.55),
                 weight: p.armed ? .semibold : .regular, into: &layer)
    }

    // Deadlines: a colored horizontal rule across the day column at the deadline's
    // hour, with end dots + a title/time pill. Clipped to the visible day area.
    private static func drawDeadlines(_ input: SceneInput, _ deadlines: [Deadline], _ selected: String?, _ ctx: inout GraphicsContext, _ theme: Theme) {
        let tl = timelineInfo(input)
        guard tl.reveal > 0.05, tl.hourH > 0 else { return }
        let f = frameFor(input.focus, input)
        let clipRight = input.z > 2 ? f.x0 + CGFloat(input.daily.dom) * f.dayW : input.vp.w
        var clip = ctx
        clip.clip(to: Path(CGRect(x: Layout.labelW, y: tl.tlTop, width: max(0, clipRight - Layout.labelW), height: tl.tlBottom - tl.tlTop)))
        for d in deadlines {
            guard let pos = deadlinePos(d, input) else { continue }
            let fade = dailyFade(relDomOf(input.year, input.focus, d.month, d.day) ?? -999, input) * tl.reveal
            if fade <= 0.02 { continue }
            var layer = clip
            layer.opacity = Double(fade)
            let color = theme.eventBorder(d.color)
            let sel = d.id == selected
            var line = Path()
            line.move(to: CGPoint(x: pos.x, y: pos.y)); line.addLine(to: CGPoint(x: pos.x + pos.w, y: pos.y))
            layer.stroke(line, with: .color(color), lineWidth: sel ? 2.5 : 1.5)
            for cx in [pos.x, pos.x + pos.w] {
                let dot = Path(ellipseIn: CGRect(x: cx - 3, y: pos.y - 3, width: 6, height: 6))
                layer.fill(dot, with: .color(theme.bg)); layer.stroke(dot, with: .color(color), lineWidth: 1.5)
            }
            let t = Int((d.hour * 60).rounded())
            let label = "\(d.title)  \(String(format: "%02d:%02d", (t / 60) % 24, t % 60))"
            let resolved = layer.resolve(Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(color))
            let sz = resolved.measure(in: CGSize(width: 240, height: 20))
            let pill = CGRect(x: pos.x + 4, y: pos.y - 17, width: min(sz.width + 10, pos.w - 6), height: 15)
            if pill.width > 12 {
                layer.fill(Path(roundedRect: pill, cornerRadius: 4), with: .color(theme.bg.opacity(0.85)))
                layer.stroke(Path(roundedRect: pill, cornerRadius: 4), with: .color(color.opacity(0.7)), lineWidth: 1)
                var textLayer = layer
                textLayer.clip(to: Path(pill))
                textLayer.draw(resolved, at: CGPoint(x: pill.minX + 5, y: pill.midY), anchor: .leading)
            }
        }
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
        ctx.stroke(p, with: .color(it.lineStyle == nil ? theme.sep : theme.gridLine), style: strokeStyle(it.lineStyle, width: it.lineW))
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

    // ── Chrome: dashboard title + bars, track names ───────────────────────────────
    // (The gutter + dashboard masks themselves are frosted SwiftUI material views.)
    private static func drawDashboardChrome(_ input: SceneInput, _ ctx: inout GraphicsContext, _ theme: Theme) {
        let reveal = clamp(input.z - 2, 0, 1)
        if reveal <= 0.001 { return }
        let dashLeft = dashboardLeft(input)
        if dashLeft >= input.vp.w { return }
        var layer = ctx
        layer.opacity = Double(reveal)
        // two thin bars at the band top/bottom, matching the timeline dividers
        let barX = dashLeft + 25
        for y in [Layout.topPad, Layout.topPad + Layout.monthH] {
            var p = Path()
            p.move(to: CGPoint(x: barX, y: y)); p.addLine(to: CGPoint(x: input.vp.w - 18, y: y))
            layer.stroke(p, with: .color(theme.sep.opacity(0.58)), lineWidth: 1)
        }
        // day title — bottom-aligned in the band region, just above the lower bar
        // (matches .cc-dd-titlezone { align-items: flex-end }).
        if let r = resolveDate(input.year, input.focus, input.daily.dom) {
            let lowerBarY = Layout.topPad + Layout.monthH
            let w = input.vp.w - barX - 18
            let name = WD3[dayOfWeek(input.year, r.month, r.day)].uppercased()
            drawText(name, CGRect(x: barX, y: lowerBarY - 46, width: w, height: 14),
                     size: 11, align: .left, color: theme.textMuted, tracking: 1, into: &layer)
            drawText("\(MONTH_LONG[r.month]) \(r.day)", CGRect(x: barX, y: lowerBarY - 33, width: w, height: 26),
                     size: 19, align: .left, color: theme.text, weight: .medium, into: &layer)
        }
    }

    private static func drawTrackNames(_ input: SceneInput, _ tracks: [[String]], _ ctx: inout GraphicsContext, _ theme: Theme) {
        let left = Layout.mnameW
        let width = Layout.labelW - Layout.mnameW - Layout.rightPad
        for m in 0..<12 {
            let f = frameFor(m, input, anim: input.monthAnim)
            if f.opacity < 0.05 || f.bandY + 4 * f.trackH < -4 || f.bandY > input.vp.h + 4 { continue }
            let names = m < tracks.count ? tracks[m] : []
            var layer = ctx
            layer.opacity = Double(f.opacity)
            for i in 0..<4 {
                let y = f.bandY + CGFloat(i) * f.trackH
                if i > 0 {
                    var sep = Path()
                    sep.move(to: CGPoint(x: left, y: y)); sep.addLine(to: CGPoint(x: left + width, y: y))
                    layer.stroke(sep, with: .color(theme.cellGrid), style: StrokeStyle(lineWidth: 1, dash: [1, 2]))
                }
                let name = i < names.count ? names[i] : ""
                // Match the event-name font (Comic Sans MS 13) for a consistent look.
                drawText(name, CGRect(x: left + 6, y: y, width: width - 8, height: f.trackH),
                         size: 13, align: .left, color: theme.text, font: .custom("Comic Sans MS", size: 13),
                         into: &layer, clipToRect: true)
            }
            // solid bottom border across the gutter (month-name cell + track cells) —
            // the grid's month divider doesn't extend into the gutter. Internal borders
            // match the quarter top (0.6, 1×); the quarter's bottom month is emphasized
            // (1.0, 1.5×), matching its grid msep.
            let quarterBottom = m % 3 == 2
            var bottom = Path()
            let by = f.bandY + 4 * f.trackH
            bottom.move(to: CGPoint(x: 0, y: by)); bottom.addLine(to: CGPoint(x: Layout.labelW - Layout.rightPad, y: by))
            layer.stroke(bottom, with: .color(theme.sep.opacity(quarterBottom ? 1.0 : 0.6)), lineWidth: quarterBottom ? 1.5 : 1)
        }
    }

    // ── Text + stroke helpers ──────────────────────────────────────────────────────
    private static func strokeStyle(_ s: LineStyle?, width: CGFloat = 1) -> StrokeStyle {
        switch s {
        case .dashed: return StrokeStyle(lineWidth: width, dash: [4, 3])
        case .dotted: return StrokeStyle(lineWidth: width, dash: [1, 3])
        case .none: return StrokeStyle(lineWidth: width)
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

    private static func drawText(_ s: String, _ rect: CGRect, size: CGFloat, align: TextAlign, color: Color, weight: Font.Weight = .regular, tracking: CGFloat = 0, font: Font? = nil, into ctx: inout GraphicsContext, clipToRect: Bool = false) {
        if s.isEmpty { return }
        let f = font ?? .system(size: size, weight: weight)
        let resolved = ctx.resolve(Text(s).font(f).tracking(tracking).foregroundStyle(color))
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
