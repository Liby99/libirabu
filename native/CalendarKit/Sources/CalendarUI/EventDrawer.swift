// Event detail drawer — a right-side glass panel to edit an event's title, color,
// and times. Lives outside the per-frame TimelineView (so its TextField keeps focus
// and state); edits commit straight to the engine, which the Canvas reflects each
// frame. Which event is open is held in an @Observable UI-state object.

import SwiftUI
import CalendarGeometry
import CalendarEngine

@MainActor
@Observable
public final class CalendarUIState {
    public var openEventId: String?
    public init() {}
}

struct EventDrawer: View {
    let engine: CalendarEngine
    let id: String
    let theme: Theme
    let onClose: () -> Void

    @State private var title = ""
    @State private var color = "blue"
    @State private var start: CGFloat = 9
    @State private var end: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Event").font(.title3.weight(.semibold))
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }

            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.custom("Comic Sans MS", size: 15))
                .onChange(of: title) { _, v in engine.update(id) { $0.title = v } }

            VStack(alignment: .leading, spacing: 7) {
                label("Color")
                HStack(spacing: 9) {
                    ForEach(EVENT_COLORS, id: \.self) { key in
                        Circle()
                            .fill(theme.eventBorder(key))
                            .frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(theme.text, lineWidth: key == color ? 2 : 0))
                            .contentShape(Circle())
                            .onTapGesture { color = key; engine.update(id) { $0.color = key } }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                label("Time")
                timeRow("Start", $start) {
                    engine.update(id) {
                        $0.startHour = start
                        if $0.endHour <= start { $0.endHour = min(24, start + 0.5); end = $0.endHour }
                    }
                }
                timeRow("End", $end) {
                    end = max(start + 0.25, end)
                    engine.update(id) { $0.endHour = end }
                }
            }

            Spacer()

            Button(role: .destructive) { engine.remove(id); onClose() } label: {
                Label("Delete Event", systemImage: "trash")
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

    private func load() {
        guard let e = engine.event(id) else { onClose(); return }
        title = e.title; color = e.color; start = e.startHour; end = e.endHour
    }

    private func label(_ s: String) -> some View {
        Text(s.uppercased()).font(.caption2).tracking(0.8).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func timeRow(_ name: String, _ value: Binding<CGFloat>, _ commit: @escaping () -> Void) -> some View {
        HStack {
            Text(name).font(.callout).frame(width: 44, alignment: .leading)
            Text(hhmm(value.wrappedValue)).font(.callout.monospacedDigit())
            Spacer()
            Stepper("", value: value, in: 0...24, step: 0.25)
                .labelsHidden()
                .onChange(of: value.wrappedValue) { _, _ in commit() }
        }
    }

    private func hhmm(_ h: CGFloat) -> String {
        let t = Int((h * 60).rounded()); return String(format: "%02d:%02d", (t / 60) % 24, t % 60)
    }
}
