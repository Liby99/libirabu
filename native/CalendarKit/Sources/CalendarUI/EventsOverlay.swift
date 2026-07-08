// Timed + band events as real SwiftUI views layered over the Canvas — so each
// sticker's translucent fill sits over a genuine frosted-glass backdrop blur
// (.ultraThinMaterial), the native analogue of the web's `backdrop-filter: blur`.
// Visual only; gestures are handled by the AppKit input bridge above it.

import SwiftUI
import CalendarGeometry

struct EventsOverlay: View {
    let input: SceneInput
    let events: [TimedEvent]
    let bands: [BandEvent]
    let selected: String?
    let theme: Theme

    var body: some View {
        let tl = timelineInfo(input)
        let f = frameFor(input.focus, input)
        // Right clip edge: full width, or the chosen day's right edge in daily view
        // (so events/bands don't show through the dashboard panel).
        let clipRight = input.z > 2 ? f.x0 + CGFloat(input.daily.dom) * f.dayW : input.vp.w
        let bandClip = CGRect(x: Layout.labelW, y: 0, width: max(0, clipRight - Layout.labelW), height: input.vp.h)
        let tlClip = CGRect(x: Layout.labelW, y: tl.tlTop, width: max(0, clipRight - Layout.labelW), height: max(0, tl.tlBottom - tl.tlTop))

        ZStack(alignment: .topLeading) {
            // band events — on the track lanes, visible at every zoom
            stickers(bandItems()).clipShape(RectClip(rect: bandClip))
            // timed events — on the day-detail timeline
            if tl.reveal > 0.05 && tl.hourH > 0 {
                stickers(timedItems(tl)).clipShape(RectClip(rect: tlClip))
            }
        }
        .allowsHitTesting(false)
    }

    private struct Item2 { let rect: CGRect; let fade: Double; let view: AnyView }

    @ViewBuilder private func stickers(_ items: [Item2]) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                it.view
                    .frame(width: it.rect.width, height: it.rect.height)
                    .position(x: it.rect.midX, y: it.rect.midY)
                    .opacity(it.fade)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func bandItems() -> [Item2] {
        bands.compactMap { b in
            guard let r = bandEventRect(b, input, anim: input.monthAnim) else { return nil }
            let f = frameFor(b.month, input, anim: input.monthAnim)
            return Item2(rect: CGRect(x: r.x, y: r.y, width: r.w, height: r.h),
                         fade: Double(f.opacity),
                         view: AnyView(BandSticker(ev: b, selected: b.id == selected, theme: theme)))
        }
    }

    private func timedItems(_ tl: TimelineInfo) -> [Item2] {
        var byDay: [Int: [TimedEvent]] = [:]
        for e in events {
            if let rd = relDomOf(input.focus, e.month, e.day) { byDay[rd, default: []].append(e) }
        }
        var out: [Item2] = []
        for (rd, evs) in byDay {
            let fade = dailyFade(rd, input) * tl.reveal
            if fade <= 0.02 { continue }
            let layout = layoutDay(evs)
            for e in evs {
                guard let r = eventRect(e, input.focus, tl, input.vp, layout[e.id]) else { continue }
                let rect = CGRect(x: r.minX, y: tl.tlTop - tl.scroll + r.minY, width: r.width, height: r.height)
                if rect.maxY < tl.tlTop || rect.minY > tl.tlBottom { continue }
                out.append(Item2(rect: rect, fade: Double(fade),
                                 view: AnyView(EventSticker(ev: e, height: rect.height, selected: e.id == selected, theme: theme))))
            }
        }
        return out
    }
}

/// A timed-event sticker — two layers (.cc-tevent): frosted material + translucent
/// tint, an inner box with a colored left accent bar, a handwriting title + time.
private struct EventSticker: View {
    let ev: TimedEvent
    let height: CGFloat
    let selected: Bool
    let theme: Theme

    var body: some View {
        let lay = eventTextLayout(height)
        let border = theme.eventBorder(ev.color)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 7).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 7).fill(theme.eventFill(ev.color))
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
            if selected {
                RoundedRectangle(cornerRadius: 7).strokeBorder(border, lineWidth: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .shadow(color: .black.opacity(selected ? 0.28 : 0), radius: selected ? 6 : 0, y: selected ? 3 : 0)
    }
}

/// An all-day band sticker — same material treatment, title vertically centered.
private struct BandSticker: View {
    let ev: BandEvent
    let selected: Bool
    let theme: Theme

    var body: some View {
        let border = theme.eventBorder(ev.color)
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 6).fill(theme.eventFill(ev.color))
            HStack(spacing: 0) {
                Rectangle().fill(border).frame(width: selected ? 3 : 1)
                Text(ev.title)
                    .font(.custom("Comic Sans MS", size: 12))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .padding(.leading, 4)
                    .padding(.trailing, 6)
                Spacer(minLength: 0)
            }
            .padding(2)
            if selected {
                RoundedRectangle(cornerRadius: 6).strokeBorder(border, lineWidth: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Clips content to an absolute rectangle in the parent's coordinate space.
struct RectClip: Shape {
    let rect: CGRect
    func path(in _: CGRect) -> Path { Path(rect) }
}
