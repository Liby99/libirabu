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

    private struct Item2: Identifiable { let id: String; let rect: CGRect; let fade: Double; let view: AnyView }

    @ViewBuilder private func stickers(_ items: [Item2]) -> some View {
        ZStack(alignment: .topLeading) {
            // Stable identity (event id) so a z-order re-sort keeps the view alive and its
            // hover/select transitions can animate rather than snapping.
            ForEach(items) { it in
                it.view
                    .frame(width: it.rect.width, height: it.rect.height)
                    .position(x: it.rect.midX, y: it.rect.midY)
                    .opacity(it.fade)
                    .zIndex(zOf(it.id))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    // Draw order via zIndex (selected/hovered on top) since ForEach is id-ordered now.
    private func zOf(_ id: String) -> Double { id == selected ? 2 : (id == hovered ? 1 : 0) }

    private func bandItems() -> [Item2] {
        var placed: [(ev: BandEvent, rect: CGRect, fade: Double)] = []
        for b in bands {
            guard let r = bandEventRect(b, input, anim: input.monthAnim) else { continue }
            let f = frameFor(b.month, input, anim: input.monthAnim)
            placed.append((b, CGRect(x: r.x, y: r.y, width: r.w, height: r.h), Double(f.opacity)))
        }
        placed.sort(by: orderBands)
        return placed.map { Item2(id: $0.ev.id, rect: $0.rect, fade: $0.fade, view: AnyView(
            BandSticker(ev: $0.ev, hovered: $0.ev.id == hovered, selected: $0.ev.id == selected,
                        drawerOpen: $0.ev.id == drawerId, theme: theme))) }
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
        return placed.map { Item2(id: $0.ev.id, rect: $0.rect, fade: $0.fade, view: AnyView(EventSticker(ev: $0.ev, height: $0.rect.height, selected: $0.ev.id == selected, theme: theme))) }
    }

    // Draw order: later-starting events in front; the selected one always frontmost.
    private func orderTimed(_ a: (ev: TimedEvent, rect: CGRect, fade: Double), _ b: (ev: TimedEvent, rect: CGRect, fade: Double)) -> Bool {
        let sa = a.ev.id == selected, sb = b.ev.id == selected
        if sa != sb { return sb }                                  // selected sorts last (front)
        if a.ev.startHour != b.ev.startHour { return a.ev.startHour < b.ev.startHour }
        return a.ev.endHour > b.ev.endHour
    }
    private func orderBands(_ a: (ev: BandEvent, rect: CGRect, fade: Double), _ b: (ev: BandEvent, rect: CGRect, fade: Double)) -> Bool {
        let sa = a.ev.id == selected, sb = b.ev.id == selected
        if sa != sb { return sb }
        return a.ev.startDay < b.ev.startDay
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
    let theme: Theme

    var body: some View {
        let border = theme.eventBorder(ev.color)
        let radius: CGFloat = 9
        let active = hovered || selected || drawerOpen   // frosted when engaged, else clear
        Text(ev.title)
            .font(.custom("Comic Sans MS", size: 12))
            .foregroundStyle(theme.text)
            .lineLimit(1)
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .glassEffect(active ? .regular.tint(border.opacity(0.34)) : .clear.tint(border.opacity(0.24)),
                         in: RoundedRectangle(cornerRadius: radius))
            // Left accent bar: rounded, inset 6px from left/top/bottom; thicker when selected.
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(border)
                    .frame(width: selected ? 3 : 2)
                    .padding(.vertical, 6)
                    .padding(.leading, 6)
            }
            .overlay {
                if drawerOpen {
                    RoundedRectangle(cornerRadius: radius).strokeBorder(border, lineWidth: 2)
                } else if selected {
                    RoundedRectangle(cornerRadius: radius).strokeBorder(border, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
            }
            .animation(.easeInOut(duration: 0.18), value: [hovered, selected, drawerOpen])
    }
}

/// Clips content to an absolute rectangle in the parent's coordinate space.
struct RectClip: Shape {
    let rect: CGRect
    func path(in _: CGRect) -> Path { Path(rect) }
}
