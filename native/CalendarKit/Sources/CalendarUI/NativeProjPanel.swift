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
    var onOpen: (String, Int?, String?) -> Void
    var onJump: (String, Int?) -> Void = { _, _ in }

    @State private var expanded: String? // accordion: at most one project shows ALL rows

    /// The TODO panel's freeze pattern: the project ORDER and each project's score-ranked task
    /// membership are frozen per render basis and refreshed only at full-render boundaries
    /// (first render, panel re-key, or an EXTERNAL data change). A self-toggle adopts its own
    /// write's stamp instead, so checking a box re-renders the same chart shape — no project
    /// reshuffle mid-click — and the @State write is ALSO what re-renders the panel instantly
    /// while the carousel's render clock sleeps (nothing else invalidates a paused panel).
    private struct Frozen {
        var basis: String // scope|key
        var stamp: String // engine.todoDataStamp the structure was built from / has adopted
        var order: [(key: String, ranked: [String])] // project → byScore task anchors
    }

    @State private var frozen: Frozen?

    static let rowH: CGFloat = 26 // row pitch (label row == track row)
    static let trackH: CGFloat = 20 // the grey track's height within the row
    /// Bar-segment opacity — tune to taste. The web shipped .85; lightened to .80 so the
    /// segments sit a touch softer against the grey tracks.
    static let barOpacity: Double = 0.60

    var body: some View {
        let today = NativeDashPanel.todayIso()
        let (rs, re) = range
        let feed = ProjIndex.shown(engine.projFeed(today: today), rs: rs, re: re)
        let order = frozenOrder(feed, today: today)
        let byKey = Dictionary(feed.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let liveTask = Dictionary(feed.flatMap { p in p.tasks.map { (NativeDashPanel.anchor($0.todo), $0) } },
                                  uniquingKeysWith: { a, _ in a })
        ScrollView {
            // LAZY charts: a dense store mounts only near-viewport projects — the full-list
            // build was the "first ⌘J is the most noticeable" hitch (every chart's rows,
            // tracks, and axes entered the AttributeGraph at once).
            LazyVStack(alignment: .leading, spacing: 22) {
                if order.isEmpty {
                    Text("No projects here yet. Tag todo items with @project:your-project — they show up right here.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.text.opacity(0.5))
                        .padding(.top, 6)
                }
                ForEach(order, id: \.key) { entry in
                    if let p = byKey[entry.key] {
                        projectSection(p, ranked: entry.ranked, liveTask: liveTask,
                                       today: today, rs: rs, re: re)
                    }
                }
            }
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    /// See Frozen. Rebuilt only when basis/stamp move; @State writes hop off the render pass.
    private func frozenOrder(_ projects: [Project], today: String) -> [(key: String, ranked: [String])] {
        let basis = "\(scope)|\(key)"
        let stamp = engine.todoDataStamp
        if let f = frozen, f.basis == basis, f.stamp == stamp {
            return f.order
        }
        return NativeDash.diagTime("projFrozenOrder(\(scope)|\(key))") {
            // Scores are computed ONCE per task, then sorted — a score inside the comparator ran
            // O(n log n) times and made this the single hottest block on tab open (~90ms release,
            // several× that in debug, on a 500-task year).
            let order = projects.map { p in
                (key: p.key,
                 ranked: p.tasks
                     .map { (score: ProjIndex.taskScore($0, today: today), anchor: NativeDashPanel.anchor($0.todo)) }
                     .sorted { $0.score > $1.score }
                     .map(\.anchor))
            }
            let f = Frozen(basis: basis, stamp: stamp, order: order)
            DispatchQueue.main.async { frozen = f }
            return order
        }
    }

    private var range: (String, String) {
        switch scope {
        case "day": (key, key)
        case "week": (key, TodoIndex.addDuration(key, 6, "d"))
        default: ("\(key)-01", CalendarEngine.monthEndIso(key))
        }
    }

    @ViewBuilder
    private func projectSection(_ p: Project, ranked: [String], liveTask: [String: ProjTask],
                                today: String, rs: String, re: String) -> some View {
        let showAll = expanded == p.key
        // FROZEN membership/rank, LIVE rows: each anchor renders the current parse of its line
        // in its frozen slot (checked state updates in place, no reshuffle).
        let byScore = ranked.compactMap { liveTask[$0] }
        // Chart order: pinned rows on top (newest first), the rest chronological. Pinned rows
        // are ALWAYS members — the quick-add's "appears on top" guarantee must survive the
        // collapsed view's score clamp, so #proj-pinned rows join the visible set even when
        // their score ranks below the top maxRows.
        let clamped = showAll ? byScore : Array(byScore.prefix(ProjIndex.maxRows))
        let clampedOut = showAll ? [] : byScore.dropFirst(ProjIndex.maxRows)
            .filter { $0.todo.tags.contains("proj-pinned") }
        let visible = ProjIndex.chartRows(clamped + clampedOut)
        let foldable = byScore.count > ProjIndex.maxRows
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: p.key, count: byScore.count,
                          hidden: showAll ? 0 : byScore.count - visible.count,
                          chevron: foldable, open: showAll, theme: theme) {
                withAnimation(.easeInOut(duration: 0.28)) { // = PROJ_ANIM_MS
                    expanded = showAll ? nil : p.key // accordion: opening one closes the other
                }
            }
            ProjChart(project: p, tasks: visible, today: today, rs: rs, re: re, scope: scope,
                      theme: theme,
                      onToggle: { t in
                          NativeDashPanel.toggleTodo(engine, t.todo)
                          engine.todoFeedRefreshNow(today: today) // serve-stale: land it NOW
                          // Our own write: adopt its stamp (no refreeze/reshuffle) — and this
                          // @State write is what re-renders the panel RIGHT NOW; the paused
                          // render clock wouldn't until the next mouse move woke it.
                          frozen?.stamp = engine.todoDataStamp
                      },
                      onOpen: onOpen,
                      onOpenTodo: { t in
                          if t.source == "event" {
                              onOpen(t.eventId, t.line, t.occurrenceKey)
                          } // event drawer
                          else if let key = t.dailyDate {
                              onJump(key, t.line)
                          } // fly to the note
                      },
                      onQuickAdd: { quickAdd(p.key, $0) })
        }
    }

    /// The quick-add submit: append the typed todo into THIS panel's scope note (the same
    /// storage key the NOTE tab edits — see NativeNotePanel), @project-tagged + pinned +
    /// created-stamped, then land the coalesced feed refresh NOW so the chart gains its row
    /// immediately. No navigation — the field stays put for the next item.
    private func quickAdd(_ project: String, _ text: String) {
        let todo = text.trimmingCharacters(in: .whitespaces)
        guard !todo.isEmpty else { return }
        let storageKey = scope == "day" ? key
            : scope == "week" ? "week:\(key)" : "month:\(key)"
        // The note editor's stampCreated() format: minute precision, YYYY-MM-DDTHH:mm.
        let stamp = NativeDashPanel.todayIso() + "T" + String(NativeDashPanel.clockNow().prefix(5))
        let next = TodoIndex.appendProjectTodo(note: engine.dailyNote(storageKey),
                                               project: project, todo: todo, stamp: stamp)
        engine.setDailyNote(storageKey, next)
        engine.todoFeedRefreshNow(today: NativeDashPanel.todayIso())
        engine.wake() // repaint now — the paused render clock won't (see NativeNotePanel)
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
    var onOpen: (String, Int?, String?) -> Void
    var onOpenTodo: (ParsedTodo) -> Void
    var onQuickAdd: (String) -> Void

    @State private var frontLabel: String? // hovered deadline/event label: raised above the rest
    @State private var draft = "" // the quick-add field's in-progress text
    @FocusState private var draftFocused: Bool

    private var headroom: CGFloat {
        project.deadlines.isEmpty && project.events.isEmpty ? 18 : 36
    }

    private var chartHeight: CGFloat {
        headroom + CGFloat(tasks.count) * NativeProjPanel.rowH + 36 // + the two axis rows
    }

    var body: some View {
        let scale = ChartScale(project: project, tasks: tasks, today: today, rs: rs, re: re)
        GeometryReader { geo in
            let labelW = max(120, geo.size.width * 0.32)
            let plotW = max(40, geo.size.width - labelW - 10)
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    // The quick-add row rides INSIDE the existing headroom strip (bottom-
                    // aligned, right above the top row) — no extra chart height.
                    Color.clear.frame(height: headroom)
                        .overlay(alignment: .bottomLeading) { quickAddRow }
                    ForEach(tasks, id: \.rowId) { t in
                        labelRow(t).transition(.rowReveal)
                    }
                }
                .frame(width: labelW, alignment: .leading)
                plot(scale, w: plotW)
                    .frame(width: plotW, alignment: .topLeading)
            }
        }
        .frame(height: chartHeight)
    }

    /// The compact quick-add input: a "+" in the checkbox column (15pt + the row's 8pt gap),
    /// then a borderless field aligned with the todo titles. Enter submits into the panel's
    /// scope note, clears, and KEEPS focus so several items can be typed in a row.
    private var quickAddRow: some View {
        HStack(spacing: 8) {
            Text("+")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.text.opacity(0.35))
                .frame(width: 15) // = DashCheckbox(size: 15)'s column
            TextField("New TODO Item...", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13)) // the row-title size
                .foregroundStyle(theme.text.opacity(0.65))
                .focused($draftFocused)
                .onSubmit {
                    onQuickAdd(draft)
                    draft = ""
                    draftFocused = true
                }
        }
        .frame(height: 18, alignment: .center) // fits the 18pt no-label headroom untouched
    }

    private func labelRow(_ t: ProjTask) -> some View {
        let done = t.end != nil
        return HStack(spacing: 8) {
            DashCheckbox(checked: done, size: 15) { onToggle(t) }
                .handCursor()
            Button { onOpenTodo(t.todo) } label: {
                // Pinned rows (#proj-pinned, the quick-add's tag) carry a 📌 in the gantt.
                ProjLabelTitle(text: (t.todo.tags.contains("proj-pinned") ? "📌 " : "") + t.todo.text,
                               done: done, theme: theme)
            }
            .buttonStyle(.plain)
            .handCursor()
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
        if scope == "day" {
            // .cc-proj-dayline: the viewed day as a single solid dark rule (no band, no label).
            Rectangle().fill(theme.accentDark.opacity(0.9))
                .frame(width: 1.5, height: marksH)
                .offset(x: l, y: rowTop)
        } else {
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
    }

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
            Button { onOpen(d.id, nil, nil) } label: {
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
            ForEach(tasks, id: \.rowId) { t in
                trackRow(t, s, w: w).transition(.rowReveal)
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
            .fill(color.opacity(NativeProjPanel.barOpacity)) // open and done alike (see constant)
            .overlay {
                if over { // past-due portion: the web's 45° hatch
                    Hatch().stroke(Color.black.opacity(0.3), lineWidth: 2.2)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            .frame(width: width, height: NativeProjPanel.trackH - 2)
            .offset(x: l)
    }

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
            // The name rides centered on the box: SAME placement chain as the box itself
            // (a box-width positioning frame + the identical offset), so the two centers
            // coincide by construction — the chip just overhangs symmetrically if wider.
            Button { onOpen(ev.id, nil, nil) } label: {
                Text(ev.title)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .handCursor()
            .labelChip(theme, hover: { frontLabel = $0 ? ev.id : nil })
            .frame(width: width, height: 18)
            .offset(x: l, y: headroom - 33)
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
        let axisColor = theme.text.opacity(0.5)
        let lineY = plotH + 17 // the .cc-proj-months border-top: between the two axis rows
        Rectangle().fill(Color.gray.opacity(0.25))
            .frame(width: w, height: 1)
            .offset(y: lineY)
        ForEach(Array(stride(from: firstK, through: firstK + 12 * step, by: step)), id: \.self) { k in
            let iso = TodoIndex.addDuration(today, k, "d")
            if iso >= s.lo, iso <= s.hi {
                Text(k == 0 ? "now" : k < 0 ? "\(-k)d ago" : "in \(k)d")
                    .font(.system(size: 10))
                    .foregroundStyle(axisColor)
                    .position(x: s.x(iso) * w, y: plotH + 9)
                Rectangle().fill(axisColor) // its tick: above the line, pointing down at it
                    .frame(width: 1, height: 3)
                    .position(x: s.x(iso) * w, y: lineY - 1)
            }
        }
        ForEach(calendarTicks(s), id: \.0) { iso, label in
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(axisColor)
                .position(x: s.x(iso) * w, y: plotH + 26)
            Rectangle().fill(axisColor) // its tick: below the line
                .frame(width: 1, height: 3)
                .position(x: s.x(iso) * w, y: lineY + 2)
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
                if q.count == 3 {
                    out.append((iso, "\(mo[q[1] - 1]) \(q[2])"))
                }
                iso = TodoIndex.addDuration(iso, 7, "d")
            }
        } else { // month firsts, year-stamped at January
            var p = s.lo.split(separator: "-").compactMap { Int($0) }
            guard p.count >= 2 else { return out }
            p[1] += 1
            if p[1] > 12 {
                p[1] = 1; p[0] += 1
            }
            while out.count < 16 {
                let iso = String(format: "%04d-%02d-01", p[0], p[1])
                if iso > s.hi {
                    break
                }
                out.append((iso, "\(mo[p[1] - 1])\(p[1] == 1 ? " ’\(String(format: "%02d", p[0] % 100))" : "")"))
                p[1] += 1
                if p[1] > 12 {
                    p[1] = 1; p[0] += 1
                }
            }
        }
        return out
    }
}

/// The gantt label's check/uncheck animation — the TODO panel's mechanism, single-line: two
/// copies of the SAME text under COMPLEMENTARY left/right masks, the struck accent-grey copy
/// REPLACING the plain one as the `strike` front sweeps (0.26s), retracting on uncheck.
private struct ProjLabelTitle: View {
    let text: String
    let done: Bool
    let theme: Theme

    @State private var strike: CGFloat = -1 // -1 = unseeded (first render settles, no sweep)

    var body: some View {
        ZStack(alignment: .leading) {
            title(struck: false)
                .mask(
                    GeometryReader { g in
                        Rectangle()
                            .frame(width: g.size.width * max(0, 1 - strike), alignment: .trailing)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                )
            title(struck: true)
                .mask(
                    GeometryReader { g in
                        Rectangle()
                            .frame(width: g.size.width * max(0, strike), alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                )
        }
        .onChange(of: done, initial: true) { _, d in
            if strike < 0 {
                strike = d ? 1 : 0
            } else {
                withAnimation(.easeInOut(duration: 0.26)) { strike = d ? 1 : 0 }
            }
        }
    }

    private func title(struck: Bool) -> some View {
        Text(text)
            .font(.system(size: 13)) // the TODO list's row size
            .strikethrough(struck, color: theme.accentGrey)
            .foregroundStyle(struck ? theme.accentGrey : theme.text)
            .lineLimit(1)
    }
}

private extension ProjTask {
    /// Stable row identity across expand/collapse re-sorts — the TODO panel's anchor
    /// (source scope key + line number). Index identity made SwiftUI read a mid-list
    /// insertion as "every row after it changed content, new rows appended at the end".
    var rowId: String {
        NativeDashPanel.anchor(todo)
    }
}

/// Expand/collapse row reveal — the web's unmasking clip: the row's SLOT animates
/// 0 -> full height over full-size content (no glyph scaling), fading in alongside.
private struct RowReveal: ViewModifier, Animatable {
    var f: CGFloat // 0 = collapsed slot, 1 = full row
    var animatableData: CGFloat {
        get { f }
        set { f = newValue }
    }

    func body(content: Content) -> some View {
        content
            .frame(height: NativeProjPanel.rowH * f, alignment: .center)
            .clipped()
            .opacity(Double(f))
    }
}

private extension AnyTransition {
    static let rowReveal = AnyTransition.modifier(active: RowReveal(f: 0),
                                                  identity: RowReveal(f: 1))
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
            if t.start < rlo {
                rlo = t.start
            }
            if t.start > rhi {
                rhi = t.start
            }
            let e = t.end ?? today
            if e > rhi {
                rhi = e
            }
            if let due = t.due, due > rhi {
                rhi = due
            }
        }
        for d in project.deadlines {
            let iso = String(format: "%04d-%02d-%02d", d.year, d.month + 1, d.day)
            if iso < rlo {
                rlo = iso
            }
            if iso > rhi {
                rhi = iso
            }
        }
        for ev in project.events {
            if ev.start < rlo {
                rlo = ev.start
            }
            if ev.end > rhi {
                rhi = ev.end
            }
        }
        if rs < rlo {
            rlo = rs
        }
        if re > rhi {
            rhi = re
        }
        lo = TodoIndex.addDuration(rlo, -1, "d")
        hi = TodoIndex.addDuration(rhi, 3, "d")
        span = max(1, ProjIndex.daysBetween(lo, hi))
    }

    func x(_ iso: String, frac: Double = 0) -> CGFloat {
        let v = (Double(ProjIndex.daysBetween(lo, String(iso.prefix(10)))) + frac) / Double(span)
        return CGFloat(min(1, max(0, v)))
    }
}
