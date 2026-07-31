// The NATIVE dashboard TODO panel (webview retirement phase 1b) — SwiftUI rendering of the
// TodoFeed sections, behind the cc.nativeDash flag (or CC_NATIVE_DASH=1). V1 scope, deliberately:
// the pinned ⌘B week/month panel's TODO tab only — deadlines-in-range, open todos with subtrees,
// the top-10 completed cap with a PROJ-style chevron. NOTE/PROJ tabs and the day view stay on the
// webview; week-turn cross-fades swap content at the midpoint instead of blending (flag phase).
//
// The panel is mounted inside the calendar's per-frame TimelineView and positioned by the SAME
// dashScopePanels geometry the Canvas header draws with, so it rides the pin slide and the zoom
// carousels natively — no ticks, no IPC, and the content list is a LazyVStack (on-demand rows by
// construction). Data comes straight from engine.todoFeed (parsed once per edit, cached per gen).

import CalendarEngine
import CalendarGeometry
import CalendarRender
import SwiftUI

enum NativeDash {
    /// The rollout flag: `defaults write … cc.nativeDash -bool YES` or env CC_NATIVE_DASH=1.
    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: "cc.nativeDash")
            || ProcessInfo.processInfo.environment["CC_NATIVE_DASH"] != nil
    }
}

struct NativeDashPanel: View {
    let engine: CalendarEngine
    let scope: String // "week" | "month"
    let key: String // week: the Sunday's ISO; month: "YYYY-MM"
    let theme: Theme
    var settings: DashTodoSettings? // layering prefs (⚙) — nil falls back to scope defaults
    var nav: NativeDashNavModel? // keyboard row cursor (⌘B focus / arrows / Space / Enter)
    var onOpen: (String) -> Void // event todo row → open that event (the drawer)
    var onJump: (String) -> Void = { _ in } // note todo row → fly to its note (storage key)

    @State private var doneOpen: Set<String> = [] // per-view completed expansion (session-scoped)
    private static let doneShow = 10

    /// STAY-IN-PLACE (the web's selfEditAt rule): the visible list STRUCTURE (sections, order)
    /// freezes at each full render; a checkbox toggle updates the row's visuals in place via the
    /// live lookup but does NOT re-sort — the row migrates to/from Completed only on a real
    /// re-render (panel re-key, prefs change, or an EXTERNAL data change). `stamp` marks the data
    /// generation the frozen structure has adopted; toggle() adopts its own write's stamp so only
    /// changes we didn't make trigger a refreeze.
    private struct Frozen {
        var basis: String // key|prefs signature
        var stamp: String // engine.todoDataStamp the structure was built from / has adopted
        var sections: [TodoSection]
        var kids: [String: [ParsedTodo]]
    }

    @State private var frozen: Frozen?

    var body: some View {
        let today = Self.todayIso()
        let (start, end) = range
        let word = scope == "week" ? "this week" : "this month"
        let prefs = effectivePrefs
        let todos = engine.todoFeed(today: today)
        let (sections, kids) = frozenStructure(todos: todos, start: start, end: end,
                                               word: word, prefs: prefs)
        let live = Dictionary(todos.map { (Self.anchor($0), $0) }, uniquingKeysWith: { a, _ in a })

        // Register the VISIBLE rows (display order, fold-aware) for the keyboard cursor — off
        // the render pass, and only from the settled panel.
        let displayRows: [ParsedTodo] = sections.flatMap { sec -> [ParsedTodo] in
            let capped = sec.done && sec.items.count > Self.doneShow
                && !doneOpen.contains(sec.key)
            let roots = capped ? Array(sec.items.prefix(Self.doneShow)) : sec.items
            return visibleItems(roots: roots, kids: kids).map { live[Self.anchor($0.todo)] ?? $0.todo }
        }
        let _ = { if let nav { DispatchQueue.main.async { nav.rows = displayRows } } }()
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if prefs.deadlines {
                        deadlineSection(start: start, end: end, today: today)
                    }
                    ForEach(sections, id: \.key) { s in
                        section(s, kids: kids, live: live, today: today)
                    }
                    if sections.isEmpty {
                        Text("Nothing on the list — you’re clear. Add “- [ ] …” items to an event’s note or this scope’s notepad.")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.text.opacity(0.5))
                            .padding(.top, 6)
                    }
                }
                .padding(.trailing, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .onChange(of: nav?.cursor ?? -1) { _, c in
                guard let nav, nav.active, displayRows.indices.contains(c) else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(Self.anchor(displayRows[c]), anchor: .center)
                }
            }
        }
        // Right-click anywhere in the panel = the cog's layering menu (single-sourced from
        // DashTodoCatalog, writing through DashTodoSettings — same as the webview's popup).
        .contextMenu { prefsMenu }
    }

    /// A todo's soft-link identity (note scope + line) — stable across a toggle, unlike tieKey
    /// (whose raw-line component changes when `[ ]` flips or a done: stamp lands).
    static func anchor(_ t: ParsedTodo) -> String { "\(TodoFeed.scopeKey(t))\0\(t.line)" }

    /// One visible row of the fold-aware tree walk.
    struct RowItem {
        let todo: ParsedTodo
        let foldable: Bool
        let folded: Bool
        let hidden: Int // subtree rows hidden under a folded parent
    }

    private var collapsedSet: Set<String> { nav?.collapsedSubs ?? [] }

    private func toggleFold(_ t: ParsedTodo) {
        guard let nav else { return }
        let a = Self.anchor(t)
        withAnimation(.easeInOut(duration: 0.17)) {
            if nav.collapsedSubs.contains(a) { nav.collapsedSubs.remove(a) }
            else { nav.collapsedSubs.insert(a) }
        }
        engine.wake()
    }

    /// Walk each root's subtree skipping folded parents' descendants (the web's collapsed set).
    private func visibleItems(roots: [ParsedTodo],
                              kids: [String: [ParsedTodo]]) -> [RowItem] {
        var out: [RowItem] = []
        func walk(_ t: ParsedTodo) {
            let children = kids["\(TodoFeed.scopeKey(t))\0\(t.line)"] ?? []
            let folded = !children.isEmpty && collapsedSet.contains(Self.anchor(t))
            out.append(RowItem(todo: t, foldable: !children.isEmpty, folded: folded,
                               hidden: folded ? TodoFeed.subtree(t, kids).count - 1 : 0))
            if !folded { for c in children { walk(c) } }
        }
        for r in roots { walk(r) }
        return out
    }

    /// The frozen list structure, refreshed only at FULL-RENDER boundaries: first render, panel
    /// re-key / prefs change, or a data change we didn't make ourselves.
    private func frozenStructure(todos: [ParsedTodo], start: String, end: String, word: String,
                                 prefs: TodoFeedPrefs) -> ([TodoSection], [String: [ParsedTodo]]) {
        let basis = "\(scope)|\(key)|\(prefs.deadlines)|\(prefs.sections.sorted())|\(prefs.sources.sorted())"
        let stamp = engine.todoDataStamp
        if let f = frozen, f.basis == basis, f.stamp == stamp {
            return (f.sections, f.kids)
        }
        let sections = TodoFeed.rangeSections(todos, start: start, end: end, word: word,
                                              prefs: prefs)
        let kids = TodoFeed.childrenIndex(todos)
        // @State writes inside body are deferred; hop off the render pass.
        let f = Frozen(basis: basis, stamp: stamp, sections: sections, kids: kids)
        DispatchQueue.main.async { frozen = f }
        return (sections, kids)
    }

    private var dashScope: DashTodoScope { scope == "week" ? .week : .month }

    /// The user's layering prefs for this scope (⚙ / right-click), falling back to defaults.
    private var effectivePrefs: TodoFeedPrefs {
        guard let settings else { return scope == "week" ? .week : .month }
        let p = settings[dashScope]
        return TodoFeedPrefs(deadlines: p.deadlines,
                             sections: Array(p.sections), sources: Array(p.sources))
    }

    @ViewBuilder private var prefsMenu: some View {
        if let settings {
            Toggle("Display Deadlines", isOn: Binding(
                get: { settings[dashScope].deadlines },
                set: { on in settings[dashScope].deadlines = on; engine.wake() }
            ))
            Menu("Show Collections") {
                ForEach(DashTodoCatalog.sections(for: dashScope), id: \.key) { entry in
                    Toggle(entry.label, isOn: Binding(
                        get: { settings[dashScope].sections.contains(entry.key) },
                        set: { on in
                            if on { settings[dashScope].sections.insert(entry.key) }
                            else { settings[dashScope].sections.remove(entry.key) }
                            engine.wake()
                        }
                    ))
                }
            }
            Menu("Collect from…") {
                ForEach(DashTodoCatalog.sources, id: \.key) { entry in
                    Toggle(entry.label, isOn: Binding(
                        get: { settings[dashScope].sources.contains(entry.key) },
                        set: { on in
                            if on { settings[dashScope].sources.insert(entry.key) }
                            else { settings[dashScope].sources.remove(entry.key) }
                            engine.wake()
                        }
                    ))
                }
            }
        }
    }

    private var range: (String, String) {
        scope == "week"
            ? (key, TodoIndex.addDuration(key, 6, "d"))
            : ("\(key)-01", CalendarEngine.monthEndIso(key))
    }

    static func todayIso() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 2000, c.month ?? 1, c.day ?? 1)
    }

    // ── Sections ─────────────────────────────────────────────────────────────────────────────

    @ViewBuilder
    private func section(_ s: TodoSection, kids: [String: [ParsedTodo]],
                         live: [String: ParsedTodo], today: String) -> some View {
        let capped = s.done && s.items.count > Self.doneShow
        let open = !capped || doneOpen.contains(s.key)
        let roots = open ? s.items : Array(s.items.prefix(Self.doneShow))
        let rows = visibleItems(roots: roots, kids: kids)
        VStack(alignment: .leading, spacing: 5) {
            SectionHeader(title: s.title, count: s.items.count,
                          hidden: capped && !open ? s.items.count - Self.doneShow : 0,
                          chevron: capped, open: open, theme: theme) {
                if open { doneOpen.remove(s.key) } else { doneOpen.insert(s.key) }
            }
            ForEach(rows.indices, id: \.self) { i in
                // Frozen placement, LIVE content: the row renders the current parse of its
                // source line (checkbox state, strike, ✓ label update the moment it's toggled)
                // while its position in the list stays frozen.
                let item = rows[i]
                let t = live[Self.anchor(item.todo)] ?? item.todo
                let focused = nav.map {
                    $0.active && $0.currentRow.map(Self.anchor) == Self.anchor(t)
                } ?? false
                TodoRow(todo: t, today: today,
                        ownNoteKey: scope == "week" ? "week:\(key)" : "month:\(key)",
                        theme: theme, focused: focused,
                        foldable: item.foldable, folded: item.folded, hiddenSubs: item.hidden,
                        onToggle: { toggle(t) },
                        onOpen: { openRow(t) },
                        onFold: { toggleFold(t) })
                    .id(Self.anchor(t))
            }
        }
    }

    @ViewBuilder
    private func deadlineSection(start: String, end: String, today: String) -> some View {
        let list: [(Deadline, String)] = engine.viewDeadlines()
            .map { d in (d, String(format: "%04d-%02d-%02d", d.year, d.month + 1, d.day)) }
            .filter { $0.1 >= start && $0.1 <= end }
            .sorted { a, b in a.1 != b.1 ? a.1 < b.1 : a.0.hour < b.0.hour }
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                SectionHeader(title: "Deadlines in \(scope == "week" ? "this week" : "this month")",
                              count: list.count, hidden: 0, chevron: false, open: true,
                              theme: theme, onChevron: {})
                ForEach(list, id: \.0.id) { d, iso in
                    DeadlineRowView(deadline: d, label: "\(Self.relDue(today, iso)) · \(Self.hhmm(d.hour))",
                                    theme: theme) {
                        engine.revealAndSelect(id: d.id)
                    }
                }
            }
        }
    }

    // ── Actions (the same soft-link writes the webview posted back) ──────────────────────────

    /// Flip a todo's checkbox in its source note (done-stamped), through the engine's own write
    /// paths. Shared by the TODO and PROJ panels.
    static func toggleTodo(_ engine: CalendarEngine, _ t: ParsedTodo) {
        let stamp = todayIso() + "T" + clockNow()
        if t.source == "daily" {
            let key = t.dailyDate ?? ""
            let cur = engine.dailyNote(key)
            if let next = TodoIndex.toggleTodoLine(cur, line: t.line, stamp: stamp), next != cur {
                engine.setDailyNote(key, next)
            }
        } else {
            let cur: String = t.occurrenceKey.map { engine.occNote(t.eventId, $0) }
                ?? engine.notes(t.eventId)
            if let next = TodoIndex.toggleTodoLine(cur, line: t.line, stamp: stamp), next != cur {
                engine.applyTodoNote(eventId: t.eventId, occKey: t.occurrenceKey, value: next)
            }
        }
        // Self-edit: rebuild the feed NOW (the serve-stale path would leave this row's checkbox
        // visually stale for the coalescing window otherwise).
        engine.todoFeedRefreshNow(today: todayIso())
    }

    private func toggle(_ t: ParsedTodo) {
        Self.toggleTodo(engine, t)
        // Our own write: adopt its data stamp so the frozen structure is NOT refrozen — the row
        // stays in place, animating; external changes still refreeze on their own stamps.
        frozen?.stamp = engine.todoDataStamp
    }

    private func openRow(_ t: ParsedTodo) {
        if t.source == "event" {
            onOpen(t.eventId) // opens the event drawer, like the web's data-open
        } else if let key = t.dailyDate {
            onJump(key) // fly to the note's day/week/month, landing on the NOTE tab
        }
    }

    static func clockNow() -> String {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
        return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// The web's finishedLabel: relative done-day + the stamp's wall time when present.
    static func finishedLabel(_ viewIso: String, _ stamp: String) -> String {
        let rel = relDue(viewIso, String(stamp.prefix(10)))
        guard stamp.count >= 16 else { return rel }
        return "\(rel) · \(stamp.dropFirst(11).prefix(5))"
    }

    /// "today" / "3d over" / "in 3d" / the date — a compact relative-due label.
    static func relDue(_ today: String, _ iso: String) -> String {
        guard iso.count >= 10 else { return iso }
        let d = String(iso.prefix(10))
        if d == today { return "today" }
        let days = daysBetween(today, d)
        if days == 1 { return "tomorrow" }
        if days == -1 { return "yesterday" }
        return days < 0 ? "\(-days)d ago" : "in \(days)d"
    }

    static func daysBetween(_ a: String, _ b: String) -> Int {
        func date(_ s: String) -> Date? {
            let p = s.split(separator: "-").compactMap { Int($0) }
            guard p.count == 3 else { return nil }
            return utcCalendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
        }
        guard let da = date(a), let db = date(b) else { return 0 }
        return utcCalendar.dateComponents([.day], from: da, to: db).day ?? 0
    }

    static func hhmm(_ hour: CGFloat) -> String {
        let t = Int((hour * 60).rounded())
        return String(format: "%02d:%02d", (t / 60) % 24, t % 60)
    }
}

/// A section header: uppercase title, count badge, optional "+N more" hint + expansion chevron
/// (the PROJ panel's disclosure language). Shared with NativeProjPanel.
struct SectionHeader: View {
    let title: String
    let count: Int
    let hidden: Int
    let chevron: Bool
    let open: Bool
    let theme: Theme
    var onChevron: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // The same type as the Canvas header's eyebrow ("MONTHLY DASHBOARD" —
            // drawPanelChrome): 10pt, 1.5 tracking, theme.textMuted.
            Text(title.uppercased())
                .font(.system(size: 10))
                .kerning(1.5)
                .foregroundStyle(theme.textMuted)
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(theme.accentGrey.opacity(0.18)))
                .foregroundStyle(theme.text.opacity(0.7))
            if hidden > 0 {
                Text("+\(hidden) more")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.accentGrey)
            }
            if chevron {
                Spacer(minLength: 4)
                Button(action: onChevron) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(theme.accentGrey)
                }
                .buttonStyle(.plain)
                .help("Show all / top items")
            }
        }
    }
}

/// One deadline row (the web's .cc-dd-ddl): color dot, title filling the row, and the
/// relative-due + time label RIGHT-ALIGNED at the row's edge; hover washes the row and tints
/// the title; click navigates to the deadline.
private struct DeadlineRowView: View {
    let deadline: Deadline
    let label: String
    let theme: Theme
    var onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 7) {
                Circle().fill(theme.eventBorder(deadline.color)).frame(width: 8, height: 8)
                Text(deadline.title.isEmpty ? "(untitled)" : deadline.title)
                    .font(.system(size: 12))
                    .foregroundStyle(hovering ? Theme.accent : theme.text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading) // flex:1 → label right-aligns
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.text.opacity(0.6))
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovering ? theme.accentGrey.opacity(0.14) : .clear)
                    .padding(.horizontal, -4)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// One todo row — a faithful port of the webview's .cc-dtodo styling: 15px rounded checkbox,
/// 13px title (prefix + content as inline segments of ONE wrapped text; accent-grey prefix,
/// accent-grey + strike when done), then the 11px meta row — priority bangs (mono-heavy red;
/// levels 4-5 as a white-on-red badge), "↪ follow up …" in teal (red when overdue) OR the
/// relative due (accent-grey; red semibold when overdue), boxed project chips (≤2), and #tags
/// in the ACCENT color (≤3).
private struct TodoRow: View {
    let todo: ParsedTodo
    let today: String
    var ownNoteKey: String = "" // the hosting panel's own scope-note key — its items drop the prefix
    let theme: Theme
    var focused: Bool = false // keyboard cursor here → dashed accent ring
    var foldable: Bool = false // has sub-items → trailing disclosure chevron
    var folded: Bool = false
    var hiddenSubs: Int = 0 // rows hidden under this folded parent ("+N sub")
    var onToggle: () -> Void
    var onOpen: () -> Void
    var onFold: () -> Void = {}

    private static let followupTeal = Color(red: 0x4F / 255.0, green: 0xB0 / 255.0, blue: 0xB0 / 255.0)

    @State private var hovering = false
    // The strike-through DRAWS/RETRACTS left-to-right (the web's character-progressive animation,
    // as a width-mask over a struck copy of the same text). Seeded to the settled state; animates
    // on every done flip.
    @State private var strike: CGFloat = -1 // -1 = unseeded

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            DashCheckbox(checked: todo.done, size: 15, action: onToggle)
                .padding(.top, 2) // .cc-dtodo-check margin-top
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 3) {
                    animatedTitle
                    metaRow
                }
                .contentShape(Rectangle())
                // Hover wash on the TEXT REGION only (back to the web's .cc-dtodo-main:hover):
                // a rounded accent-grey fill bled slightly past the content so layout never
                // shifts. The title tint rides the same hover state.
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hovering ? theme.accentGrey.opacity(0.14) : .clear)
                        .padding(.horizontal, -6).padding(.vertical, -3)
                )
                .onHover { hovering = $0 }
            }
            .buttonStyle(.plain)
            if foldable {
                Spacer(minLength: 4)
                Button(action: onFold) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .rotationEffect(.degrees(folded ? 0 : 90))
                        .foregroundStyle(theme.accentGrey)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Fold / unfold sub-items")
            }
        }
        .onChange(of: todo.done, initial: true) { _, done in
            if strike < 0 {
                strike = done ? 1 : 0 // first render: settled, no animation
            } else {
                withAnimation(.easeInOut(duration: 0.26)) { strike = done ? 1 : 0 }
            }
        }
        .padding(.vertical, 5) // roomier than the web row box, per taste
        .frame(maxWidth: .infinity, alignment: .leading)
        // Keyboard cursor: the dashed accent ring around the whole row (the web's nav ring).
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Theme.accent.opacity(focused ? 0.8 : 0),
                              style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .padding(.horizontal, -4)
        )
        .padding(.leading, CGFloat(min(todo.indent, 6)) * 18) // --nest × 18px
        .background(alignment: .topLeading) {
            // Editor-style indent guides: a vertical line per ancestor level, dropped from under
            // that level's checkbox (x = level·18 + checkbox center), spanning this row's full
            // height — contiguous sibling rows join into one continuous line.
            GeometryReader { g in
                ForEach(0 ..< min(todo.indent, 6), id: \.self) { level in
                    Rectangle()
                        .fill(theme.accentGrey.opacity(0.35))
                        .frame(width: 1, height: g.size.height)
                        .offset(x: CGFloat(level) * 18 + 7)
                }
            }
        }
    }

    /// Two copies of the SAME wrapped text with COMPLEMENTARY left/right masks — the struck copy
    /// replaces the plain one as the `strike` front sweeps (layering it on top let the
    /// full-strength base bleed through and killed the dimming). The struck presentation is the
    /// plain text with a PRONOUNCED text-color strike, then ONE opacity over the whole thing.
    private var animatedTitle: some View {
        ZStack(alignment: .topLeading) {
            title(struck: false)
                .mask(
                    GeometryReader { g in
                        Rectangle()
                            .frame(width: g.size.width * max(0, 1 - strike), alignment: .trailing)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                )
            title(struck: true)
                .opacity(hovering ? 0.62 : 0.45) // the entire struck unit dims as one
                .mask(
                    GeometryReader { g in
                        Rectangle()
                            .frame(width: g.size.width * max(0, strike), alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                )
        }
    }

    private func title(struck: Bool) -> some View {
        titleText(struck: struck)
            .font(.system(size: 13))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The row's single wrapped text: "Event · " prefix (accent-grey) + content, inline segments.
    /// Hover tints the CONTENT (not the prefix) to the accent — done rows to the full text color.
    private func titleText(struck: Bool) -> Text {
        // The struck copy keeps FULL text color with a full-color strike — a pronounced line —
        // and the dimming comes from the single .opacity applied to the whole copy above.
        let contentColor = struck ? theme.text : (hovering ? Theme.accent : theme.text)
        let content = Text(todo.text)
            .strikethrough(struck, color: theme.text)
            .foregroundStyle(contentColor)
        // The web's prefix rule (rowHTML): EVERY source shows its provenance — event titles and
        // note titles ("Daily note · 2026-07-28", "Weekly note · …") alike — except sub-items,
        // the panel's OWN scope note (its title would be redundant inside its own panel), and
        // today's daily note.
        let ownNote = todo.source == "daily"
            && (todo.dailyDate == ownNoteKey || todo.dailyDate == today)
        guard todo.parentLine == nil, !todo.eventTitle.isEmpty, !ownNote else {
            return content
        }
        return Text("\(todo.eventTitle) · ").foregroundStyle(theme.accentGrey) + content
    }

    private var metaRow: some View {
        let opd = TodoFeed.opDate(todo)
        let overdue = opd < today
        let red = theme.eventBorder("red")
        return HStack(spacing: 8) {
            if todo.done {
                // The web's done meta: a single "✓ <finished rel · time>" in dark green.
                Text("✓ \(todo.doneDate.map { NativeDashPanel.finishedLabel(today, $0) } ?? "done")")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.eventBorder("darkgreen").opacity(0.5))
            } else if let p = todo.priority {
                let bangs = Text(String(repeating: "!", count: p))
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .kerning(-0.5)
                if p >= 4 { // levels 4-5: white on red badge
                    bangs.foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(red))
                } else {
                    bangs.foregroundStyle(red)
                }
            }
            if !todo.done, let f = todo.followup {
                Text("↪ follow up \(NativeDashPanel.relDue(today, f))")
                    .font(.system(size: 11, weight: overdue ? .semibold : .medium))
                    .foregroundStyle(overdue ? red : Self.followupTeal)
            } else if !todo.done {
                Text(NativeDashPanel.relDue(today, opd))
                    .font(.system(size: 11, weight: overdue ? .semibold : .regular))
                    .foregroundStyle(overdue ? red : theme.accentGrey)
            }
            ForEach(todo.done ? [] : todo.projects.prefix(2), id: \.self) { proj in
                // Project pill: a slight ACCENT (red) tint — wash + border — so a project reads
                // as belonging to the app's accent system, distinct from grey #tags.
                Text(proj)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.text.opacity(0.8))
                    .padding(.horizontal, 5).padding(.vertical, 0.5)
                    .background(Capsule().fill(Theme.accent.opacity(0.08)))
                    .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1))
            }
            ForEach(todo.done ? [] : todo.tags.prefix(3), id: \.self) { tag in
                Text("#\(tag)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent.opacity(0.85))
            }
            if folded, hiddenSubs > 0 {
                Text("+\(hiddenSubs) sub")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.text.opacity(0.55))
            }
        }
    }
}

