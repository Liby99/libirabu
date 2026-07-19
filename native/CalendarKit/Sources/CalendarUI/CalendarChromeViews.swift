// Small chrome views over the calendar canvas: the deadline quick-add "+", the day-view
// timeline↔dashboard split handle, and the Year›Month›Week›Day breadcrumb.
// Split from CalendarView.swift (file diet).

import AppKit
import CalendarEngine
import CalendarGeometry
import SwiftUI

/// Draggable handle on the timeline↔dashboard boundary in day view. Mirrors the drawer's resize
/// handle: a slim capsule that surfaces on hover, with a resize cursor; dragging it adjusts the
/// split (`daily.frac`). Positioned from `engine.daily.frac` each render — during a drag its own
/// `dragFrac` state drives both the position and the engine update, so the handle tracks the cursor
/// even though the engine isn't `@Observable`.
/// The deadline quick-add "+" affordance: a small circle with a plus, matching the calendar's cursor
/// accent. Purely visual (positioned by CalendarView); the click is handled by the InputCatcher.
struct DeadlineAddButton: View {
    let theme: Theme
    var hovering: Bool = false
    var body: some View {
        // Neutral cursor-colored ring at rest; on hover the edge + glyph brighten to full label color,
        // with a faint fill and glow (mirrors the web's .cc-ddl-add:hover feedback).
        Image(systemName: "plus")
            .font(.system(size: 8, weight: hovering ? .heavy : .bold))
            .foregroundStyle(hovering ? theme.text : theme.text.opacity(0.75))
            .frame(width: 15, height: 15)
            .background(Circle().fill(hovering ? theme.text.opacity(0.14) : theme.bg))
            .overlay(Circle().strokeBorder(hovering ? theme.text : theme.cursor, lineWidth: hovering ? 2 : 1.5))
            .shadow(color: theme.text.opacity(hovering ? 0.35 : 0), radius: hovering ? 4 : 0)
            .shadow(color: .black.opacity(0.3), radius: 2.5)
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct DashboardSplitHandle: View {
    let engine: CalendarEngine
    let vp: Viewport
    let height: CGFloat
    let theme: Theme
    var onFrac: (CGFloat) -> Void = { _ in } // report the live split so the dashboard re-lays-out
    @State private var inGap = false // mouse anywhere in the timeline↔dashboard gap
    @State private var onGrip = false // mouse on the capsule itself (→ brighter + resize cursor)
    @State private var dragFrac: CGFloat?
    @State private var startFrac: CGFloat = 0.45

    private let minFrac: CGFloat = 0.22, maxFrac: CGFloat = 0.82 // must match engine.setDailyFrac
    /// The dashboard content is inset ~25px from the boundary (see drawDashboardChrome's barX); the
    /// capsule sits centered in that empty gap, which is also the zone that reveals it on hover.
    private let gapInset: CGFloat = 25

    var body: some View {
        let contentW = max(1, vp.w - Layout.labelW)
        let frac = dragFrac ?? engine.daily.frac
        // Timeline edge (gap's left) shifted by the layers' padLeft; the capsule centers in the gap.
        let gapLeftX = Layout.padLeft + Layout.labelW + frac * contentW
        let centerX = gapLeftX + gapInset / 2
        let active = onGrip || dragFrac != nil
        // Two states: faint in the gap, lighter on the grip; invisible otherwise.
        let opacity: Double = active ? 0.6 : (inGap ? 0.28 : 0.0)
        Capsule()
            .fill(theme.text.opacity(opacity))
            .frame(width: 4, height: 48)
            .frame(width: 12, height: 56) // grip zone: brighten + resize cursor + drag
            .contentShape(Rectangle())
            .onHover {
                h in onGrip = h; if h {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                // GLOBAL space: the handle repositions itself as `frac` changes, so a `.local`
                // translation would be measured against a moving origin → feedback twitch.
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { v in
                        if dragFrac == nil {
                            startFrac = engine.daily.frac
                        }
                        let nf = min(maxFrac, max(minFrac, startFrac + v.translation.width / contentW))
                        dragFrac = nf
                        engine.setDailyFrac(nf)
                        onFrac(nf)
                    }
                    .onEnded { _ in dragFrac = nil }
            )
            .frame(width: gapInset, height: height) // gap zone: reveals the capsule (faint)
            .contentShape(Rectangle())
            .onHover { inGap = $0 }
            .position(x: centerX, y: height / 2)
            .animation(.easeOut(duration: 0.12), value: opacity)
    }
}

/// Year › Month › Week › Day breadcrumb, progressive by zoom level (matches the web).
/// The Year crumb is a menu that jumps between selectable years.
struct Breadcrumb: View {
    let engine: CalendarEngine
    private var chrome: CalendarChrome {
        engine.chrome
    }

    var body: some View {
        let atYear = chrome.level == 0
        HStack(spacing: 5) {
            // At the yearly view the "Year" crumb is a native Menu (system dropdown) whose
            // label includes our own caret — so clicking the text OR the caret opens it.
            // Deeper in, it's a plain button that zooms back out to the year.
            if atYear {
                Menu {
                    Picker("Year", selection: Binding(get: { chrome.year }, set: { engine.selectYear($0) })) {
                        ForEach(engine.yearOptions, id: \.self) { y in Text(verbatim: "\(y)").tag(y) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    yearLabel(atYear: true)
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                Button { engine.zoomToYear() } label: { yearLabel(atYear: false) }
                    .buttonStyle(.plain)
            }
            if chrome.level >= 1 {
                sep; crumbButton(MONTH_LONG[chrome.displayFocus], active: chrome.level == 1) { engine.zoomToMonth() }
            }
            if chrome.level >= 2 {
                sep; crumbButton("Week \(Int(chrome.week.rounded()) + 1)", active: chrome.level == 2) {
                    engine.zoomToWeek()
                }
            }
            if chrome.level >= 3, let r = resolveDate(chrome.year, chrome.displayFocus, chrome.displayDom) {
                sep; crumb("\(WD_LONG[dayOfWeek(r.year, r.month, r.day)]), \(r.day)\(ordinal(r.day))", active: true)
            }
        }
        .padding(.horizontal, 18)
    }

    private func yearLabel(atYear: Bool) -> some View {
        HStack(spacing: 0) {
            crumb("Year \(chrome.year)", active: atYear).fixedSize()
            if atYear {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 5)
            }
        }
    }

    private var sep: some View {
        Text("›").font(.system(size: 12)).foregroundStyle(.tertiary)
            .padding(.horizontal, 3) // a little more breathing room around the "›"
    }

    private func crumb(_ text: String, active: Bool) -> some View {
        Text(text)
            .font(.system(size: 13, weight: active ? .semibold : .regular))
            .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
    }

    /// A crumb that navigates when clicked (Month / Week). Kept clickable even when it's the active
    /// level — clicking then just re-settles that view.
    private func crumbButton(_ text: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { crumb(text, active: active) }
            .buttonStyle(.plain)
    }

    private func ordinal(_ n: Int) -> String {
        if (n % 100) / 10 == 1 {
            return "th"
        }
        switch n % 10 { case 1: return "st"; case 2: return "nd"; case 3: return "rd"; default: return "th" }
    }
}
