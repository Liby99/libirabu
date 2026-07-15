// Timed + band events as real SwiftUI views layered over the Canvas — each sticker
// is Liquid Glass (.glassEffect), so overlapping events are genuinely translucent
// and blur what's behind them (the native analogue of the web's translucent fill +
// backdrop-filter). Visual only; gestures are handled by the AppKit input bridge.

import SwiftUI
import AppKit
import CalendarGeometry

struct EventsOverlay: View {
    let input: SceneInput
    let events: [TimedEvent]
    let bands: [BandEvent]
    var bandBadges: [String: EventBadges] = [:]   // provenance/kind markers per band box id
    var eventBadges: [String: EventBadges] = [:]  // …and per timed-event box id
    let selected: String?        // the selected BOX id (a ghost carries occKey); series-matched below
    let hovered: String?         // the hovered BOX id (exact box gets hover feedback)
    let drawerOpen: Bool         // the detail drawer is open → the focused box gets the thick border
    let editingId: String?
    var draggingId: String? = nil   // event being moved/resized → floats full-width above the day,
                                    // and is excluded from the others' overlap packing (no reflow)
    var perfMode: Bool = false   // flat tinted fills instead of Liquid Glass (global toggle)
    let theme: Theme

    static let spilloverDim: CGFloat = 0.45   // opacity of neighbor-month (spillover-day) events

    /// A box belongs to the clicked event's series (same source: recurrence occurrence / promoted
    /// bar / original), so it shares the accompanied style.
    private func inSeries(_ id: String) -> Bool { selected.map { sourceId(of: id) == sourceId(of: $0) } ?? false }

    /// The activation level for a box (see EventActivation). The exact clicked box is focusMain
    /// (single click) or selected (drawer open); its siblings are accompanied; an unrelated box the
    /// pointer is over is hover; everything else is plain.
    private func activation(_ id: String) -> EventActivation {
        if id == selected { return drawerOpen ? .selected : .focusMain }
        if inSeries(id) { return .accompanied }
        if id == hovered { return .hover }
        return .plain
    }

    var body: some View {
        let anim = input.monthAnim
        let to = anim.map { input.focus + $0.dir }
        // Outgoing (current) month — slides + fades out during a page-turn (anim==nil → resting, mul 1).
        let tlOut = timelineInfo(input, anim: anim)
        let outMul = anim.map { outgoingDetailReveal($0.p) } ?? 1
        let clipRight = dashboardLeftAnimated(input)   // day-view dashboard mask (slides in from the right)
        let bandClip = CGRect(x: Layout.labelW, y: 0, width: max(0, clipRight - Layout.labelW), height: input.vp.h)

        ZStack(alignment: .topLeading) {
            stickers(bandItems()).clipShape(RectClip(rect: bandClip))
            if tlOut.reveal > 0.05 && tlOut.hourH > 0 {
                stickers(timedItems(tlOut, focus: input.focus, fadeMul: outMul))
                    .clipShape(RectClip(rect: tlClip(tlOut, clipRight)))
            }
            // Incoming month during a page-turn: its timeline slides in from the opposite edge,
            // and its timed events fade in alongside it (matching the incoming grid's reveal).
            if let anim, let to, to >= 0, to <= 11 {
                let tlIn = timelineInfo(input, focus: to, anim: anim)
                if tlIn.reveal > 0.05 && tlIn.hourH > 0 {
                    stickers(timedItems(tlIn, focus: to, fadeMul: incomingDetailReveal(anim.p), keyTag: "~in"))
                        .clipShape(RectClip(rect: tlClip(tlIn, clipRight)))
                }
            }
            // Year-view weekday marker ("Thu") floating above the hovered day — a small
            // Liquid Glass capsule, centered on the day column.
            if let wm = weekdayMarker() {
                Text(wm.text)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2.5)
                    .glassEffect(.regular, in: .capsule)
                    .fixedSize()
                    .position(wm.center)
            }
            // Current-time label(s): dark-red glass + a red caret pointing at the now-line. The line
            // itself stays in the Canvas; only this label is SwiftUI (for real glass blur).
            ForEach(nowLabelSpecs(input)) { spec in
                nowLabelView(spec)
            }
            // Mouse-cursor time tag: SwiftUI (not Canvas) so it isn't clipped at the gutter and its
            // side animates smoothly on a flip (e.g. the week↔day transition) instead of jumping.
            if let tag = cursorTagSpec(input) {
                cursorTagView(tag)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private func cursorTagView(_ spec: CursorTagSpec) -> some View {
        let c = theme.cursor
        let shape = RoundedRectangle(cornerRadius: 5)
        Text(spec.text)
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(c)
            .frame(width: spec.rect.width, height: spec.rect.height)
            .background(shape.fill(theme.bg.opacity(0.82)))
            .overlay(shape.strokeBorder(c, lineWidth: 1))
            // Caret on the line-facing edge; on a side flip the old one retracts and the new one grows.
            .overlay { flipCaret(pointsRight: true, shown: spec.pointsRight, color: c, h: 8) }
            .overlay { flipCaret(pointsRight: false, shown: !spec.pointsRight, color: c, h: 8) }
            .opacity(spec.opacity)
            .position(x: spec.rect.midX, y: spec.rect.midY)
            .animation(.easeInOut(duration: 0.2), value: spec.pointsRight)   // slide + caret-swap on flip
            .allowsHitTesting(false)
    }

    /// A caret on one edge that grows in / retracts out as `shown` toggles — so a left↔right flip
    /// reads as one caret sliding out while the other slides in, instead of instantly swapping sides.
    @ViewBuilder private func flipCaret(pointsRight: Bool, shown: Bool, color: Color, h: CGFloat) -> some View {
        Caret(pointsRight: pointsRight).fill(color)
            .frame(width: 5, height: h)
            .scaleEffect(x: shown ? 1 : 0, anchor: pointsRight ? .leading : .trailing)   // grow/retract at the edge
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: pointsRight ? .trailing : .leading)
            .offset(x: pointsRight ? 5 : -5)
            .opacity(shown ? 1 : 0)
    }

    @ViewBuilder private func nowLabelView(_ spec: NowLabelSpec) -> some View {
        let red = theme.nowLine
        let shape = RoundedRectangle(cornerRadius: 10)   // match the deadline pill's radius
        // Dark mode: dark base + strong red glass, white label. Light mode: a bright frosted
        // base with only a faint red tint, and a dark label — the time stays red in both.
        let labelColor: Color = theme.dark ? .white.opacity(0.7) : theme.text.opacity(0.7)
        let baseFill: Color = (theme.dark ? Color.black : Color.white).opacity(theme.dark ? 0.55 : 0.62)
        let glassTint = red.opacity(theme.dark ? 0.5 : 0.14)
        VStack(alignment: spec.pointsRight ? .trailing : .leading, spacing: -1) {
            Text("CURRENT TIME").font(.system(size: 7.5, weight: .semibold)).foregroundStyle(labelColor)
            Text(spec.text).font(.system(size: 13, weight: .bold)).foregroundStyle(red)   // time in the accent color
        }
        .padding(.horizontal, 7).padding(.vertical, 3)          // match the deadline pill's padding
        .frame(width: spec.rect.width, height: spec.rect.height, alignment: spec.pointsRight ? .trailing : .leading)
        .background(shape.fill(baseFill))                        // solid base so the frost reads clean
        .glassEffect(.regular.tint(glassTint), in: shape)
        .overlay(shape.strokeBorder(red, lineWidth: 1))          // fully wrapped border
        // Caret on the line-facing edge; on a side flip (e.g. week↔day) the old one retracts and the
        // new one grows, so the label slides across smoothly instead of jumping.
        .overlay { flipCaret(pointsRight: true, shown: spec.pointsRight, color: red, h: 9) }
        .overlay { flipCaret(pointsRight: false, shown: !spec.pointsRight, color: red, h: 9) }
        .opacity(spec.opacity)
        .position(x: spec.rect.midX, y: spec.rect.midY + 1)     // nudge the whole label + caret down 1px
        .animation(.easeInOut(duration: 0.2), value: spec.pointsRight)   // slide + caret-swap on flip
        .allowsHitTesting(false)
    }

    /// Clip a timeline layer to its own (possibly sliding) day-detail region.
    private func tlClip(_ tl: TimelineInfo, _ clipRight: CGFloat) -> CGRect {
        CGRect(x: Layout.labelW, y: tl.tlTop, width: max(0, clipRight - Layout.labelW),
               height: max(0, tl.tlBottom - tl.tlTop))
    }

    /// The floating weekday chip for year-view day hover. Mirrors buildHover's `dayOn`:
    /// year zoom, a hovered month on screen, and a valid day-of-month.
    private func weekdayMarker() -> (center: CGPoint, text: String)? {
        guard input.z < 0.5, let m = input.hover.month, let dom = input.hover.dom else { return nil }
        guard dom >= 1 && dom <= daysInMonth(input.year, m) else { return nil }
        let f = frameFor(m, input)
        guard f.bandY <= input.vp.h + 20, f.bandY + 4 * f.trackH >= -20 else { return nil }  // on screen
        let cx = f.x0 + (CGFloat(dom) - 0.5) * f.dayW   // center of the day column
        let cy = f.bandY - 15                            // floated above the band top
        return (CGPoint(x: cx, y: cy), WD3[dayOfWeek(input.year, m, dom)])
    }

    private struct Item2: Identifiable { let id: String; let rect: CGRect; let fade: Double; let z: Double; let view: AnyView }

    @ViewBuilder private func stickers(_ items: [Item2]) -> some View {
        ZStack(alignment: .topLeading) {
            // Stable identity (event id) so a z-order re-sort keeps the view alive and its
            // hover/select transitions can animate rather than snapping. Draw order is the
            // explicit per-item z (band: 10+startDay baseline, raised on hover/select).
            ForEach(items) { it in
                it.view
                    .frame(width: it.rect.width, height: it.rect.height)
                    .position(x: it.rect.midX, y: it.rect.midY)
                    .opacity(it.fade)
                    .zIndex(it.z)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A rect is worth rendering only if it (nearly) intersects the viewport. Culls the ~11
    /// months that sit off-screen in month view, and anything scrolled out of view elsewhere —
    /// each survivor is a real Liquid Glass sticker, so skipping them is the big per-frame win.
    private func onScreen(_ rect: CGRect) -> Bool {
        let M: CGFloat = 40
        return rect.maxY > -M && rect.minY < input.vp.h + M && rect.maxX > -M && rect.minX < input.vp.w + M
    }

    private func bandItems() -> [Item2] {
        var placed: [(ev: BandEvent, rect: CGRect, fade: Double)] = []
        let weekish = input.z >= 1.5
        for b in bands {
            // Month/year layout positions a band by its month alone (frameFor(b.month)), so a
            // neighbor-year band would land in the CURRENT year's same-month row. Only the week/day
            // (weekish) path is year-safe (bandEventRect gates via relDomOf), so skip cross-year
            // bands outside it — they show only as week-view boundary spillover.
            if !weekish && b.year != input.year { continue }
            guard let r = bandEventRect(b, input, anim: input.monthAnim) else { continue }
            // Opacity comes from the FOCUS frame in week/day view (the adjacent month's own frame is
            // off-screen there); a neighbor-month band shown in the spillover columns is dimmed.
            let f = frameFor(weekish ? input.focus : b.month, input, anim: input.monthAnim)
            let spill: Double = weekish ? Double(spillFactor(b.month, input, dim: Self.spilloverDim)) : 1
            let rect = CGRect(x: r.x, y: r.y, width: r.w, height: r.h)
            guard f.opacity > 0.004, onScreen(rect) else { continue }   // skip invisible / off-screen months
            placed.append((b, rect, Double(f.opacity) * spill))
        }
        // Fully-overlapping (same month/track/startDay/endDay): collapse to ONE (highest id),
        // hide the rest, and flag the kept one with a warning sign.
        var hidden = Set<String>(), warn = Set<String>()
        var full: [String: [Int]] = [:]
        for (i, p) in placed.enumerated() { full["\(p.ev.month)-\(p.ev.track)-\(p.ev.startDay)-\(p.ev.endDay)", default: []].append(i) }
        for (_, idxs) in full where idxs.count > 1 {
            let keep = idxs.max { placed[$0].ev.id < placed[$1].ev.id }!
            warn.insert(placed[keep].ev.id)
            for i in idxs where i != keep { hidden.insert(placed[i].ev.id) }
        }
        // Per lane (visible bars): gap = px to the nearest LATER-starting bar (title clips
        // before it; unbounded if none). Same-start stacks: shorter on top (z), longer
        // simply behind — its title runs full and is covered by the shorter bar.
        var gapBy: [String: CGFloat] = [:]
        var zBy: [String: Double] = [:]
        var clipBox = Set<String>()   // non-longest same-start bars clip to their own box
        var byLane: [String: [Int]] = [:]
        // Week view shows both months on the same 4 lanes, so group by track alone — a spillover
        // (neighbor-month) bar must "see" the focus bars on its lane so its title clips before them.
        for (i, p) in placed.enumerated() where !hidden.contains(p.ev.id) {
            byLane[weekish ? "\(p.ev.track)" : "\(p.ev.month)-\(p.ev.track)", default: []].append(i)
        }
        for (_, idxs) in byLane {
            for i in idxs {
                // Compare by rendered X (startDay isn't comparable across months in the shared lane).
                let later = idxs.filter { placed[$0].rect.minX > placed[i].rect.minX + 1 }
                if let nearest = later.min(by: { placed[$0].rect.minX < placed[$1].rect.minX }) {
                    gapBy[placed[i].ev.id] = placed[nearest].rect.minX - placed[i].rect.minX
                }
            }
            var byDay: [Int: [Int]] = [:]
            for i in idxs { byDay[placed[i].ev.startDay, default: []].append(i) }
            for (start, stackIdxs) in byDay where stackIdxs.count >= 2 {
                func len(_ i: Int) -> Int { placed[i].ev.endDay - placed[i].ev.startDay }
                let stack = stackIdxs.sorted { len($0) > len($1) }   // longest first (bottom)
                for si in stack.indices {
                    zBy[placed[stack[si]].ev.id] = Double(10 + start + si * 2)   // shorter → higher → on top
                    if si > 0 { clipBox.insert(placed[stack[si]].ev.id) }        // all but the longest
                }
            }
        }
        return placed.compactMap { p in
            let id = p.ev.id
            if hidden.contains(id) { return nil }
            let a = activation(id)
            let z: Double = a.isActive ? a.z : (zBy[id] ?? Double(10 + p.ev.startDay))
            return Item2(id: id, rect: p.rect, fade: p.fade, z: z, view: AnyView(
                BandSticker(ev: p.ev, activation: a, editing: id == editingId,
                            gap: gapBy[id], clipBox: clipBox.contains(id),
                            warn: warn.contains(id), box: p.rect.size,
                            badges: bandBadges[id] ?? [],
                            plain: perfMode,
                            theme: theme)))
        }
    }

    /// Timed stickers for one month `focus`, placed against its timeline `tl`. `fadeMul` scales
    /// the whole layer (a page-turn fades the outgoing set out / incoming set in); `keyTag` keeps
    /// the incoming set's ForEach ids distinct from the outgoing set's during the cross-fade.
    private func timedItems(_ tl: TimelineInfo, focus: Int, fadeMul: CGFloat = 1, keyTag: String = "") -> [Item2] {
        var byDay: [Int: [TimedEvent]] = [:]
        // `relDomOf` gates adjacency (returns nil for non-neighbor months), so iterating all years lets
        // Dec↔Jan spillover events cross the year boundary while far-off months are still excluded.
        for e in events {
            if let rd = relDomOf(input.year, focus, e.year, e.month, e.day) { byDay[rd, default: []].append(e) }
        }
        var gf = input; gf.focus = focus
        let dim = daysInMonth(input.year, focus)
        var placed: [(ev: TimedEvent, rect: CGRect, fade: Double)] = []
        for (rd, evs) in byDay {
            // Spillover day (belongs to the previous/next month) → drawn dimmed but fully interactive;
            // a month-edge flip cross-fades the dim/bright swap. (rd<1 → prev month, rd>dim → next.)
            let evMonth = rd < 1 ? focus - 1 : (rd > dim ? focus + 1 : focus)
            let spill = (input.z >= 1.5) ? spillFactor((evMonth + 12) % 12, gf, dim: Self.spilloverDim) : 1
            let fade = dailyFade(rd, gf) * tl.reveal * fadeMul * spill
            if fade <= 0.02 { continue }
            // Pack the OTHER events as if the dragged one weren't in this day, so they don't shrink/
            // reflow mid-edit; the dragged event then gets no layout slot → eventRect renders it
            // full-width, and it draws on top (selected → frontmost z). Committed on drop.
            let layout = layoutDay(draggingId != nil ? evs.filter { $0.id != draggingId } : evs)
            for e in evs {
                guard let r = eventRect(e, input.year, focus, tl, input.vp, layout[e.id]) else { continue }
                let rect = CGRect(x: r.minX, y: tl.tlTop - tl.scroll + r.minY, width: r.width, height: r.height)
                if rect.maxY < tl.tlTop || rect.minY > tl.tlBottom { continue }   // outside the timeline band
                if rect.maxX < -40 || rect.minX > input.vp.w + 40 { continue }    // scrolled off horizontally (week/day)
                placed.append((e, rect, Double(fade)))
            }
        }
        placed.sort(by: orderTimed)
        return placed.enumerated().map { i, p in
            let id = p.ev.id
            let a = activation(id)
            let z: Double = a.isActive ? a.z : Double(i)
            return Item2(id: id + keyTag, rect: p.rect, fade: p.fade, z: z, view: AnyView(
                EventSticker(ev: p.ev, height: p.rect.height, showText: input.z >= 1.5,
                             plain: perfMode, activation: a, badges: eventBadges[id] ?? [], theme: theme)))
        }
    }

    // Draw order: later-starting events in front; the selected one always frontmost.
    private func orderTimed(_ a: (ev: TimedEvent, rect: CGRect, fade: Double), _ b: (ev: TimedEvent, rect: CGRect, fade: Double)) -> Bool {
        let sa = inSeries(a.ev.id), sb = inSeries(b.ev.id)
        if sa != sb { return sb }                                  // selected series sorts last (front)
        if a.ev.startHour != b.ev.startHour { return a.ev.startHour < b.ev.startHour }
        return a.ev.endHour > b.ev.endHour
    }
}

private extension View {
    /// Event surface. `flat` = cheap tinted fill (Performance Mode at rest). `keepFillBase` keeps
    /// that flat fill UNDER the glass (Performance Mode is on), so a flat→glass hover cross-fades:
    /// the fill stays put and the glass materializes over the colored fill instead of tearing the
    /// fill out and flashing the dark backdrop while the glass forms. Non-perf: glass only.
    @ViewBuilder func eventSurface(_ glass: Glass, plainFill: Color, in shape: RoundedRectangle, flat: Bool, keepFillBase: Bool) -> some View {
        self.background {
            ZStack {
                if flat || keepFillBase { shape.fill(plainFill) }      // stable base in Performance Mode
                if !flat { Color.clear.glassEffect(glass, in: shape) } // glass on top; fades in over the fill
            }
        }
    }
}

/// A timed event — same visual language as a band (BandStyle): frosted glass tinted with
/// the event color, a rounded accent bar, dotted-when-selected / solid-when-drawer border.
/// Content is the height-driven title + time (clipped, unlike bands' overflow).
private struct EventSticker: View {
    let ev: TimedEvent
    let height: CGFloat
    var showText: Bool = true    // month view hides title/time (tiny slivers) — glass + bar only
    var plain: Bool = false      // skip glass (animating, or tiny month sliver)
    let activation: EventActivation
    var badges: EventBadges = [] // provenance/kind marker glyphs (same as bands)
    let theme: Theme

    var body: some View {
        let lay = eventTextLayout(height)
        let border = theme.eventBorder(ev.color)
        let color = theme.eventColor(ev.color)
        let r = BandStyle.cornerRadius
        let active = activation.isActive
        let tint = activation.tint * theme.eventTintScale
        let glass: Glass = (active || BandStyle.idleFrosted) ? .regular.tint(color.opacity(tint))
                                                             : .clear.tint(color.opacity(tint))
        let barWidth = activation.accentWide ? BandStyle.accentWidthSelected : BandStyle.accentWidth
        // The left accent bar is a fixed-width vertical bar on every timed event, tall or short.
        // Normally inset top/bottom (accentInset) like a band; but on a short event the inset would
        // eat the bar, so shrink it toward 0 — a very short event's bar spans the full height.
        let barVInset = min(BandStyle.accentInset, max(0, (height - BandStyle.accentInset * 2) / 2))
        VStack(alignment: .leading, spacing: showText ? -1 : 0) {
            // Month view (no title): markers sit in-flow at the top, same as bands. Week/day view
            // shows the title starting at the top — its markers are a top-right overlay (below), so
            // they don't push the title down.
            if !showText, !badges.isEmpty {
                badgeRow(badges, border)
            }
            if showText {
                Text(ev.title)
                    .font(.custom("Comic Sans MS", size: lay.tiny ? 10 : 13))
                    .foregroundStyle(theme.text)
                    .lineLimit(lay.titleLines)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if !(lay.short || lay.tiny) {
                    Text(fmtHourRange(ev.startHour, ev.endHour))
                        .font(.system(size: 8.5))
                        .foregroundStyle(theme.text.opacity(0.72))
                        .padding(.top, 2)   // a touch more breathing room below the title
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, BandStyle.accentInset + barWidth + BandStyle.barTextGap)
        .padding(.trailing, BandStyle.titleTrailing)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .eventSurface(glass, plainFill: color.opacity(tint), in: RoundedRectangle(cornerRadius: r), flat: plain && !active, keepFillBase: plain)
        .overlay(alignment: .topTrailing) {   // week/day view: markers pinned to the top-right corner
            if showText, !badges.isEmpty {
                badgeRow(badges, border).padding(.top, 3).padding(.trailing, 4)
            }
        }
        .overlay(alignment: .leading) {   // rounded accent bar, inset + thicker when selected
            Capsule().fill(border).frame(width: barWidth)
                .padding(.vertical, barVInset).padding(.leading, BandStyle.accentInset)
        }
        .overlay { activationBorder(activation, color: border, radius: r) }
        .animation(.easeInOut(duration: BandStyle.animation), value: activation)
    }
}

// ── Deadline labels: SwiftUI glass pills above the Canvas moment-line ─────────────────
// The horizontal moment line + end dots are drawn in the Canvas (SceneRenderer.drawMid); this
// renders the LABEL as a glass pill with the SAME five activation levels as events (tint by level;
// border: none for plain/hover, solid focus-main, dashed accompanied, thick selected). The line
// itself never dashes — selection styling lives entirely on the pill.
struct DeadlinesOverlay: View {
    let input: SceneInput
    let deadlines: [Deadline]
    var sides: [String: Bool] = [:]   // offline side assignment (id → onLeft); base for each label
    let selected: String?
    let hovered: String?
    let drawerOpen: Bool
    let theme: Theme

    private func inSeries(_ id: String) -> Bool { selected.map { sourceId(of: id) == sourceId(of: $0) } ?? false }
    private func activation(_ id: String) -> EventActivation {
        if id == selected { return drawerOpen ? .selected : .focusMain }
        if inSeries(id) { return .accompanied }
        if id == hovered { return .hover }
        return .plain
    }

    // Per-label content + geometry (both possible sides). The base side comes from `sides`; the
    // rendered pill matches the hit-test because both use the same base + flip rule.
    private struct Spec: Identifiable { let id: String; let info: DeadlineLabelInfo; let color: String; let fade: Double }

    private func specs(focus: Int, anim: PageAnim?, fadeMul: CGFloat) -> [Spec] {
        let tl = timelineInfo(input, focus: focus, anim: anim)
        guard tl.reveal > 0.05, tl.hourH > 0 else { return [] }
        var gf = input; gf.focus = focus
        var out: [Spec] = []
        for d in deadlines {
            guard let pos = deadlinePos(d, input, focus: focus, anim: anim) else { continue }
            let rd = relDomOf(input.year, focus, d.year, d.month, d.day) ?? -999
            let spill = (input.z >= 1.5) ? spillFactor(d.month, gf, dim: EventsOverlay.spilloverDim) : 1
            let fade = dailyFade(rd, gf) * tl.reveal * fadeMul * spill
            if fade <= 0.02 { continue }
            out.append(Spec(id: d.id, info: deadlineLabelInfo(d, lineX: pos.x, lineY: pos.y, colW: pos.w, input), color: d.color, fade: Double(fade)))
        }
        return out
    }

    var body: some View {
        let anim = input.monthAnim
        let clipRight = dashboardLeftAnimated(input)   // day-view dashboard mask (slides in from the right)
        let outMul = anim.map { outgoingDetailReveal($0.p) } ?? 1
        ZStack(alignment: .topLeading) {
            pillLayer(focus: input.focus, anim: anim, fadeMul: outMul, clipRight: clipRight)
            if let anim {
                let to = input.focus + anim.dir
                if to >= 0, to <= 11 { pillLayer(focus: to, anim: anim, fadeMul: incomingDetailReveal(anim.p), clipRight: clipRight) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    @ViewBuilder private func pillLayer(focus: Int, anim: PageAnim?, fadeMul: CGFloat, clipRight: CGFloat) -> some View {
        let tl = timelineInfo(input, focus: focus, anim: anim)
        let H = DeadlineLabel.height
        let all = specs(focus: focus, anim: anim, fadeMul: fadeMul)
        // The raised label (hovered / selected); neighbours only yield when its cursor LINE would cross
        // them. Pure label-label overlap is fine — the raised label just occludes the other.
        let topSpec = all.max { activation($0.id).z < activation($1.id).z }
        let topLine: CGRect? = topSpec.flatMap { t in
            activation(t.id).z > 0 ? CGRect(x: t.info.lineX - 4, y: t.info.lineY - 5, width: t.info.colW + 8, height: 10) : nil
        }
        let topId = topSpec?.id
        ZStack(alignment: .topLeading) {
            ForEach(all) { s in
                let a = activation(s.id)
                let base = sides[s.id] ?? s.info.defaultOnLeft   // offline assignment (fallback: default)
                // Flip to the other side only when the raised deadline's LINE would cross this label —
                // but never in day view, where labels always stay on the left of the single day column.
                let flip = input.z <= 2 && topId != nil && topId != s.id && topLine.map { s.info.rect(onLeft: base).intersects($0) } == true
                let onLeft = flip ? !base : base
                let rect = s.info.rect(onLeft: onLeft)
                DeadlinePill(title: s.info.title, timeLine: s.info.timeLine, color: theme.eventBorder(s.color),
                             activation: a, onLeft: onLeft, width: rect.width, height: rect.height, theme: theme)
                    .opacity(s.fade)
                    .position(x: rect.midX, y: rect.midY)
                    .zIndex(a.z)   // hovered/selected label rises above overlapping neighbors
                    .animation(.easeInOut(duration: 0.2), value: onLeft)   // slide + caret-swap on flip
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Clip vertically to the timeline (so a deadline scrolled out of view hides its label);
        // horizontal is generous so a side-placed pill/caret isn't cut.
        .clipShape(RectClip(rect: CGRect(x: -Layout.labelW, y: tl.tlTop - H, width: input.vp.w + 2 * Layout.labelW, height: (tl.tlBottom - tl.tlTop) + 2 * H)))
    }
}

/// One deadline label: a two-line glass pill (title over time+timezone) sized like a band event,
/// tinted + bordered by its activation level, with a caret pointing into the moment line.
private struct DeadlinePill: View {
    let title: String
    let timeLine: String
    let color: Color
    let activation: EventActivation
    let onLeft: Bool          // pill sits left of the column → caret/border on its RIGHT edge (points in)
    let width: CGFloat
    let height: CGFloat
    let theme: Theme
    var body: some View {
        let r: CGFloat = 10
        let shape = RoundedRectangle(cornerRadius: r)
        VStack(alignment: .leading, spacing: -1) {
            Text(title).font(.custom("Comic Sans MS", size: 12)).foregroundStyle(theme.text).lineLimit(1)
            Text(timeLine).font(.system(size: 10, weight: .semibold)).foregroundStyle(color).lineLimit(1)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .frame(width: width, height: height, alignment: .leading)
        // Opaque base UNDER the frosted glass (like the event stickers) so the label reads as a solid
        // frosted pill in front of the timeline, not a translucent tint you can see through.
        .background {
            ZStack {
                shape.fill(theme.bg)   // occludes the timeline behind → the frost reads solid
                Color.clear.glassEffect(.regular.tint(color.opacity(activation.tint * theme.eventTintScale)), in: shape)
            }
        }
        // Edge accent (border + caret) on the line-facing side; the other side stays collapsed. On a
        // flip the old caret retracts into the pill edge while the new one grows from the opposite side.
        .overlay { sideEdge(pointsRight: true, shown: onLeft, r: r) }
        .overlay { sideEdge(pointsRight: false, shown: !onLeft, r: r) }
        .overlay { activationBorder(activation, color: color, radius: r) }
        .animation(.easeInOut(duration: BandStyle.animation), value: activation)
    }

    @ViewBuilder private func sideEdge(pointsRight: Bool, shown: Bool, r: CGFloat) -> some View {
        ZStack {
            SideBorder(pointsRight: pointsRight, radius: r).strokeBorder(color, lineWidth: 1)
            Caret(pointsRight: pointsRight).fill(color)
                .frame(width: 6, height: 11)
                .scaleEffect(x: shown ? 1 : 0, anchor: pointsRight ? .leading : .trailing)   // grow/retract at the edge
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: pointsRight ? .trailing : .leading)
                .offset(x: pointsRight ? 6 : -6)
        }
        .opacity(shown ? 1 : 0)
    }
}

/// One rounded side of a pill — the vertical edge plus its two corner arcs — for a colored border
/// that hugs the caret's side (covering the corners, unlike a straight bar).
private struct SideBorder: InsettableShape {
    let pointsRight: Bool
    let radius: CGFloat
    var inset: CGFloat = 0
    func inset(by amount: CGFloat) -> SideBorder { var s = self; s.inset += amount; return s }
    func path(in rectIn: CGRect) -> Path {
        var p = Path()
        let rect = rectIn.insetBy(dx: inset, dy: inset)
        let r = radius - inset   // keep the arcs riding the (inset) rounded corner
        // Just 45° of each corner (the half nearest the vertical edge), so the border only nudges
        // into the corners rather than wrapping them fully.
        if pointsRight {
            p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: .degrees(-45), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: .degrees(0), endAngle: .degrees(45), clockwise: false)
        } else {
            p.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: .degrees(135), endAngle: .degrees(180), clockwise: false)
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(225), clockwise: false)
        }
        return p
    }
}

/// A small triangular caret pointing toward a line (deadline moment line / now-line).
private struct Caret: Shape {
    let pointsRight: Bool
    func path(in rect: CGRect) -> Path {
        var p = Path()
        if pointsRight {
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        } else {
            p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        p.closeSubpath()
        return p
    }
}

/// A horizontal row of the event's provenance/kind marker glyphs (shared by the in-flow month
/// layout and the week/day top-right overlay).
@ViewBuilder private func badgeRow(_ badges: EventBadges, _ color: Color) -> some View {
    HStack(spacing: 2) {
        ForEach(badgeSymbols(badges), id: \.self) { sym in
            Image(systemName: sym).font(.system(size: 6.5, weight: .bold))
        }
    }
    .foregroundStyle(color)
}

/// SF Symbol glyphs for an event's provenance/kind markers, in a stable left→right order.
private func badgeSymbols(_ b: EventBadges) -> [String] {
    var s: [String] = []
    if b.contains(.recurrent) { s.append("repeat") }
    if b.contains(.promoted) { s.append("pin.fill") }
    if b.contains(.ai) { s.append("sparkles") }
    if b.contains(.imported) { s.append("square.and.arrow.down") }
    return s
}

/// The per-activation border overlay shared by both stickers: normal solid (focus), dashed
/// (accompanied sibling), thick solid (selected/drawer); nothing for hover/plain.
@ViewBuilder
private func activationBorder(_ activation: EventActivation, color: Color, radius: CGFloat) -> some View {
    switch activation {
    case .selected:
        RoundedRectangle(cornerRadius: radius).strokeBorder(color, lineWidth: BandStyle.selectedBorderWidth)
    case .focusMain:
        RoundedRectangle(cornerRadius: radius).strokeBorder(color, lineWidth: BandStyle.focusBorderWidth)
    case .accompanied:
        RoundedRectangle(cornerRadius: radius).strokeBorder(color, style: StrokeStyle(lineWidth: BandStyle.accompaniedBorderWidth, dash: BandStyle.accompaniedDash))
    case .hover, .plain:
        EmptyView()
    }
}

/// An all-day band: a frosted liquid-glass rounded rect tinted with the event color.
/// Hover fades the fill slightly; single-select adds a thin dotted border; an open
/// drawer (double-click) makes it a solid, thicker border.
private struct BandSticker: View {
    let ev: BandEvent
    let activation: EventActivation
    let editing: Bool
    let gap: CGFloat?        // px to the nearest later-starting bar (title clips before it)
    let clipBox: Bool        // clip title to this box's right edge (shorter same-start bar on top)
    let warn: Bool           // fully-overlapping-events warning (this is the kept band)
    let box: CGSize          // band box size (for scrim geometry)
    var badges: EventBadges = []   // provenance/kind marker glyphs at the bottom of the bar
    var plain: Bool = false  // skip glass while animating (page-turn/pinch) — cheaper per frame
    let theme: Theme

    var body: some View {
        let border = theme.eventBorder(ev.color)
        let color = theme.eventColor(ev.color)
        let r = BandStyle.cornerRadius
        let active = activation.isActive
        let tint = activation.tint * theme.eventTintScale
        let glass: Glass = (active || BandStyle.idleFrosted) ? .regular.tint(color.opacity(tint))
                                                             : .clear.tint(color.opacity(tint))
        let barWidth = activation.accentWide ? BandStyle.accentWidthSelected : BandStyle.accentWidth
        let lead = BandStyle.accentInset + barWidth + BandStyle.barTextGap

        // Only the FOCUSED box (exact click / drawer, or a lone hover) un-truncates to full overflow —
        // NOT the accompanied siblings of a selected series, which stay clipped like normal bars so
        // just the one main title spills. Otherwise: a shorter same-start bar (on top) clips to its
        // own box; everyone else clips before the next later bar (unbounded when none).
        let expanded = activation.expandsTitle
        let clip: CGFloat? = expanded ? nil
            : (clipBox ? max(0, box.width - lead - BandStyle.titleTrailing) : gap.map { max(12, $0 - 10) })
        // Spill scrim (focused box only): the part of the full title past the box's right edge, when
        // it overruns something behind it — a longer same-start bar (clipBox) or a later bar.
        // A dark plate occludes that bar's text so the spilled title stays readable.
        let titleEnd = lead + Self.titleWidth(ev.title)
        let spill = max(0, titleEnd + 9 - box.width)
        let maskW: CGFloat = (expanded && spill > 0 && (clipBox || (gap != nil && gap! < titleEnd))) ? spill : 0

        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .eventSurface(glass, plainFill: color.opacity(tint), in: RoundedRectangle(cornerRadius: r), flat: plain && !active, keepFillBase: plain)
            // Spill scrim: a frosted plate of THIS event's color that sits UNDER the box, shares its
            // two left corners (same radius), and extends right to cover the full un-truncated title.
            // Under the box it's hidden by the glass; past the box it occludes the bar behind the
            // spill. A single rounded rect → no triangular gap at the box's rounded right corner.
            .background(alignment: .leading) {
                if maskW > 0 {
                    let shape = RoundedRectangle(cornerRadius: r)
                    Rectangle().fill(theme.bg.opacity(0.55))   // base occlusion under the frost
                        .frame(width: box.width + maskW, height: box.height)
                        .glassEffect(.regular.tint(color.opacity(BandStyle.tintIdle * theme.eventTintScale)), in: shape)
                        .clipShape(shape)
                }
            }
            .overlay(alignment: .leading) {   // accent bar
                Capsule().fill(border).frame(width: barWidth)
                    .padding(.vertical, BandStyle.accentInset).padding(.leading, BandStyle.accentInset)
            }
            .overlay(alignment: .leading) {   // markers (top) + title, as one vertically-centered block
                if !editing {
                    VStack(alignment: .leading, spacing: -3) {   // negative → pull the title up tight under the icons
                        if !badges.isEmpty {
                            HStack(spacing: 2) {
                                ForEach(badgeSymbols(badges), id: \.self) { sym in
                                    Image(systemName: sym).font(.system(size: 6.5, weight: .bold))
                                }
                            }
                            .foregroundStyle(border)
                        }
                        titleView(clip: clip)
                    }
                    .padding(.leading, lead)
                    .allowsHitTesting(false)
                }
            }
            .overlay { activationBorder(activation, color: border, radius: r) }   // level-specific border
            .overlay(alignment: .topLeading) { // fully-overlapping warning
                if warn {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.yellow)
                        .padding(.leading, 2).padding(.top, 1)
                        .help("Fully overlapping events")
                }
            }
            .animation(.easeInOut(duration: BandStyle.animation), value: activation)
    }

    @ViewBuilder private func titleView(clip: CGFloat?) -> some View {
        let t = Text(ev.title)
            .font(.custom("Comic Sans MS", size: BandStyle.titleSize))
            .foregroundStyle(theme.text)
            .lineLimit(1)
        if let clip { t.truncationMode(.tail).frame(width: clip, alignment: .leading) }
        else { t.fixedSize() }
    }

    static func titleWidth(_ s: String) -> CGFloat {
        let f = NSFont(name: "Comic Sans MS", size: BandStyle.titleSize) ?? NSFont.systemFont(ofSize: BandStyle.titleSize)
        return (s as NSString).size(withAttributes: [.font: f]).width
    }
}

/// Clips content to an absolute rectangle in the parent's coordinate space.
struct RectClip: Shape {
    let rect: CGRect
    func path(in _: CGRect) -> Path { Path(rect) }
}
