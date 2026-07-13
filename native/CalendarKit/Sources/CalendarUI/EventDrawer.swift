// Detail drawer — right-side glass panel, resizable, sliding in from the right.
// Top section mirrors the web's EventDrawerShell: a borderless handwriting title as
// the header row, a small close-X in the corner, a dashed-separated label-less
// "when" row, then the color swatch row, then a divider. Handles all three item
// kinds (timed event, all-day band, deadline).

import SwiftUI
import CalendarGeometry
import CalendarEngine

@MainActor
@Observable
public final class CalendarUIState {
    public var openEventId: String?
    public var editingTrack: TrackEdit?   // inline track-name editor target
    public init() {}
}

/// Target for the inline track-name editor: which month + track, and where (geometry rect).
public struct TrackEdit: Equatable { public var month: Int; public var track: Int; public var rect: CGRect }

private enum ItemKind2 { case timed, band, deadline }

struct EventDrawer: View {
    let engine: CalendarEngine
    let id: String
    @Binding var width: CGFloat
    let theme: Theme
    let onClose: () -> Void

    @State private var kind: ItemKind2 = .timed
    @State private var title = ""
    @State private var color = "blue"
    @State private var month = 0
    @State private var start: CGFloat = 9
    @State private var end: CGFloat = 10
    @State private var startDay = 1
    @State private var endDay = 1
    @State private var track = 0
    @State private var day = 1
    @State private var hour: CGFloat = 12
    @State private var resizeStart: CGFloat?

    private let base = Calendar.current.startOfDay(for: Date())

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title as the header row (borderless handwriting).
            TextField("Untitled", text: $title)
                .textFieldStyle(.plain)
                .font(.custom("Comic Sans MS", size: 19).weight(.bold))
                .foregroundStyle(theme.text)
                .padding(.trailing, 26)
                .padding(.bottom, 8)
                .onChange(of: title) { _, v in commitTitle(v) }

            // "When" row — label-less, dashed separator above (like .cc-dw-row).
            whenRow
                .frame(minHeight: 30)
                .padding(.vertical, 6)
                .overlay(alignment: .top) { dashed }

            // Color swatches — no separator, snug under the when row.
            HStack(spacing: 9) {
                ForEach(EVENT_COLORS, id: \.self) { key in
                    Circle()
                        .fill(theme.eventBorder(key))
                        .frame(width: 17, height: 17)
                        .overlay(Circle().strokeBorder(theme.text, lineWidth: key == color ? 2 : 0))
                        .contentShape(Circle())
                        .onTapGesture { color = key; commitColor(key) }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 10)

            Rectangle().fill(theme.text.opacity(0.18)).frame(height: 1)   // .cc-dw-divider

            if kind == .band {
                configRow("Lane") {
                    Picker("", selection: $track) {
                        ForEach(0..<4, id: \.self) { Text("T\($0 + 1)").tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .onChange(of: track) { _, v in engine.updateBand(id) { $0.track = v } }
                }
            }

            Spacer(minLength: 0)

            Button(role: .destructive) { engine.remove(id); onClose() } label: {
                Label("Delete", systemImage: "trash").font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.eventBorder("red"))
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .frame(width: width, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
                .padding(10)
        }
        .overlay(alignment: .leading) { resizeHandle }
        .overlay(alignment: .leading) { Rectangle().fill(theme.text.opacity(0.25)).frame(width: 1) }
        .onAppear(perform: load)
        .id(id)
    }

    // ── When row per kind ─────────────────────────────────────────────────────────
    @ViewBuilder private var whenRow: some View {
        switch kind {
        case .timed:
            HStack(spacing: 8) {
                DatePicker("", selection: hourBinding($start) { s in engine.update(id) { $0.startHour = s; if $0.endHour <= s { $0.endHour = min(24, s + 0.5); end = $0.endHour } } }, displayedComponents: .hourAndMinute).labelsHidden()
                Text("–").foregroundStyle(.secondary)
                DatePicker("", selection: hourBinding($end) { e in engine.update(id) { $0.endHour = max(start + 0.25, e) } }, displayedComponents: .hourAndMinute).labelsHidden()
                Spacer(minLength: 0)
            }
        case .band:
            HStack(spacing: 6) {
                dayStepper($startDay) { startDay = min(startDay, endDay); engine.updateBand(id) { $0.startDay = startDay } }
                Text("–").foregroundStyle(.secondary)
                dayStepper($endDay) { endDay = max(startDay, endDay); engine.updateBand(id) { $0.endDay = endDay } }
                Spacer(minLength: 0)
            }
        case .deadline:
            HStack(spacing: 8) {
                dayStepper($day) { engine.updateDeadline(id) { $0.day = day } }
                DatePicker("", selection: hourBinding($hour) { h in engine.updateDeadline(id) { $0.hour = h } }, displayedComponents: .hourAndMinute).labelsHidden()
                Spacer(minLength: 0)
            }
        }
    }

    private func dayStepper(_ value: Binding<Int>, _ commit: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text("\(MONTH_NAMES[month]) \(value.wrappedValue)").font(.callout.monospacedDigit())
            Stepper("", value: value, in: 1...daysInMonth(engine.year, month)).labelsHidden()
                .onChange(of: value.wrappedValue) { _, _ in commit() }
        }
    }

    @ViewBuilder private func configRow<Content: View>(_ name: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Text(name.uppercased()).font(.caption2).tracking(0.8).foregroundStyle(.secondary)
            Spacer()
            content().frame(width: 150)
        }
        .padding(.vertical, 10)
    }

    private var dashed: some View {
        GeometryReader { g in
            Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: g.size.width, y: 0)) }
                .stroke(theme.text.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .frame(height: 1)
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 7)
            .contentShape(Rectangle())
            .onHover { $0 ? NSCursor.resizeLeftRight.set() : NSCursor.arrow.set() }
            .gesture(
                DragGesture()
                    .onChanged { v in
                        let s = resizeStart ?? width
                        if resizeStart == nil { resizeStart = width }
                        width = min(760, max(300, s - v.translation.width))
                    }
                    .onEnded { _ in resizeStart = nil }
            )
    }

    // ── Hour ↔ Date binding for the compact time pickers ─────────────────────────
    private func hourBinding(_ h: Binding<CGFloat>, commit: @escaping (CGFloat) -> Void) -> Binding<Date> {
        Binding(
            get: {
                let hh = min(23, Int(h.wrappedValue))
                let mm = Int((h.wrappedValue - floor(h.wrappedValue)) * 60)
                return Calendar.current.date(bySettingHour: hh, minute: mm, second: 0, of: base) ?? base
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                let nv = CGFloat(c.hour ?? 0) + CGFloat(c.minute ?? 0) / 60
                h.wrappedValue = nv
                commit(nv)
            }
        )
    }

    // ── Load + commit ─────────────────────────────────────────────────────────────
    private func load() {
        if let e = engine.event(id) {
            kind = .timed; title = e.title; color = e.color; month = e.month; start = e.startHour; end = e.endHour
        } else if let b = engine.band(id) {
            kind = .band; title = b.title; color = b.color; month = b.month; startDay = b.startDay; endDay = b.endDay; track = b.track
        } else if let d = engine.deadline(id) {
            kind = .deadline; title = d.title; color = d.color; month = d.month; day = d.day; hour = d.hour
        } else { onClose() }
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
}
