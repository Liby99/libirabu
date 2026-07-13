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
    let selected: String?
    let hovered: String?
    let drawerId: String?
    let editingId: String?
    let theme: Theme

    var body: some View {
        let tl = timelineInfo(input)
        let f = frameFor(input.focus, input)
        let clipRight = input.z > 2 ? f.x0 + CGFloat(input.daily.dom) * f.dayW : input.vp.w
        let bandClip = CGRect(x: Layout.labelW, y: 0, width: max(0, clipRight - Layout.labelW), height: input.vp.h)
        let tlClip = CGRect(x: Layout.labelW, y: tl.tlTop, width: max(0, clipRight - Layout.labelW), height: max(0, tl.tlBottom - tl.tlTop))

        ZStack(alignment: .topLeading) {
            stickers(bandItems()).clipShape(RectClip(rect: bandClip))
            if tl.reveal > 0.05 && tl.hourH > 0 {
                stickers(timedItems(tl)).clipShape(RectClip(rect: tlClip))
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
        }
        .allowsHitTesting(false)
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

    private func bandItems() -> [Item2] {
        var placed: [(ev: BandEvent, rect: CGRect, fade: Double)] = []
        for b in bands {
            guard let r = bandEventRect(b, input, anim: input.monthAnim) else { continue }
            let f = frameFor(b.month, input, anim: input.monthAnim)
            placed.append((b, CGRect(x: r.x, y: r.y, width: r.w, height: r.h), Double(f.opacity)))
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
        for (i, p) in placed.enumerated() where !hidden.contains(p.ev.id) { byLane["\(p.ev.month)-\(p.ev.track)", default: []].append(i) }
        for (_, idxs) in byLane {
            for i in idxs {
                let laterMinX = idxs.filter { placed[$0].ev.startDay > placed[i].ev.startDay }.map { placed[$0].rect.minX }.min()
                if let lx = laterMinX { gapBy[placed[i].ev.id] = lx - placed[i].rect.minX }
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
            let z: Double = id == drawerId ? 1001 : (id == selected ? 1000 : (id == hovered ? 950 : (zBy[id] ?? Double(10 + p.ev.startDay))))
            return Item2(id: id, rect: p.rect, fade: p.fade, z: z, view: AnyView(
                BandSticker(ev: p.ev, hovered: id == hovered, selected: id == selected,
                            drawerOpen: id == drawerId, editing: id == editingId,
                            gap: gapBy[id], clipBox: clipBox.contains(id), warn: warn.contains(id),
                            box: p.rect.size, theme: theme)))
        }
    }

    private func timedItems(_ tl: TimelineInfo) -> [Item2] {
        var byDay: [Int: [TimedEvent]] = [:]
        for e in events {
            if let rd = relDomOf(input.year, input.focus, e.month, e.day) { byDay[rd, default: []].append(e) }
        }
        var placed: [(ev: TimedEvent, rect: CGRect, fade: Double)] = []
        for (rd, evs) in byDay {
            let fade = dailyFade(rd, input) * tl.reveal
            if fade <= 0.02 { continue }
            let layout = layoutDay(evs)
            for e in evs {
                guard let r = eventRect(e, input.year, input.focus, tl, input.vp, layout[e.id]) else { continue }
                let rect = CGRect(x: r.minX, y: tl.tlTop - tl.scroll + r.minY, width: r.width, height: r.height)
                if rect.maxY < tl.tlTop || rect.minY > tl.tlBottom { continue }
                placed.append((e, rect, Double(fade)))
            }
        }
        placed.sort(by: orderTimed)
        return placed.enumerated().map { i, p in
            let z: Double = p.ev.id == selected ? 1000 : (p.ev.id == hovered ? 950 : Double(i))
            return Item2(id: p.ev.id, rect: p.rect, fade: p.fade, z: z, view: AnyView(EventSticker(ev: p.ev, height: p.rect.height, selected: p.ev.id == selected, theme: theme)))
        }
    }

    // Draw order: later-starting events in front; the selected one always frontmost.
    private func orderTimed(_ a: (ev: TimedEvent, rect: CGRect, fade: Double), _ b: (ev: TimedEvent, rect: CGRect, fade: Double)) -> Bool {
        let sa = a.ev.id == selected, sb = b.ev.id == selected
        if sa != sb { return sb }                                  // selected sorts last (front)
        if a.ev.startHour != b.ev.startHour { return a.ev.startHour < b.ev.startHour }
        return a.ev.endHour > b.ev.endHour
    }
}

/// A timed-event glass sticker — a colored left accent bar + handwriting title + time.
private struct EventSticker: View {
    let ev: TimedEvent
    let height: CGFloat
    let selected: Bool
    let theme: Theme

    var body: some View {
        let lay = eventTextLayout(height)
        let border = theme.eventBorder(ev.color)
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(border).frame(width: selected ? 3 : 1)
            VStack(alignment: .leading, spacing: 1) {
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
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 4)
            .padding(.trailing, 6)
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(.regular.tint(border.opacity(0.30)), in: RoundedRectangle(cornerRadius: 7))
        .overlay { if selected { RoundedRectangle(cornerRadius: 7).strokeBorder(border, lineWidth: 1) } }
        .shadow(color: .black.opacity(selected ? 0.26 : 0), radius: selected ? 6 : 0, y: selected ? 3 : 0)
    }
}

/// An all-day band: a frosted liquid-glass rounded rect tinted with the event color.
/// Hover fades the fill slightly; single-select adds a thin dotted border; an open
/// drawer (double-click) makes it a solid, thicker border.
private struct BandSticker: View {
    let ev: BandEvent
    let hovered: Bool
    let selected: Bool
    let drawerOpen: Bool
    let editing: Bool
    let gap: CGFloat?        // px to the nearest later-starting bar (title clips before it)
    let clipBox: Bool        // clip title to this box's right edge (shorter same-start bar on top)
    let warn: Bool           // fully-overlapping-events warning (this is the kept band)
    let box: CGSize          // band box size (for scrim geometry)
    let theme: Theme

    var body: some View {
        let border = theme.eventBorder(ev.color)
        let color = theme.eventColor(ev.color)
        let r = BandStyle.cornerRadius
        let active = hovered || selected || drawerOpen
        let tint = (selected || drawerOpen) ? BandStyle.tintSelected
                 : (hovered ? BandStyle.tintHovered : BandStyle.tintIdle)
        let glass: Glass = (active || BandStyle.idleFrosted) ? .regular.tint(color.opacity(tint))
                                                             : .clear.tint(color.opacity(tint))
        let barWidth = selected ? BandStyle.accentWidthSelected : BandStyle.accentWidth
        let lead = BandStyle.accentInset + barWidth + BandStyle.barTextGap

        // Hover un-truncates to full overflow. Otherwise: a shorter same-start bar (on top)
        // clips to its own box so its title doesn't spill over the longer bar behind it;
        // everyone else clips before the next later bar (unbounded when none).
        let clip: CGFloat? = hovered ? nil
            : (clipBox ? max(0, box.width - lead - BandStyle.titleTrailing) : gap.map { max(12, $0 - 10) })
        // Spill scrim (hover only): only the part of the full title past the box's right edge,
        // and only when it overruns the next bar. Height = full box height.
        let titleEnd = lead + Self.titleWidth(ev.title)
        let maskW: CGFloat = (hovered && gap != nil && gap! < titleEnd) ? max(0, titleEnd + 9 - box.width) : 0

        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassEffect(glass, in: RoundedRectangle(cornerRadius: r))
            .overlay(alignment: .leading) {   // accent bar
                Capsule().fill(border).frame(width: barWidth)
                    .padding(.vertical, BandStyle.accentInset).padding(.leading, BandStyle.accentInset)
            }
            .overlay(alignment: .leading) {   // spill scrim (behind the title)
                if maskW > 0 {
                    UnevenRoundedRectangle(bottomTrailingRadius: 5, topTrailingRadius: 5)
                        .fill(.regularMaterial)
                        .frame(width: maskW, height: box.height)
                        .offset(x: box.width)
                }
            }
            .overlay(alignment: .leading) {   // title (renders full; covered by any bar on top)
                if !editing { titleView(clip: clip).padding(.leading, lead) }
            }
            .overlay {                          // selection / drawer border
                if drawerOpen {
                    RoundedRectangle(cornerRadius: r).strokeBorder(border, lineWidth: BandStyle.drawerBorderWidth)
                } else if selected {
                    RoundedRectangle(cornerRadius: r).strokeBorder(border, style: StrokeStyle(lineWidth: BandStyle.selectedBorderWidth, dash: BandStyle.selectedDash))
                }
            }
            .overlay(alignment: .topLeading) { // fully-overlapping warning
                if warn {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.yellow)
                        .padding(.leading, 2).padding(.top, 1)
                        .help("Fully overlapping events")
                }
            }
            .animation(.easeInOut(duration: BandStyle.animation), value: [hovered, selected, drawerOpen])
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
