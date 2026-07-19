// Read-only detail sheet for a tapped item — the iPhone's stand-in for the Mac's edit drawer.
// Resolves the tapped BOX id against the display arrays (so recurrence ghosts and promoted
// bars show their occurrence's dates) and reads notes/tags through the source/overlay id,
// exactly like the drawer does. Strictly read-only: no engine mutation besides selection.

import CalendarEngine
import CalendarGeometry
import CalendarRender
import SwiftUI

struct PhoneEventSheet: View {
    let engine: CalendarEngine
    let boxId: String
    let theme: Theme

    var body: some View {
        let d = details()
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle().fill(theme.eventBorder(d.color)).frame(width: 12, height: 12)
                Text(d.title.isEmpty ? "(untitled)" : d.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
            }
            Text(d.when)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !d.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(d.tags, id: \.self) { t in
                        Text("#\(t)")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(theme.eventFill(d.color)))
                    }
                }
            }
            if !d.notes.isEmpty {
                Divider()
                ScrollView {
                    Text(d.notes)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private struct Details {
        var title = ""
        var when = ""
        var color = "red"
        var notes = ""
        var tags: [String] = []
    }

    private func details() -> Details {
        var d = Details()
        let src = sourceId(of: boxId)
        d.notes = engine.notes(src)
        d.tags = engine.richTags(src)
        if let e = engine.viewEvents().first(where: { $0.id == boxId }) {
            d.title = e.title; d.color = e.color
            d.when = "\(MONTH_LONG[e.month]) \(e.day), \(e.year) · \(fmtHourRange(e.startHour, e.endHour))"
        } else if let b = engine.viewBands().first(where: { $0.id == boxId }) {
            d.title = b.title; d.color = b.color
            d.when = b.startDay == b.endDay
                ? "\(MONTH_LONG[b.month]) \(b.startDay), \(b.year) · all day"
                : "\(MONTH_LONG[b.month]) \(b.startDay)–\(b.endDay), \(b.year)"
        } else if let dl = engine.viewDeadlines().first(where: { $0.id == boxId }) {
            d.title = dl.title; d.color = dl.color
            let h = Int(dl.hour), m = Int((dl.hour - CGFloat(h)) * 60)
            d.when = "\(MONTH_LONG[dl.month]) \(dl.day), \(dl.year) · due \(String(format: "%02d:%02d", h, m))"
        }
        return d
    }
}
