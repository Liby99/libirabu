// Timed + band events as real SwiftUI views layered over the Canvas — each sticker
// is Liquid Glass (.glassEffect), so overlapping events are genuinely translucent
// and blur what's behind them (the native analogue of the web's translucent fill +
// backdrop-filter). Visual only; gestures are handled by the AppKit input bridge.

import SwiftUI
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
        // Per-lane (month+track) gap-clip: a title runs freely into empty cells but truncates
        // ~10px before the next-starting bar. No later bar → unbounded overflow.
        var titleMax: [String: CGFloat] = [:]
        var byLane: [String: [Int]] = [:]
        for (i, p) in placed.enumerated() { byLane["\(p.ev.month)-\(p.ev.track)", default: []].append(i) }
        for (_, idxs) in byLane {
            let sorted = idxs.sorted { placed[$0].ev.startDay < placed[$1].ev.startDay }
            for j in sorted.indices where j + 1 < sorted.count {
                let gap = placed[sorted[j + 1]].rect.minX - placed[sorted[j]].rect.minX
                titleMax[placed[sorted[j]].ev.id] = max(12, gap - 10)
            }
        }
        return placed.map { p in
            let id = p.ev.id
            let active = id == hovered || id == selected || id == drawerId
            let z: Double = id == drawerId ? 1001 : (id == selected ? 1000 : (id == hovered ? 950 : Double(10 + p.ev.startDay)))
            return Item2(id: id, rect: p.rect, fade: p.fade, z: z, view: AnyView(
                BandSticker(ev: p.ev, hovered: id == hovered, selected: id == selected,
                            drawerOpen: id == drawerId, editing: id == editingId,
                            titleMax: active ? nil : titleMax[id], theme: theme)))
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
    let titleMax: CGFloat?   // width cap before the next bar; nil = overflow full width
    let theme: Theme

    var body: some View {
        let border = theme.eventBorder(ev.color)
        let color = theme.eventColor(ev.color)   // saturated hue at full opacity
        let r = BandStyle.cornerRadius
        let active = hovered || selected || drawerOpen
        let tint = (selected || drawerOpen) ? BandStyle.tintSelected
                 : (hovered ? BandStyle.tintHovered : BandStyle.tintIdle)
        let glass: Glass = (active || BandStyle.idleFrosted) ? .regular.tint(color.opacity(tint))
                                                             : .clear.tint(color.opacity(tint))
        let barWidth = selected ? BandStyle.accentWidthSelected : BandStyle.accentWidth
        let titleLeading = BandStyle.accentInset + barWidth + BandStyle.barTextGap
        // The glass box fills the band rect; the title is a separate overlay that can
        // overflow to the right (into empty cells), truncating before the next bar.
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassEffect(glass, in: RoundedRectangle(cornerRadius: r))
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(border)
                    .frame(width: barWidth)
                    .padding(.vertical, BandStyle.accentInset)
                    .padding(.leading, BandStyle.accentInset)
            }
            .overlay {
                if drawerOpen {
                    RoundedRectangle(cornerRadius: r).strokeBorder(border, lineWidth: BandStyle.drawerBorderWidth)
                } else if selected {
                    RoundedRectangle(cornerRadius: r).strokeBorder(border, style: StrokeStyle(lineWidth: BandStyle.selectedBorderWidth, dash: BandStyle.selectedDash))
                }
            }
            .overlay(alignment: .leading) {
                if !editing { titleView.padding(.leading, titleLeading) }
            }
            .animation(.easeInOut(duration: BandStyle.animation), value: [hovered, selected, drawerOpen])
    }

    // The title: capped to titleMax (ellipsis) when there's a next bar; full-width
    // (overflows the box) otherwise or when active. A frosted plate on hover keeps the
    // spilled text legible over whatever's behind it.
    @ViewBuilder private var titleView: some View {
        let t = Text(ev.title)
            .font(.custom("Comic Sans MS", size: BandStyle.titleSize))
            .foregroundStyle(theme.text)
            .lineLimit(1)
        Group {
            if let max = titleMax { t.truncationMode(.tail).frame(width: max, alignment: .leading) }
            else { t.fixedSize() }
        }
        .padding(.trailing, BandStyle.titleTrailing)
        .background {
            if hovered {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.regularMaterial)
                    .padding(.vertical, 1).padding(.horizontal, -3)
            }
        }
    }
}

/// Clips content to an absolute rectangle in the parent's coordinate space.
struct RectClip: Shape {
    let rect: CGRect
    func path(in _: CGRect) -> Path { Path(rect) }
}
