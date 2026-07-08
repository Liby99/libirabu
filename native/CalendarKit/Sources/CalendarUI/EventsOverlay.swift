// Timed events as real SwiftUI views layered over the Canvas — so each sticker's
// translucent fill sits over a genuine frosted-glass backdrop blur
// (.ultraThinMaterial), the native analogue of the web's `backdrop-filter: blur`.
// This is the "interaction overlay" from the port plan; it's visual only —
// gestures are handled by the AppKit input bridge above it.

import SwiftUI
import CalendarGeometry

struct EventsOverlay: View {
    let input: SceneInput
    let events: [TimedEvent]
    let selected: String?
    let theme: Theme

    var body: some View {
        let tl = timelineInfo(input)
        let visible = tl.reveal > 0.05 && tl.hourH > 0
        // Clip to the visible day area — excludes the gutter (left) and, in daily
        // view, the dashboard panel (right), so events never show through them.
        let f = frameFor(input.focus, input)
        let clipRight = input.z > 2 ? f.x0 + CGFloat(input.daily.dom) * f.dayW : input.vp.w
        let clip = CGRect(x: Layout.labelW, y: tl.tlTop,
                          width: max(0, clipRight - Layout.labelW),
                          height: max(0, tl.tlBottom - tl.tlTop))

        ZStack(alignment: .topLeading) {
            if visible {
                ForEach(placed(tl)) { p in
                    EventSticker(ev: p.ev, height: p.rect.height, selected: p.ev.id == selected, theme: theme)
                        .frame(width: p.rect.width, height: p.rect.height)
                        .position(x: p.rect.midX, y: p.rect.midY)
                        .opacity(p.fade)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipShape(RectClip(rect: clip))
        .allowsHitTesting(false)
    }

    private struct Placed: Identifiable {
        let id: String; let ev: TimedEvent; let rect: CGRect; let fade: Double
    }

    private func placed(_ tl: TimelineInfo) -> [Placed] {
        var byDay: [Int: [TimedEvent]] = [:]
        for e in events {
            if let rd = relDomOf(input.focus, e.month, e.day) { byDay[rd, default: []].append(e) }
        }
        var out: [Placed] = []
        for (rd, evs) in byDay {
            let fade = dailyFade(rd, input) * tl.reveal
            if fade <= 0.02 { continue }
            let layout = layoutDay(evs)
            for e in evs {
                guard let r = eventRect(e, input.focus, tl, input.vp, layout[e.id]) else { continue }
                let rect = CGRect(x: r.minX, y: tl.tlTop - tl.scroll + r.minY, width: r.width, height: r.height)
                if rect.maxY < tl.tlTop || rect.minY > tl.tlBottom { continue }
                out.append(Placed(id: e.id, ev: e, rect: rect, fade: Double(fade)))
            }
        }
        return out
    }
}

/// One event sticker — two layers (.cc-tevent): frosted material + translucent tint,
/// an inner box with a colored left accent bar, a handwriting title + time range.
private struct EventSticker: View {
    let ev: TimedEvent
    let height: CGFloat
    let selected: Bool
    let theme: Theme

    var body: some View {
        let lay = eventTextLayout(height)
        let border = theme.eventBorder(ev.color)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 7).fill(.ultraThinMaterial)   // backdrop blur
            RoundedRectangle(cornerRadius: 7).fill(theme.eventFill(ev.color)) // translucent tint

            HStack(alignment: .top, spacing: 0) {
                Rectangle().fill(border).frame(width: selected ? 3 : 1)   // left accent bar
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
                RoundedRectangle(cornerRadius: 7).strokeBorder(border, lineWidth: 1)  // solid ring
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .shadow(color: .black.opacity(selected ? 0.28 : 0), radius: selected ? 6 : 0, y: selected ? 3 : 0)
    }
}

/// Clips content to an absolute rectangle in the parent's coordinate space.
struct RectClip: Shape {
    let rect: CGRect
    func path(in _: CGRect) -> Path { Path(rect) }
}
