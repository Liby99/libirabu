// The NATIVE PROJ (gantt) panel — the Swift port of dashboard.ts projChartHTML (webview
// retirement phase 2), shown for the pinned week/month panel's PROJ tab behind cc.nativeDash.
// Per project: a label column of REAL todo rows (checkbox toggles the source line, title opens
// the event) beside a percent-projected timeline — task bars (created/start → done/now), overdue
// hatching past a crossed due:, due ticks, deadline rules + labels, event boxes, the wall-clock
// now line, the current-view band, and two axis rows (relative days + calendar boundaries).
// Top-8 relevance cut with an accordion expand (one project open at a time), animated by SwiftUI
// instead of the web's hand-rolled two-frame transition choreography.

import CalendarEngine
import CalendarGeometry
import CalendarRender
import SwiftUI

struct NativeProjPanel: View {
    let engine: CalendarEngine
    let scope: String // "week" | "month"
    let key: String
    let theme: Theme
    var onOpen: (String) -> Void

    @State private var expanded: String? // accordion: at most one project shows ALL rows

    static let rowH: CGFloat = 20
    static let labelW: CGFloat = 150

    var body: some View {
        let today = NativeDashPanel.todayIso()
        let (rs, re) = range
        let projects = ProjIndex.shown(engine.projFeed(today: today), rs: rs, re: re)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if projects.isEmpty {
                    Text("No projects here yet. Tag todo items with @project:your-project — they show up right here.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.text.opacity(0.5))
                        .padding(.top, 6)
                }
                ForEach(projects, id: \.key) { p in
                    projectSection(p, today: today, rs: rs, re: re)
                }
            }
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    private var range: (String, String) {
        scope == "week"
            ? (key, TodoIndex.addDuration(key, 6, "d"))
            : ("\(key)-01", CalendarEngine.monthEndIso(key))
    }

    @ViewBuilder
    private func projectSection(_ p: Project, today: String, rs: String, re: String) -> some View {
        let showAll = expanded == p.key
        let byScore = p.tasks.sorted {
            ProjIndex.taskScore($0, today: today) > ProjIndex.taskScore($1, today: today)
        }
        let visible = (showAll ? byScore : Array(byScore.prefix(ProjIndex.maxRows)))
            .sorted { $0.start < $1.start } // chart order: chronological
        let foldable = p.tasks.count > ProjIndex.maxRows
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: p.key, count: p.tasks.count,
                          hidden: showAll ? 0 : p.tasks.count - visible.count,
                          chevron: foldable, open: showAll, theme: theme) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    expanded = showAll ? nil : p.key // accordion: opening one closes the other
                }
            }
            ProjChart(project: p, tasks: visible, today: today, rs: rs, re: re, scope: scope,
                      theme: theme,
                      onToggle: { NativeDashPanel.toggleTodo(engine, $0.todo) },
                      onOpen: { id in onOpen(id) })
        }
    }
}

/// One project's chart: label rows beside the percent-projected plot area.
private struct ProjChart: View {
    let project: Project
    let tasks: [ProjTask]
    let today: String
    let rs: String
    let re: String
    let scope: String
    let theme: Theme
    var onToggle: (ProjTask) -> Void
    var onOpen: (String) -> Void

    private var headroom: CGFloat { project.deadlines.isEmpty && project.events.isEmpty ? 16 : 32 }

    var body: some View {
        let scale = ChartScale(project: project, tasks: tasks, today: today, rs: rs, re: re)
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: headroom)
                ForEach(tasks.indices, id: \.self) { i in
                    labelRow(tasks[i])
                }
            }
            .frame(width: NativeProjPanel.labelW, alignment: .leading)
            plot(scale)
        }
    }

    private func labelRow(_ t: ProjTask) -> some View {
        HStack(spacing: 5) {
            DashCheckbox(checked: t.end != nil, size: 11) { onToggle(t) }
            Button { onOpen(t.todo.eventId) } label: {
                Text(t.todo.text)
                    .font(.system(size: 11))
                    .strikethrough(t.end != nil, color: theme.text.opacity(0.4))
                    .foregroundStyle(theme.text.opacity(t.end != nil ? 0.4 : 0.78))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .disabled(t.todo.source != "event")
        }
        .frame(height: NativeProjPanel.rowH, alignment: .leading)
        .help(t.todo.text)
    }

    private func plot(_ scale: ChartScale) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let rowsH = CGFloat(tasks.count) * NativeProjPanel.rowH
            let plotH = headroom + rowsH
            ZStack(alignment: .topLeading) {
                viewMark(scale, w: w, plotH: plotH)
                deadlineRules(scale, w: w, plotH: plotH, rowsH: rowsH)
                nowLine(scale, w: w, plotH: plotH)
                taskBars(scale, w: w)
                eventBoxes(scale, w: w, rowsH: rowsH)
                axes(scale, w: w, plotH: plotH)
            }
        }
        .frame(height: headroom + CGFloat(tasks.count) * NativeProjPanel.rowH + 30)
    }

    // ── Overlays ─────────────────────────────────────────────────────────────────────────────

    @ViewBuilder
    private func viewMark(_ s: ChartScale, w: CGFloat, plotH: CGFloat) -> some View {
        let accent = theme.eventBorder("red")
        if scope == "day" {
            Rectangle().fill(theme.text.opacity(0.5)).frame(width: 1, height: plotH)
                .offset(x: s.x(rs) * w)
        } else {
            let l = s.x(rs) * w
            let r = s.x(TodoIndex.addDuration(re, 1, "d")) * w // end-day inclusive
            Rectangle().fill(accent.opacity(0.07))
                .frame(width: max(1, r - l), height: plotH)
                .offset(x: l)
            Rectangle().fill(accent.opacity(0.5)).frame(width: 1, height: plotH).offset(x: l)
            Rectangle().fill(accent.opacity(0.5)).frame(width: 1, height: plotH).offset(x: r)
            Text(scope == "week" ? "This Week" : "This Month")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(accent.opacity(0.8))
                .position(x: (l + r) / 2, y: headroom - 8)
        }
    }

    @ViewBuilder
    private func deadlineRules(_ s: ChartScale, w: CGFloat, plotH: CGFloat,
                               rowsH: CGFloat) -> some View {
        ForEach(project.deadlines, id: \.id) { d in
            let iso = String(format: "%04d-%02d-%02d", d.year, d.month + 1, d.day)
            let px = s.x(iso) * w
            let color = theme.eventBorder(d.color)
            Rectangle().fill(color.opacity(0.55))
                .frame(width: 1, height: plotH)
                .offset(x: px)
            Button { onOpen(d.id) } label: {
                Text(d.title.isEmpty ? "(deadline)" : d.title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .position(x: px, y: 6)
        }
    }

    @ViewBuilder
    private func nowLine(_ s: ChartScale, w: CGFloat, plotH: CGFloat) -> some View {
        let cal = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let frac = Double((cal.hour ?? 0) * 60 + (cal.minute ?? 0)) / 1440
        let px = s.x(today, frac: frac) * w
        let accent = theme.eventBorder("red")
        Rectangle().fill(accent).frame(width: 1.5, height: plotH).offset(x: px)
        Text("now")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(accent))
            .position(x: px, y: headroom - 8)
    }

    private func taskBars(_ s: ChartScale, w: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(tasks.indices, id: \.self) { i in
                trackRow(tasks[i], s, w: w)
            }
        }
        .padding(.top, headroom)
    }

    @ViewBuilder
    private func trackRow(_ t: ProjTask, _ s: ChartScale, w: CGFloat) -> some View {
        let color = theme.eventBorder(t.color)
        let end = t.end ?? today
        let done = t.end != nil
        ZStack(alignment: .leading) {
            // The bar taxonomy: one solid bar to done/now; a crossed due splits solid|hatched;
            // an uncrossed future due renders as a small vertical tick.
            if let due = t.due, end > due {
                if t.start < due {
                    bar(s, w, t.start, due, color, dim: done, over: false)
                    bar(s, w, due, end, color, dim: done, over: true)
                } else {
                    bar(s, w, t.start, end, color, dim: done, over: true)
                }
            } else {
                bar(s, w, t.start, end, color, dim: done, over: false)
                if let due = t.due, due > end {
                    Rectangle().fill(color)
                        .frame(width: 2, height: 11)
                        .offset(x: s.x(due) * w - 1)
                }
            }
        }
        .frame(height: NativeProjPanel.rowH, alignment: .leading)
    }

    private func bar(_ s: ChartScale, _ w: CGFloat, _ a: String, _ b: String, _ color: Color,
                     dim: Bool, over: Bool) -> some View {
        let l = s.x(a) * w
        let width = max(4, s.x(b) * w - l)
        return RoundedRectangle(cornerRadius: 2.5)
            .fill(color.opacity(dim ? 0.35 : over ? 0.5 : 0.85))
            .frame(width: width, height: 5)
            .offset(x: l)
    }

    @ViewBuilder
    private func eventBoxes(_ s: ChartScale, w: CGFloat, rowsH: CGFloat) -> some View {
        ForEach(project.events.indices, id: \.self) { i in
            let ev = project.events[i]
            let color = theme.eventBorder(ev.color)
            let l = s.x(ev.start) * w
            let width = max(6, s.x(TodoIndex.addDuration(ev.end, 1, "d")) * w - l)
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(color.opacity(0.55), lineWidth: 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.06)))
                .frame(width: width, height: rowsH)
                .offset(x: l, y: headroom)
                .allowsHitTesting(false)
            Button { onOpen(ev.id) } label: {
                Text(ev.title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .frame(maxWidth: max(30, width))
            }
            .buttonStyle(.plain)
            .position(x: l + width / 2, y: 22)
        }
    }

    /// Two axis rows below the plot: relative days from now, then calendar boundaries
    /// (Sundays on short spans, month firsts otherwise).
    @ViewBuilder
    private func axes(_ s: ChartScale, w: CGFloat, plotH: CGFloat) -> some View {
        let span = s.span
        let step = span <= 42 ? 7 : span <= 100 ? 30 : span <= 240 ? 60 : 90
        let firstK = Int(ceil(Double(-ProjIndex.daysBetween(s.lo, today)) / Double(step))) * step
        ForEach(Array(stride(from: firstK, through: firstK + 12 * step, by: step)), id: \.self) { k in
            let iso = TodoIndex.addDuration(today, k, "d")
            if iso >= s.lo, iso <= s.hi {
                Text(k == 0 ? "now" : k < 0 ? "\(-k)d ago" : "in \(k)d")
                    .font(.system(size: 8))
                    .foregroundStyle(theme.text.opacity(0.45))
                    .position(x: s.x(iso) * w, y: plotH + 7)
            }
        }
        ForEach(calendarTicks(s), id: \.0) { iso, label in
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(theme.text.opacity(0.45))
                .position(x: s.x(iso) * w, y: plotH + 20)
        }
    }

    private func calendarTicks(_ s: ChartScale) -> [(String, String)] {
        let mo = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        var out: [(String, String)] = []
        if s.span <= 60 { // week boundaries: Sundays as "Jul 6"
            let p = s.lo.split(separator: "-").compactMap { Int($0) }
            guard p.count == 3,
                  let d0 = utcCalendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
            else { return out }
            let dow = utcCalendar.component(.weekday, from: d0) - 1 // 0 = Sunday
            var iso = TodoIndex.addDuration(s.lo, (7 - dow) % 7, "d")
            while iso <= s.hi, out.count < 16 {
                let q = iso.split(separator: "-").compactMap { Int($0) }
                if q.count == 3 { out.append((iso, "\(mo[q[1] - 1]) \(q[2])")) }
                iso = TodoIndex.addDuration(iso, 7, "d")
            }
        } else { // month firsts, year-stamped at January
            var p = s.lo.split(separator: "-").compactMap { Int($0) }
            guard p.count >= 2 else { return out }
            p[1] += 1
            if p[1] > 12 { p[1] = 1; p[0] += 1 }
            while out.count < 16 {
                let iso = String(format: "%04d-%02d-01", p[0], p[1])
                if iso > s.hi { break }
                out.append((iso, "\(mo[p[1] - 1])\(p[1] == 1 ? " ’\(String(format: "%02d", p[0] % 100))" : "")"))
                p[1] += 1
                if p[1] > 12 { p[1] = 1; p[0] += 1 }
            }
        }
        return out
    }
}

/// The chart's time projection: earliest visible start → max(now, latest deadline/due/event),
/// the current view window always in frame, plus breathing room (−1d / +3d). x() → 0…1.
private struct ChartScale {
    let lo: String
    let hi: String
    let span: Int

    init(project: Project, tasks: [ProjTask], today: String, rs: String, re: String) {
        var rlo = today, rhi = today
        for t in tasks {
            if t.start < rlo { rlo = t.start }
            if t.start > rhi { rhi = t.start }
            let e = t.end ?? today
            if e > rhi { rhi = e }
            if let due = t.due, due > rhi { rhi = due }
        }
        for d in project.deadlines {
            let iso = String(format: "%04d-%02d-%02d", d.year, d.month + 1, d.day)
            if iso < rlo { rlo = iso }
            if iso > rhi { rhi = iso }
        }
        for ev in project.events {
            if ev.start < rlo { rlo = ev.start }
            if ev.end > rhi { rhi = ev.end }
        }
        if rs < rlo { rlo = rs }
        if re > rhi { rhi = re }
        lo = TodoIndex.addDuration(rlo, -1, "d")
        hi = TodoIndex.addDuration(rhi, 3, "d")
        span = max(1, ProjIndex.daysBetween(lo, hi))
    }

    func x(_ iso: String, frac: Double = 0) -> CGFloat {
        let v = (Double(ProjIndex.daysBetween(lo, String(iso.prefix(10)))) + frac) / Double(span)
        return CGFloat(min(1, max(0, v)))
    }
}
