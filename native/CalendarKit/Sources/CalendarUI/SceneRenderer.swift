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
        return CGRect(x: Layout.labelW, y: 0, width: max(0, dashboardLeftAnimated(input) - Layout.labelW), height: input.vp.h)
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
    static func drawMid(input: SceneInput, deadlines: [Deadline], selected: String?, drawerOpen: Bool = false, hovered: String? = nil, only: String? = nil, hide: String? = nil, in ctx: inout GraphicsContext, theme: Theme) {
        drawDeadlines(input, deadlines, selected, drawerOpen, hovered, only, hide, &ctx, theme)
    }

    /// Chrome, each clipped to its own region so it can't collide with content:
    /// gutter items + track names (gutter region), now-line/cursor (content region),
    /// then the dashboard title.
    static func drawAbove(input: SceneInput, tracks: [[String]], hideTrack: (Int, Int)? = nil, in ctx: inout GraphicsContext, theme: Theme) {
        let items = buildScene(input).items.sorted { $0.z < $1.z }
        // gutter region: month name, hour labels, gutter borders, gutter hover + tracks
        var gut = ctx; gut.clip(to: Path(gutterRect(input)))
        for it in items where it.gutter && it.opacity > 0.001 {
            var layer = gut; layer.opacity = Double(it.opacity); drawItem(it, into: &layer, theme: theme)
        }
        drawTrackNames(input, tracks, hideTrack, &gut, theme)
        // content region: now-line + mouse cursor. Widen a few px past the content edges so the
        // end-dots (r=4), centered exactly on the left/right boundaries, draw whole instead of halved.
        // (The cursor time tag is NOT here — it's a SwiftUI overlay, so it isn't clipped at the gutter.)
        var content = ctx; content.clip(to: Path(contentRect(input).insetBy(dx: -6, dy: 0)))
        for it in items where isForeground(it.kind) && it.opacity > 0.001 {
            var layer = content; layer.opacity = Double(it.opacity); drawItem(it, into: &layer, theme: theme)
        }
        drawDashboardChrome(input, &ctx, theme)
        drawYearPull(input, &ctx, theme)
        drawMonthPull(input, &ctx, theme)
        drawWeekPull(input, &ctx, theme)
        drawDayPull(input, &ctx, theme)
        drawScrollDebug(input, &ctx, theme)
    }

    // Pull-to-flip-month hint (week view, at a month edge). Hugs the pulled left/right edge and
    // names the neighbor month + how the flip resolves: an ALIGNED boundary (the boundary week is
    // wholly this month) advances to a fresh "prev/next month"; a SHARED boundary week (already
    // shows the neighbor's spillover, dimmed) merely "reveal"s it (brightens). Always full month name.
    private static func drawWeekPull(_ input: SceneInput, _ ctx: inout GraphicsContext, _ theme: Theme) {
        guard input.z >= 1.5, input.z < 2.5, let p = input.weekPull, p.over > 4 else { return }
        let reveal = min(1, p.over / 40)
        // A vertical (90°-rotated) label that slides IN from the pulled edge as the rubber-band grows,
        // hugging the gap the overscroll opens — right edge for a next-month pull, left for previous.
        let edgeX = p.dir > 0 ? input.vp.w - Layout.padLeft : Layout.labelW
        let depth: CGFloat = 20                            // resting distance in from the edge
        let slide = lerp(depth - 12, depth, reveal)        // peeks, then slides inward with the pull
        let cx = p.dir > 0 ? edgeX - slide : edgeX + slide
        let tl = timelineInfo(input)                       // center on the daily timeline band, not the whole window
        let cy = (tl.tlTop + tl.tlBottom) * 0.5
        var layer = ctx
        layer.opacity = Double(reveal)
        layer.translateBy(x: cx, y: cy)
        layer.rotate(by: .degrees(p.dir > 0 ? 90 : -90))   // reads top→bottom (right) / bottom→top (left)
        // Local frame after the rotate: local-x runs ALONG the edge, local-y is depth. Stack the two
        // lines across the depth axis, centered on the edge.
        drawText(MONTH_LONG[p.targetMonth], CGRect(x: -130, y: -16, width: 260, height: 20),
                 size: 17, align: .center, color: theme.text, weight: .semibold, into: &layer)
        let cap = p.shared ? "reveal" : (p.dir < 0 ? "prev month" : "next month")
        drawText(cap, CGRect(x: -130, y: 5, width: 260, height: 13),
                 size: 10, align: .center, color: p.armed ? theme.nowLine : theme.text.opacity(0.6),
                 weight: p.armed ? .semibold : .regular, into: &layer)
    }

    // Pull-to-flip-month hint (day view, at a month edge): names the neighbor month + "prev/next
    // month". Mirrors drawWeekPull, hugging the pulled edge of the single day column (its left edge /
    // the dashboard boundary on the right).
    private static func drawDayPull(_ input: SceneInput, _ ctx: inout GraphicsContext, _ theme: Theme) {
        guard input.z >= 2.5, let p = input.dayPull, p.over > 4 else { return }
        let reveal = min(1, p.over / 40)
        let edgeX = p.dir > 0 ? dashboardLeft(input) : Layout.labelW
        let depth: CGFloat = 20
        let slide = lerp(depth - 12, depth, reveal)
        let cx = p.dir > 0 ? edgeX - slide : edgeX + slide
        let tl = timelineInfo(input)
        let cy = (tl.tlTop + tl.tlBottom) * 0.5
        var layer = ctx
        layer.opacity = Double(reveal)
        layer.translateBy(x: cx, y: cy)
        layer.rotate(by: .degrees(p.dir > 0 ? 90 : -90))
        drawText(MONTH_LONG[p.targetMonth], CGRect(x: -130, y: -16, width: 260, height: 20),
                 size: 17, align: .center, color: theme.text, weight: .semibold, into: &layer)
        drawText(p.dir < 0 ? "prev month" : "next month", CGRect(x: -130, y: 5, width: 260, height: 13),
                 size: 10, align: .center, color: p.armed ? theme.nowLine : theme.text.opacity(0.6),
                 weight: p.armed ? .semibold : .regular, into: &layer)
    }

    // Pull-to-flip-month hint (month view, at the Jan/Dec boundary): the target month + year,
    // captioned "Release to switch" once past the flip threshold. Hugs the top/bottom edge.
    private static func drawMonthPull(_ input: SceneInput, _ ctx: inout GraphicsContext, _ theme: Theme) {
        guard input.z >= 0.5, input.z < 1.5, let p = input.monthPull, p.over > 4 else { return }
        let reveal = min(1, p.over / 40)
        let cx = (input.vp.w - Layout.padLeft) / 2
        let cy = p.atTop ? max(21, Layout.topPad - 30) : min(input.vp.h - 21, input.vp.h - 34)
        var layer = ctx
        layer.opacity = Double(reveal)
        let mName = p.atTop ? MONTH_LONG[11] : MONTH_LONG[0]   // prev Dec / next Jan
        drawText("\(mName) \(p.targetYear)", CGRect(x: cx - 120, y: cy - 17, width: 240, height: 22),
                 size: 18, align: .center, color: theme.text, weight: .semibold, into: &layer)
        let cap = p.armed ? "Release to switch" : (p.atTop ? "Previous month" : "Next month")
        drawText(cap, CGRect(x: cx - 120, y: cy + 5, width: 240, height: 14),
                 size: 10, align: .center, color: p.armed ? theme.nowLine : theme.text.opacity(0.55),
                 weight: p.armed ? .semibold : .regular, into: &layer)
    }

    // DEBUG: visualize the year-scroll boundaries + flip threshold. Toggle with debugScroll.
    // Compile-time false in release, so the guarded draw path dead-strips entirely.
    #if DEBUG
    static var debugScroll = false
    #else
    static let debugScroll = false
    #endif
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
    private static func drawDeadlines(_ input: SceneInput, _ deadlines: [Deadline], _ selected: String?, _ drawerOpen: Bool, _ hovered: String?, _ only: String?, _ hide: String?, _ ctx: inout GraphicsContext, _ theme: Theme) {
        let anim = input.monthAnim
        // Outgoing (current) month — slides + fades out during a page-turn (anim==nil → resting).
        let outMul = anim.map { outgoingDetailReveal($0.p) } ?? 1
        drawDeadlineLayer(input, deadlines, selected, drawerOpen, hovered, only, hide, &ctx, theme, focus: input.focus, anim: anim, fadeMul: outMul)
        // Incoming month during a page-turn: its deadlines slide in + fade in with its timeline.
        if let anim {
            let to = input.focus + anim.dir
            if to >= 0, to <= 11 {
                drawDeadlineLayer(input, deadlines, selected, drawerOpen, hovered, only, hide, &ctx, theme, focus: to, anim: anim, fadeMul: incomingDetailReveal(anim.p))
            }
        }
    }

    private static func drawDeadlineLayer(_ input: SceneInput, _ deadlinesIn: [Deadline], _ selected: String?, _ drawerOpen: Bool, _ hovered: String?, _ only: String?, _ hide: String?, _ ctx: inout GraphicsContext, _ theme: Theme, focus: Int, anim: PageAnim?, fadeMul: CGFloat) {
        let tl = timelineInfo(input, focus: focus, anim: anim)
        guard tl.reveal > 0.05, tl.hourH > 0 else { return }
        // Draw the hovered / selected deadline LAST so its moment line + dots sit on top of neighbors.
        func rank(_ d: Deadline) -> Int {
            if d.id == selected { return drawerOpen ? 4 : 3 }
            if selected.map({ sourceId(of: d.id) == sourceId(of: $0) }) == true { return 2 }
            return d.id == hovered ? 1 : 0
        }
        let deadlines = deadlinesIn.enumerated().sorted { rank($0.element) != rank($1.element) ? rank($0.element) < rank($1.element) : $0.offset < $1.offset }.map(\.element)
        let clipRight = dashboardLeftAnimated(input)   // clip to the animated dashboard mask
        var clip = ctx
        // Widen BOTH edges by the end-dot radius so a deadline's left/right dots (centered on the
        // content boundaries — the gutter and the day-view dashboard mask) draw whole, not halved.
        let dotR: CGFloat = 4
        clip.clip(to: Path(CGRect(x: Layout.labelW - dotR, y: tl.tlTop, width: max(0, clipRight - Layout.labelW + 2 * dotR), height: tl.tlBottom - tl.tlTop)))
        var gf = input; gf.focus = focus
        for d in deadlines {
            if let only, d.id != only { continue }   // lifted copy → draw ONLY this deadline
            if let hide, d.id == hide { continue }    // blurred main scene → SKIP it (drawn sharp in the lift)
            guard let pos = deadlinePos(d, input, focus: focus, anim: anim) else { continue }
            let rd = relDomOf(input.year, focus, d.year, d.month, d.day) ?? -999
            let spill = (input.z >= 1.5) ? spillFactor(d.month, gf) : 1   // dim spillover-day deadlines; cross-fade on flip
            let fade = dailyFade(rd, gf) * tl.reveal * fadeMul * spill
            if fade <= 0.02 { continue }
            var layer = clip
            layer.opacity = Double(fade)
            let color = theme.eventBorder(d.color)
            // The moment line stays SOLID at every activation level — only the LABEL (a SwiftUI glass
            // pill; see DeadlinesOverlay) shows selection styling. Width just bumps a touch when focused.
            let isMain = d.id == selected
            let inSeries = selected.map { sourceId(of: d.id) == sourceId(of: $0) } ?? false
            let lineW: CGFloat = isMain ? (drawerOpen ? 3 : 2.5) : (inSeries ? 2 : 1.5)
            var line = Path()
            line.move(to: CGPoint(x: pos.x, y: pos.y)); line.addLine(to: CGPoint(x: pos.x + pos.w, y: pos.y))
            layer.stroke(line, with: .color(color), lineWidth: lineW)
            for cx in [pos.x, pos.x + pos.w] {
                let dot = Path(ellipseIn: CGRect(x: cx - 3, y: pos.y - 3, width: 6, height: 6))
                layer.fill(dot, with: .color(theme.bg)); layer.stroke(dot, with: .color(color), lineWidth: 1.5)
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
        case .todayMonth:
            ctx.fill(Path(it.rect), with: .color(theme.todayMonthWash))
        case .now:
            ctx.fill(Path(it.rect), with: .color(theme.nowLine))
            drawEndDots(it, &ctx, color: theme.nowLine, bg: theme.bg)
        case .cursor:
            if !it.hollow { ctx.fill(Path(it.rect), with: .color(theme.cursor)) }   // hollow → dots only
            drawEndDots(it, &ctx, color: theme.cursor, bg: theme.bg)
        case .monthLabel: drawMonthLabel(it, &ctx, theme)
        case .dayLabel: drawDayLabel(it, &ctx, theme)
        case .todayTag:
            drawText(it.text ?? "", it.rect, size: it.fontSize ?? 8, align: it.align, color: theme.nowLine, weight: .bold, tracking: 1.2, into: &ctx)
        case .weekdayTag:
            drawPillText(it.text ?? "", it.rect, size: it.fontSize ?? 9, color: theme.text, theme: theme, into: &ctx)
        case .nowLabel:
            break   // the CURRENT TIME label is rendered in SwiftUI (EventsOverlay) for real glass
        case .timeTag:
            break   // the mouse-cursor time tag is rendered in SwiftUI (EventsOverlay) — see cursorTagView
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
        // The dashboard is a two-layer carousel (mirrors the web's cc-daily-dash / cc-daily-inner-dash):
        //  • a FIXED mask — the region between `dashLeft` and the right edge. It doesn't move or fade
        //    with day paging; the timeline is clipped out of it (window glass shows through), and it
        //    only reveals with the zoom (`reveal`, slid in from the right via dashboardLeftAnimated).
        //  • per-day PANELS (bars + name + date, and future content) that slide a full panel-width and
        //    cross-fade like a carousel as you page days — the whole panel moves together, not just the date.
        let dashLeft = dashboardLeftAnimated(input)
        if dashLeft >= input.vp.w - 1 { return }
        let barX = dashLeft + 25                       // matches the web's --dd-pad: 25px
        let barRight = input.vp.w - 18
        let lowerBarY = Layout.topPad + Layout.monthH
        let w = barRight - barX
        let panelW = max(1, input.vp.w - dashLeft)     // one panel = the full dashboard width
        let clipRect = Path(CGRect(x: dashLeft, y: 0, width: panelW, height: input.vp.h))

        let cal = Calendar.current
        let today = cal.dateComponents([.year, .month, .day], from: input.now)

        // One day's panel, translated by `x` (0 = centered) and faded by distance from center.
        func drawPanel(_ dom: Int, _ x: CGFloat) {
            let op = max(0, 1 - abs(x) / panelW)       // web: opacity = 1 − |x|/width
            guard op > 0.01, let r = resolveDate(input.year, input.focus, dom) else { return }
            var layer = ctx
            layer.opacity = Double(reveal * op)
            layer.clip(to: clipRect)
            // top + bottom bars — matching the band's emphasized edge; slide rigidly with the panel.
            // The band's top/bottom borders draw at bandY − 1 (see buildMonthBands ftopg/msep), so shift
            // these up 1px to line up exactly with the timeline track's borders across the boundary.
            for y in [Layout.topPad - 0.5, lowerBarY - 0.5] {
                var p = Path()
                p.move(to: CGPoint(x: barX + x, y: y)); p.addLine(to: CGPoint(x: barRight + x, y: y))
                layer.stroke(p, with: .color(theme.sep.opacity(Layout.bandEdgeOpacity)), lineWidth: Layout.bandEdgeWidth)
            }
            drawText("DAILY DASHBOARD", CGRect(x: barX + x, y: lowerBarY - 46, width: w, height: 14),
                     size: 10, align: .left, color: theme.textMuted, tracking: 1.5, into: &layer)
            // date + a (Today/Yesterday/Tomorrow) suffix (muted), like the web's cc-dd-special
            let base = "\(WD_LONG[dayOfWeek(r.year, r.month, r.day)]), \(MONTH_LONG[r.month]) \(r.day)"
            var special = ""
            if let d0 = cal.date(from: DateComponents(year: today.year, month: today.month, day: today.day)),
               let d1 = cal.date(from: DateComponents(year: r.year, month: r.month + 1, day: r.day)) {
                switch cal.dateComponents([.day], from: d0, to: d1).day ?? 99 {
                case 0: special = " (Today)"; case -1: special = " (Yesterday)"; case 1: special = " (Tomorrow)"; default: break
                }
            }
            drawText(base + special, CGRect(x: barX + x, y: lowerBarY - 33, width: w, height: 26),
                     size: 19, align: .left, color: theme.text, weight: .medium, into: &layer)
        }
        if let a = input.daily.anim {
            let dir = CGFloat(a.dir)
            drawPanel(input.daily.dom, -dir * a.p * panelW)              // current slides out + fades
            drawPanel(input.daily.dom + a.dir, dir * (1 - a.p) * panelW) // incoming slides in from the other side
        } else {
            drawPanel(input.daily.dom, 0)
        }
    }

    private static func drawTrackNames(_ input: SceneInput, _ tracks: [[String]], _ hide: (Int, Int)?, _ ctx: inout GraphicsContext, _ theme: Theme) {
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
                if hide?.0 == m, hide?.1 == i { continue }   // slot is being edited inline
                let name = i < names.count ? names[i] : ""
                // Match the event-name font (Comic Sans MS 13) for a consistent look; the
                // left inset matches the inline editor's leading padding (no jump on edit).
                drawText(name, CGRect(x: left + 10, y: y, width: width - 14, height: f.trackH),
                         size: 13, align: .left, color: theme.text, font: .custom("Comic Sans MS", size: 13),
                         into: &layer, clipToRect: true)
            }
            // Gutter bottom border (the grid's month divider doesn't reach the gutter).
            // Emphasized (shared band-edge style) for a quarter's bottom month OR the focused
            // band in month view; internal dividers otherwise. Matches the grid msep.
            let quarterBottom = m % 3 == 2
            let isFocus = m == input.focus || (input.monthAnim != nil && m == input.focus + input.monthAnim!.dir)
            let edge = max(quarterBottom ? 1 : 0, isFocus ? clamp((input.z - 0.82) / 0.18, 0, 1) : 0)
            var bottom = Path()
            let by = f.bandY + 4 * f.trackH
            bottom.move(to: CGPoint(x: 0, y: by)); bottom.addLine(to: CGPoint(x: Layout.labelW - Layout.rightPad, y: by))
            layer.stroke(bottom, with: .color(theme.sep.opacity(lerp(Layout.bandInnerOpacity, Layout.bandEdgeOpacity, edge))),
                         lineWidth: lerp(Layout.bandInnerWidth, Layout.bandEdgeWidth, edge))
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
