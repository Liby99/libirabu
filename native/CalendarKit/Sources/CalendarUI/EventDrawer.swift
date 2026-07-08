// Detail drawer — a right-side glass panel to edit the double-clicked item. Handles
// all three kinds (timed event, all-day band, deadline), showing the fields each
// needs. Lives outside the per-frame TimelineView (so its TextField keeps focus);
// edits commit straight to the engine, which the Canvas reflects each frame.

import SwiftUI
import CalendarGeometry
import CalendarEngine

@MainActor
@Observable
public final class CalendarUIState {
    public var openEventId: String?
    public init() {}
}

private enum ItemKind2 { case timed, band, deadline }

struct EventDrawer: View {
    let engine: CalendarEngine
    let id: String
    let theme: Theme
    let onClose: () -> Void

    @State private var kind: ItemKind2 = .timed
    @State private var title = ""
    @State private var color = "blue"
    @State private var month = 0
    // timed
    @State private var start: CGFloat = 9
    @State private var end: CGFloat = 10
    // band
    @State private var startDay = 1
    @State private var endDay = 1
    @State private var track = 0
    // deadline
    @State private var day = 1
    @State private var hour: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(heading).font(.title3.weight(.semibold))
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }

            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.custom("Comic Sans MS", size: 15))
                .onChange(of: title) { _, v in commitTitle(v) }

            VStack(alignment: .leading, spacing: 7) {
                label("Color")
                HStack(spacing: 9) {
                    ForEach(EVENT_COLORS, id: \.self) { key in
                        Circle()
                            .fill(theme.eventBorder(key))
                            .frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(theme.text, lineWidth: key == color ? 2 : 0))
                            .contentShape(Circle())
                            .onTapGesture { color = key; commitColor(key) }
                    }
                }
            }

            switch kind {
            case .timed:
                section("Time") {
                    timeRow("Start", $start) {
                        engine.update(id) { $0.startHour = start; if $0.endHour <= start { $0.endHour = min(24, start + 0.5); end = $0.endHour } }
                    }
                    timeRow("End", $end) { end = max(start + 0.25, end); engine.update(id) { $0.endHour = end } }
                }
            case .band:
                let dim = daysInMonth(month)
                section("Days") {
                    intRow("Start", $startDay, 1...dim) { startDay = min(startDay, endDay); engine.updateBand(id) { $0.startDay = startDay } }
                    intRow("End", $endDay, 1...dim) { endDay = max(startDay, endDay); engine.updateBand(id) { $0.endDay = endDay } }
                }
                section("Lane") {
                    Picker("", selection: $track) {
                        ForEach(0..<4, id: \.self) { Text("T\($0 + 1)").tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .onChange(of: track) { _, v in engine.updateBand(id) { $0.track = v } }
                }
            case .deadline:
                let dim = daysInMonth(month)
                section("When") {
                    intRow("Day", $day, 1...dim) { engine.updateDeadline(id) { $0.day = day } }
                    timeRow("Time", $hour) { engine.updateDeadline(id) { $0.hour = hour } }
                }
            }

            Spacer()

            Button(role: .destructive) { engine.remove(id); onClose() } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .padding(20)
        .frame(width: 320)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
        .overlay(alignment: .leading) { Rectangle().fill(.separator).frame(width: 1) }
        .onAppear(perform: load)
        .id(id)
    }

    private var heading: String {
        switch kind { case .timed: return "Event"; case .band: return "All-day"; case .deadline: return "Deadline" }
    }

    private func load() {
        if let e = engine.event(id) {
            kind = .timed; title = e.title; color = e.color; month = e.month; start = e.startHour; end = e.endHour
        } else if let b = engine.band(id) {
            kind = .band; title = b.title; color = b.color; month = b.month; startDay = b.startDay; endDay = b.endDay; track = b.track
        } else if let d = engine.deadline(id) {
            kind = .deadline; title = d.title; color = d.color; month = d.month; day = d.day; hour = d.hour
        } else {
            onClose()
        }
    }

    private func commitTitle(_ v: String) {
        switch kind {
        case .timed: engine.update(id) { $0.title = v }
        case .band: engine.updateBand(id) { $0.title = v }
        case .deadline: engine.updateDeadline(id) { $0.title = v }
        }
    }
    private func commitColor(_ v: String) {
        switch kind {
        case .timed: engine.update(id) { $0.color = v }
        case .band: engine.updateBand(id) { $0.color = v }
        case .deadline: engine.updateDeadline(id) { $0.color = v }
        }
    }

    // ── Small view helpers ──────────────────────────────────────────────────────
    private func label(_ s: String) -> some View {
        Text(s.uppercased()).font(.caption2).tracking(0.8).foregroundStyle(.secondary)
    }
    @ViewBuilder private func section<Content: View>(_ name: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { label(name); content() }
    }
    @ViewBuilder private func timeRow(_ name: String, _ value: Binding<CGFloat>, _ commit: @escaping () -> Void) -> some View {
        HStack {
            Text(name).font(.callout).frame(width: 48, alignment: .leading)
            Text(hhmm(value.wrappedValue)).font(.callout.monospacedDigit())
            Spacer()
            Stepper("", value: value, in: 0...24, step: 0.25).labelsHidden()
                .onChange(of: value.wrappedValue) { _, _ in commit() }
        }
    }
    @ViewBuilder private func intRow(_ name: String, _ value: Binding<Int>, _ range: ClosedRange<Int>, _ commit: @escaping () -> Void) -> some View {
        HStack {
            Text(name).font(.callout).frame(width: 48, alignment: .leading)
            Text("\(value.wrappedValue)").font(.callout.monospacedDigit())
            Spacer()
            Stepper("", value: value, in: range).labelsHidden()
                .onChange(of: value.wrappedValue) { _, _ in commit() }
        }
    }
    private func hhmm(_ h: CGFloat) -> String {
        let t = Int((h * 60).rounded()); return String(format: "%02d:%02d", (t / 60) % 24, t % 60)
    }
}
