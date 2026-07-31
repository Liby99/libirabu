// The NATIVE PROJ (gantt) panel — the Swift port of dashboard.ts projChartHTML (webview
// retirement phase 2), shown for the pinned week/month panel's PROJ tab behind cc.nativeDash.
// Per project: a label column of REAL todo rows (the house 15px DashCheckbox toggles the source
// line, titles open the event) beside a percent-projected timeline — every row gets a GREY
// ROUNDED TRACK (the web's .cc-proj-track) with its bars inset inside; crossed-due segments are
// hatched; uncrossed dues render as ticks; deadline rules + labels, event boxes, the wall-clock
// now pill, the This Week/Month band, and two axis rows. Sized for readability: 26pt row pitch,
// 13pt labels (the TODO list's size), 10pt+ chrome text.

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

    static let rowH: CGFloat = 26 // row pitch (label row == track row)
    static let trackH: CGFloat = 20 // the grey track's height within the row

    var body: some View {
        let today = NativeDashPanel.todayIso()
        let (rs, re) = range
        let projects = ProjIndex.shown(engine.projFeed(today: today), rs: rs, re: re)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if projects.isEmpty {
                    Text("No projects here yet. Tag todo items with @project:your-project — they show up right here.")
                        .font(.system(size: 12))
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
        VStack(alignment: .leading, spacing: 6) {
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

/// One project's chart: the label column (32% of the width, like the web) beside the projected
/// plot; label rows and grey tracks share the same row pitch so they stay aligned 1:1.
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

    @State private var frontLabel: String? // hovered deadline/event label: raised above the rest

    private var headroom: CGFloat { project.deadlines.isEmpty && project.events.isEmpty ? 18 : 36 }
    private var chartHeight: CGFloat {
        headroom + CGFloat(tasks.count) * NativeProjPanel.rowH + 34 // + the two axis rows
    }

    var body: some View {
        let scale = ChartScale(project: project, tasks: tasks, today: today, rs: rs, re: re)
        GeometryReader { geo in
            let labelW = max(120, geo.size.width * 0.32)
            let plotW = max(40, geo.size.width - labelW - 10)
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: headroom)
                    ForEach(tasks.indices, id: \.self) { i in
                        labelRow(tasks[i])
                    }
                }
                .frame(width: labelW, alignment: .leading)
                plot(scale, w: plotW)
                    .frame(width: plotW, alignment: .topLeading)
            }
        }
        .frame(height: chartHeight)
    }

    private func labelRow(_ t: ProjTask) -> some View {
        let done = t.end != nil
        return HStack(spacing: 8) {
            DashCheckbox(checked: done, size: 15) { onToggle(t) }
                .handCursor()
            Button { onOpen(t.todo.eventId) } label: {
                Text(t.todo.text)
                    .font(.system(size: 13)) // the TODO list's row size
                    .strikethrough(done, color: theme.accentGrey)
                    .foregroundStyle(done ? theme.accentGrey : theme.text)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .handCursor()
            .disabled(t.todo.source != "event")
        }
        .frame(height: NativeProjPanel.rowH, alignment: .leading)
        .help(t.todo.text)
    }

    private func plot(_ scale: ChartScale, w: CGFloat) -> some View {
        let rowsH = CGFloat(tasks.count) * NativeProjPanel.rowH
        let plotH = headroom + rowsH
        // Vertical marks span the TRACK ROWS only (the web's plotarea: 2px above the first
        // track to 2px past the last), never the headroom strip — labels live up there.
        let trackInset = (NativeProjPanel.rowH - NativeProjPanel.trackH) / 2
        let rowTop = headroom + trackInset - 2
        let marksH = rowsH - 2 * trackInset + 4
        return ZStack(alignment: .topLeading) {
            viewMark(scale, w: w, rowTop: rowTop, marksH: marksH)
            deadlineRules(scale, w: w, rowTop: rowTop, marksH: marksH)
            nowLine(scale, w: w, rowTop: rowTop, marksH: marksH)
            taskTracks(scale, w: w)
            eventBoxes(scale, w: w, rowsH: rowsH)
            axes(scale, w: w, plotH: plotH)
        }
    }

    // ── Overlays ─────────────────────────────────────────────────────────────────────────────

    @ViewBuilder
    private func viewMark(_ s: ChartScale, w: CGFloat, rowTop: CGFloat, marksH: CGFloat) -> some View {
        let l = s.x(rs) * w
        let r = s.x(TodoIndex.addDuration(re, 1, "d")) * w // end-day inclusive
        // .cc-proj-viewband: neutral GREY (the accent red is reserved for the now line) —
        // grey wash + solid accent-grey edges, spanning the track rows only.
        Rectangle().fill(Color.gray.opacity(0.14))
            .frame(width: max(1, r - l), height: marksH)
            .offset(x: l, y: rowTop)
        Rectangle().fill(theme.accentGrey).frame(width: 1.5, height: marksH).offset(x: l, y: rowTop)
        Rectangle().fill(theme.accentGrey).frame(width: 1.5, height: marksH).offset(x: r - 1.5, y: rowTop)
        Text(scope == "week" ? "This Week" : "This Month")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(theme.accentGrey)
            .position(x: (l + r) / 2, y: headroom - 9)
    }

    @ViewBuilder
    private func deadlineRules(_ s: ChartScale, w: CGFloat, rowTop: CGFloat, marksH: CGFloat) -> some View {
        ForEach(project.deadlines, id: \.id) { d in
            let iso = String(format: "%04d-%02d-%02d", d.year, d.month + 1, d.day)
            let px = s.x(iso) * w
            let color = theme.eventBorder(d.color)
            // The rule runs from just under its top-layer label all the way down the tracks.
            let lineTop: CGFloat = 15
            Path { p in // .cc-proj-dlline: thin + DASHED in the deadline's own color
                p.move(to: .zero)
                p.addLine(to: CGPoint(x: 0, y: rowTop + marksH - lineTop))
            }
            .stroke(color.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .frame(width: 1, height: rowTop + marksH - lineTop)
            .offset(x: px, y: lineTop)
            Button { onOpen(d.id) } label: {
                Text(d.title.isEmpty ? "(deadline)" : d.title)
                    .font(.system(size: 10.5, weight: .medium))
                    .kerning(0.3)
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .handCursor()
            .labelChip(theme, hover: { frontLabel = $0 ? d.id : nil })
            .position(x: px, y: 7)
            .zIndex(frontLabel == d.id ? 10 : 3)
        }
    }

    @ViewBuilder
    private func nowLine(_ s: ChartScale, w: CGFloat, rowTop: CGFloat, marksH: CGFloat) -> some View {
        let cal = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let frac = Double((cal.hour ?? 0) * 60 + (cal.minute ?? 0)) / 1440
        let px = s.x(today, frac: frac) * w
        let accent = theme.eventBorder("red")
        Rectangle().fill(accent.opacity(0.95)).frame(width: 1.5, height: marksH)
            .offset(x: px, y: rowTop)
        Text("now")
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Capsule().fill(accent))
            .position(x: px, y: headroom - 9)
    }

    /// The row area: one GREY ROUNDED TRACK per task (the web's .cc-proj-track — full plot
    /// width, rgba-grey wash), with the task's bars inset 1pt inside it.
    private func taskTracks(_ s: ChartScale, w: CGFloat) -> some View {
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
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.12)) // the missing grey track
                .frame(width: w, height: NativeProjPanel.trackH)
            // The bar taxonomy: one solid bar to done/now; a crossed due splits solid|hatched;
            // an uncrossed future due renders as a tick in the row's color.
            if let due = t.due, end > due {
                if t.start < due {
                    bar(s, w, t.start, due, color, over: false)
                    bar(s, w, due, end, color, over: true)
                } else {
                    bar(s, w, t.start, end, color, over: true)
                }
            } else {
                bar(s, w, t.start, end, color, over: false)
                if let due = t.due, due > end {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(color.opacity(0.8))
                        .frame(width: 2, height: NativeProjPanel.trackH)
                        .offset(x: s.x(due) * w - 1)
                }
            }
        }
        .frame(width: w, height: NativeProjPanel.rowH, alignment: .leading)
    }

    private func bar(_ s: ChartScale, _ w: CGFloat, _ a: String, _ b: String, _ color: Color,
                     over: Bool) -> some View {
        let l = s.x(a) * w
        let width = max(5, s.x(b) * w - l)
        return RoundedRectangle(cornerRadius: 3)
            .fill(color.opacity(0.85)) // .cc-proj-bar: full color at .85, open and done alike
            .overlay {
                if over { // past-due portion: the web's 45° hatch
                    Hatch().stroke(Color.black.opacity(0.3), lineWidth: 2.2)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            .frame(width: width, height: NativeProjPanel.trackH - 2)
            .offset(x: l)
    }

    @ViewBuilder
    private func eventBoxes(_ s: ChartScale, w: CGFloat, rowsH: CGFloat) -> some View {
        ForEach(project.events.indices, id: \.self) { i in
            let ev = project.events[i]
            let color = theme.eventBorder(ev.color)
            let l = s.x(ev.start) * w
            let width = max(8, s.x(TodoIndex.addDuration(ev.end, 1, "d")) * w - l)
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(color.opacity(0.6), lineWidth: 1.5)
                .background(RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.08)))
                .frame(width: width, height: rowsH)
                .offset(x: l, y: headroom)
                .allowsHitTesting(false)
            Button { onOpen(ev.id) } label: {
                Text(ev.title)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .frame(maxWidth: max(36, width))
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .handCursor()
            .labelChip(theme, hover: { frontLabel = $0 ? ev.id : nil })
            .position(x: l + width / 2, y: headroom - 24)
            .zIndex(frontLabel == ev.id ? 10 : 2)
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
                    .font(.system(size: 10))
                    .foregroundStyle(theme.text.opacity(0.5))
                    .position(x: s.x(iso) * w, y: plotH + 9)
            }
        }
        ForEach(calendarTicks(s), id: \.0) { iso, label in
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(theme.text.opacity(0.5))
                .position(x: s.x(iso) * w, y: plotH + 24)
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

private extension View {
    /// Headroom-label chip: an opaque page-background pill behind deadline/event names so
    /// overlapping labels mask each other instead of colliding glyph-on-glyph; slight
    /// horizontal padding extends the mask past the text, and hover reports up so the
    /// hovered chip can be raised above every other label.
    func labelChip(_ theme: Theme, hover: @escaping (Bool) -> Void) -> some View {
        padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 5).fill(theme.bg))
            .onHover(perform: hover)
    }
}

/// The 45° hatch for past-due bar segments (the web's repeating-linear-gradient stripes).
private struct Hatch: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let step: CGFloat = 6
        var x = -rect.height // start off-left so diagonals cover the whole rect
        while x < rect.width {
            p.move(to: CGPoint(x: x, y: rect.maxY))
            p.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += step
        }
        return p
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
