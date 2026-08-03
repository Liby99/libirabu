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

/// The pointing-hand cursor on hover, set DIRECTLY via NSCursor — SwiftUI's pointerStyle was
/// silently ineffective under the app's window-spanning input-catcher tracking areas. Works
/// because the catcher yields the cursor over the native panel (CalendarInputLayer.mouseMoved).
private struct HandCursor: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { inside in
            if inside {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}

extension View {
    func handCursor() -> some View {
        modifier(HandCursor())
    }
}

enum NativeDash {
    // The native dashboard is THE dashboard: the WKWebView fallback (and its
    // cc.nativeDashOff / CC_NATIVE_DASH_OFF kill switches) was retired to legacy/ in
    // phase 4a, 2026-08-02.

    /// Trackpad-pinch tap suppression: the panel overlay's MagnifyGesture is SIMULTANEOUS with
    /// the row buttons' click recognizers, and lifting off a pinch (notably with tap-to-click)
    /// can land as a click on whatever row the cursor hovers — zooming then "clicked" a todo
    /// and flew to its definition. The pinch handlers stamp this clock; row activations
    /// (open/jump/toggle) are ignored while a pinch is in flight or just ended.
    @MainActor static var lastPinch: Date = .distantPast
    @MainActor static var tapsSuppressed: Bool {
        Date().timeIntervalSince(lastPinch) < 0.35
    }

    /// Recently-shown panels PARKED MOUNTED (most-recent last, capped): a panel leaving the
    /// carousel keeps its view alive at opacity 0 instead of unmounting, so swiping back to it
    /// carousels REAL content with no rebuild — the mount cost (row view creation + text
    /// layout, the real-store flamegraph's remaining block) is paid once per key, not per
    /// visit. Content is NEVER gated: every mounted panel renders fully (no blank slots).
    @MainActor static var parkedPanels: [DashBodyPanel] = []
    @MainActor static var lastLiveIds: Set<String> = [] // change-gate for the per-frame bookkeeping
    /// Panels pre-built while the dashboard is RETRACTED (or at year) — these warm ALL tabs
    /// (the first-⌘J case). Mid-tour neighbor pre-builds stay single-tab: their mounts land
    /// inside fast swipe sequences, where a triple build regressed the tours.
    @MainActor static var warmIds: Set<String> = []
    /// Settled-panel dwell tracking: the CURRENT panel warms its unvisited tabs only after a
    /// SUSTAINED rest (0.5s) — warming on any momentary settle re-created the swipe-tour
    /// regression (mounts landing inside the next gesture).
    @MainActor static var settledSince: (id: String, at: Date)?

    // ── CC_DASH_DIAG=1: pin-toggle tween forensics (the "no animation, just a pop" hunt) ──
    // dashHotkey stamps the press; the overlay's per-frame eval then reports, for 2.5s: any
    // frame GAP > 50ms (who blocked the tween), any todoDataStamp change (sync/import churn
    // refreezing panels mid-slide), and whether the target panel was parked/warm at press.
    static let diag = ProcessInfo.processInfo.environment["CC_DASH_DIAG"] != nil
    @MainActor static var diagPressAt: Date?
    @MainActor static var diagLastEval: Date?
    @MainActor static var diagLastStamp = ""

    @MainActor static var diagFirstFramePending = false
    @MainActor static var diagFirstScenePending = false

    @MainActor static func diagPress(_ label: String, engine: CalendarEngine) {
        guard diag else { return }
        DashWatchdog.shared.openWindow(seconds: 2.5)
        diagPressAt = Date()
        diagLastEval = nil
        diagLastScene = nil
        diagFirstFramePending = true
        diagFirstScenePending = true
        diagLastStamp = engine.todoDataStamp
        let parked = parkedPanels.map(\.panelId).joined(separator: ",")
        print(
            "[dash-diag] \(label) pressed | awake=\(engine.renderClock.awake) pinned=\(engine.dashPinned) level=\(engine.chrome.level) parked=[\(parked)] warm=[\(warmIds.joined(separator: ","))]"
        )
    }

    /// Time a suspect on the main thread; prints only when it exceeds 50ms (diag builds).
    static func diagTime<T>(_ label: String, _ work: () -> T) -> T {
        guard diag else { return work() }
        let t0 = Date()
        let out = work()
        let ms = -t0.timeIntervalSinceNow * 1000
        if ms > 50 {
            print(String(format: "[dash-diag] %@ took %.0fms", label, ms))
        }
        return out
    }

    /// SCENE-side heartbeat (the main canvas TimelineView): if SCENE gaps mirror the overlay
    /// gaps, the render clock/schedule is stalling globally; if the scene ticks while the
    /// overlay starves, the overlay's timeline has a dependency problem.
    @MainActor static var diagLastScene: Date?
    @MainActor static func diagSceneFrame() {
        guard diag, let press = diagPressAt else { diagLastScene = nil; return }
        let now = Date()
        if diagFirstScenePending {
            diagFirstScenePending = false
            let ms = now.timeIntervalSince(press) * 1000
            if ms > 40 {
                print(String(
                    format: "[dash-diag] FIRST SCENE frame %.0fms after press (the tween ran blind until here)",
                    ms
                ))
            }
        }
        if let last = diagLastScene {
            let gap = now.timeIntervalSince(last)
            if gap > 0.05 {
                print(String(format: "[dash-diag] SCENE GAP %.0fms at +%.2fs after press",
                             gap * 1000, now.timeIntervalSince(press)))
            }
        }
        diagLastScene = now
    }

    @MainActor static func diagFrame(engine: CalendarEngine) {
        guard diag else { return }
        DashWatchdog.shared.noteEval()
        guard let press = diagPressAt else { return }
        let now = Date()
        let sincePress = now.timeIntervalSince(press)
        if sincePress > 2.5 {
            diagPressAt = nil
            print("[dash-diag] tween window closed")
            return
        }
        if diagFirstFramePending {
            diagFirstFramePending = false
            let ms = sincePress * 1000
            if ms > 40 {
                print(String(format: "[dash-diag] FIRST OVERLAY frame %.0fms after press", ms))
            }
        }
        if let last = diagLastEval {
            let gap = now.timeIntervalSince(last)
            if gap > 0.05 {
                print(String(format: "[dash-diag] FRAME GAP %.0fms at +%.2fs after press",
                             gap * 1000, sincePress))
            }
        }
        diagLastEval = now
        let stamp = engine.todoDataStamp
        if stamp != diagLastStamp {
            print(String(format: "[dash-diag] dataStamp CHANGED at +%.2fs (sync/import churn → panel refreeze) %@ → %@",
                         sincePress, diagLastStamp, stamp))
            diagLastStamp = stamp
        }
    }

    @MainActor static func parkPanels(_ live: [DashBodyPanel]) {
        for p in live {
            parkedPanels.removeAll { $0.panelId == p.panelId }
            parkedPanels.append(p)
        }
        if parkedPanels.count > 4 {
            parkedPanels.removeFirst(parkedPanels.count - 4)
        }
    }

    /// The settled panel's ADJACENT keys (month ±1, week ±7d, day ±1d) — pre-mounted parked
    /// (op 0) while at rest, ONE per frame eval, so the first swipe toward a neighbor finds
    /// its panel already built instead of paying the mount on a gesture frame.
    static func neighborPanels(of p: DashBodyPanel) -> [DashBodyPanel] {
        func with(_ key: String) -> DashBodyPanel {
            DashBodyPanel(scope: p.scope, key: key, x: p.x, w: p.w, dx: 0, dy: p.dy, op: 0)
        }
        switch p.scope {
        case "month":
            let c = p.key.split(separator: "-").compactMap { Int($0) }
            guard c.count == 2 else { return [] }
            func mk(_ y: Int, _ m: Int) -> String {
                let (yy, mm) = m < 1 ? (y - 1, 12) : m > 12 ? (y + 1, 1) : (y, m)
                return String(format: "%04d-%02d", yy, mm)
            }
            return [with(mk(c[0], c[1] + 1)), with(mk(c[0], c[1] - 1))]
        case "week":
            return [with(TodoIndex.addDuration(p.key, 7, "d")),
                    with(TodoIndex.addDuration(p.key, -7, "d"))]
        case "day":
            return [with(TodoIndex.addDuration(p.key, 1, "d")),
                    with(TodoIndex.addDuration(p.key, -1, "d"))]
        default:
            return []
        }
    }

    /// Keep nav-row registry entries only for panels still in the view tree (parked + live).
    @MainActor static func trimNavRows(_ nav: NativeDashNavModel, liveIds: Set<String>) {
        let keep = liveIds.union(parkedPanels.map(\.panelId))
        nav.rowsByPanel = nav.rowsByPanel.filter { keep.contains($0.key) }
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
    var onJump: (String, Int?) -> Void = { _, _ in } // note todo row → fly to its note (storage key)

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
    @State private var deadlineRange = NativeDashPanel.dayDeadlineRange // day deadline window

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
            return flatten(visibleTree(roots: roots, kids: kids))
                .map { live[Self.anchor($0.todo)] ?? $0.todo }
        }
        let _ = {
            if let nav {
                let pid = scope + "|" + key
                DispatchQueue.main.async { nav.rowsByPanel[pid] = displayRows }
            }
        }()
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if prefs.deadlines {
                        deadlineSection(start: start, end: end, today: today)
                    }
                    ForEach(sections, id: \.key) { s in
                        section(s, kids: kids, live: live, today: today, proxy: proxy)
                    }
                    if sections.isEmpty {
                        Text(
                            "Nothing on the list — you’re clear. Add “- [ ] …” items to an event’s note or this scope’s notepad."
                        )
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
    static func anchor(_ t: ParsedTodo) -> String {
        "\(TodoFeed.scopeKey(t))\0\(t.line)"
    }

    /// One visible row of the fold-aware tree walk.
    struct RowItem {
        let todo: ParsedTodo
        let foldable: Bool
        let folded: Bool
        let hidden: Int // subtree rows hidden under a folded parent
    }

    /// The fold-aware subtree: rendered RECURSIVELY (TodoSubtree) so each parent's children live
    /// in one zero-spacing wrapper that draws a CONTINUOUS guide border.
    /// A CLASS on purpose (flamegraph-driven, same story as TodoSubtree.Ctx): as a struct, every
    /// subtree view stored its WHOLE descendant tree by value, and the AttributeGraph's row diff
    /// compared each ParsedTodo elementwise down the tree — parent × descendants work on the
    /// real store. As a reference the graph compares one pointer per node.
    final class RowNode {
        let item: RowItem
        let children: [RowNode]

        init(item: RowItem, children: [RowNode]) {
            self.item = item
            self.children = children
        }
    }

    private var collapsedSet: Set<String> {
        nav?.collapsedSubs ?? []
    }

    /// Click on a subtree's guide line: fold that parent and smoothly center its row.
    private func foldAndCenter(_ t: ParsedTodo, proxy: ScrollViewProxy?) {
        guard let nav else { return }
        let a = Self.anchor(t)
        withAnimation(.easeInOut(duration: 0.2)) { _ = nav.collapsedSubs.insert(a) }
        engine.wake()
        withAnimation(.easeInOut(duration: 0.3)) { proxy?.scrollTo(a, anchor: .center) }
    }

    private func toggleFold(_ t: ParsedTodo) {
        guard let nav else { return }
        let a = Self.anchor(t)
        withAnimation(.easeInOut(duration: 0.17)) {
            if nav.collapsedSubs.contains(a) {
                nav.collapsedSubs.remove(a)
            } else {
                nav.collapsedSubs.insert(a)
            }
        }
        engine.wake()
    }

    /// Build each root's fold-aware subtree (folded parents keep no children).
    private func visibleTree(roots: [ParsedTodo],
                             kids: [String: [ParsedTodo]]) -> [RowNode] {
        func node(_ t: ParsedTodo) -> RowNode {
            let children = kids["\(TodoFeed.scopeKey(t))\0\(t.line)"] ?? []
            let folded = !children.isEmpty && collapsedSet.contains(Self.anchor(t))
            let item = RowItem(todo: t, foldable: !children.isEmpty, folded: folded,
                               hidden: folded ? TodoFeed.subtree(t, kids).count - 1 : 0)
            return RowNode(item: item, children: folded ? [] : children.map(node))
        }
        return roots.map(node)
    }

    private func flatten(_ nodes: [RowNode]) -> [RowItem] {
        nodes.flatMap { [$0.item] + flatten($0.children) }
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
        let sections = NativeDash.diagTime("frozenStructure(\(scope)|\(key))") {
            scope == "day"
                ? TodoFeed.sectionsForDay(todos, viewIso: key, today: Self.todayIso(), prefs: prefs)
                : TodoFeed.rangeSections(todos, start: start, end: end, word: word, prefs: prefs)
        }
        let kids = TodoFeed.childrenIndex(todos)
        // @State writes inside body are deferred; hop off the render pass.
        let f = Frozen(basis: basis, stamp: stamp, sections: sections, kids: kids)
        DispatchQueue.main.async { frozen = f }
        return (sections, kids)
    }

    private var dashScope: DashTodoScope {
        scope == "day" ? .day : scope == "week" ? .week : .month
    }

    /// The user's layering prefs for this scope (⚙ / right-click), falling back to defaults.
    private var effectivePrefs: TodoFeedPrefs {
        guard let settings else {
            return scope == "day" ? .day : scope == "week" ? .week : .month
        }
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
                            if on {
                                settings[dashScope].sections.insert(entry.key)
                            } else {
                                settings[dashScope].sections.remove(entry.key)
                            }
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
                            if on {
                                settings[dashScope].sources.insert(entry.key)
                            } else {
                                settings[dashScope].sources.remove(entry.key)
                            }
                            engine.wake()
                        }
                    ))
                }
            }
        }
    }

    private var range: (String, String) {
        switch scope {
        case "day": (key, key)
        case "week": (key, TodoIndex.addDuration(key, 6, "d"))
        default: ("\(key)-01", CalendarEngine.monthEndIso(key))
        }
    }

    static func todayIso() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 2000, c.month ?? 1, c.day ?? 1)
    }

    // ── Sections ─────────────────────────────────────────────────────────────────────────────

    @ViewBuilder
    private func section(_ s: TodoSection, kids: [String: [ParsedTodo]],
                         live: [String: ParsedTodo], today: String,
                         proxy: ScrollViewProxy? = nil) -> some View {
        let capped = s.done && s.items.count > Self.doneShow
        let open = !capped || doneOpen.contains(s.key)
        let roots = open ? s.items : Array(s.items.prefix(Self.doneShow))
        let tree = visibleTree(roots: roots, kids: kids)
        let ctx = TodoSubtree.Ctx(
            today: today,
            ownNoteKey: scope == "day" ? key : scope == "week" ? "week:\(key)" : "month:\(key)",
            theme: theme, live: live, nav: nav,
            toggle: { self.toggle($0) },
            open: { self.openRow($0) },
            fold: { self.toggleFold($0) },
            foldAndCenter: { t in self.foldAndCenter(t, proxy: proxy) }
        )
        VStack(alignment: .leading, spacing: 5) {
            SectionHeader(title: s.title, count: s.items.count,
                          hidden: capped && !open ? s.items.count - Self.doneShow : 0,
                          chevron: capped, open: open, theme: theme) {
                if open {
                    doneOpen.remove(s.key)
                } else {
                    doneOpen.insert(s.key)
                }
            }
            // Recursive subtrees: zero-spacing wrappers own the CONTINUOUS guide borders; each
            // row still renders the LIVE parse of its line in its frozen position.
            // LAZY roots (flamegraph-driven): the outer LazyVStack is lazy per SECTION, so a
            // dense month section built EVERY root subtree at once — the AttributeGraph grew
            // by the whole list and per-frame graph bookkeeping scaled with it. Lazy roots
            // keep layout pixel-identical while only materializing near-viewport subtrees.
            LazyVStack(alignment: .leading, spacing: 5) {
                ForEach(tree.indices, id: \.self) { i in
                    TodoSubtree(node: tree[i], ctx: ctx)
                }
            }
        }
    }

    /// The day scope's deadline window (the web's cc-dd-range dropdown). Session-global like the
    /// webview's module variable — panels re-key per day, so per-panel @State would reset daily.
    @MainActor static var dayDeadlineRange = "d30"
    static let dayDeadlineOpts: [(String, String)] = [
        ("week", "This week"), ("month", "This month"), ("d30", "30 days"),
        ("m3", "3 months"), ("m6", "6 months"),
    ]

    /// The last day (inclusive) to show deadlines through (ports deadlineWindowEnd).
    static func dayDeadlineEnd(_ viewIso: String, range: String) -> String {
        let p = viewIso.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3,
              let d0 = utcCalendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
        else { return viewIso }
        switch range {
        case "week": // through Saturday
            return TodoIndex.addDuration(viewIso, 6 - (utcCalendar.component(.weekday, from: d0) - 1), "d")
        case "month":
            return CalendarEngine.monthEndIso(String(viewIso.prefix(7)))
        case "m3", "m6":
            let months = range == "m3" ? 3 : 6
            guard let dt = utcCalendar.date(byAdding: .month, value: months, to: d0) else { return viewIso }
            let c = utcCalendar.dateComponents([.year, .month, .day], from: dt)
            return String(format: "%04d-%02d-%02d", c.year ?? p[0], c.month ?? p[1], c.day ?? p[2])
        default:
            return TodoIndex.addDuration(viewIso, 30, "d")
        }
    }

    @ViewBuilder
    private func deadlineSection(start: String, end: String, today: String) -> some View {
        let day = scope == "day"
        let winEnd = day ? Self.dayDeadlineEnd(key, range: deadlineRange) : end
        let all: [(Deadline, String)] = engine.viewDeadlines()
            .map { d in (d, String(format: "%04d-%02d-%02d", d.year, d.month + 1, d.day)) }
            .filter { $0.1 >= start && $0.1 <= winEnd }
            .sorted { a, b in a.1 != b.1 ? a.1 < b.1 : a.0.hour < b.0.hour }
        let list = day ? Array(all.prefix(10)) : all
        if !list.isEmpty || day {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    SectionHeader(title: day ? "Upcoming Deadlines"
                        : "Deadlines in \(scope == "week" ? "this week" : "this month")",
                        count: list.count, hidden: 0, chevron: false, open: true,
                        theme: theme, onChevron: {})
                    if day { // the web's window dropdown, as a native menu
                        Menu {
                            ForEach(Self.dayDeadlineOpts, id: \.0) { v, label in
                                Button(label) {
                                    deadlineRange = v
                                    Self.dayDeadlineRange = v
                                }
                            }
                        } label: {
                            Text(Self.dayDeadlineOpts.first { $0.0 == deadlineRange }?.1 ?? "30 days")
                                .font(.system(size: 10))
                                .foregroundStyle(theme.textMuted)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                if list.isEmpty {
                    Text("No deadlines in this window.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.text.opacity(0.45))
                }
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
        guard !NativeDash.tapsSuppressed else { return } // pinch lift-off, not a real click

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
        guard !NativeDash.tapsSuppressed else { return } // pinch lift-off, not a real click

        Self.toggleTodo(engine, t)
        // Our own write: adopt its data stamp so the frozen structure is NOT refrozen — the row
        // stays in place, animating; external changes still refreeze on their own stamps.
        frozen?.stamp = engine.todoDataStamp
    }

    private func openRow(_ t: ParsedTodo) {
        guard !NativeDash.tapsSuppressed else { return } // pinch lift-off, not a real click
        if t.source == "event" {
            onOpen(t.eventId) // opens the event drawer, like the web's data-open
        } else if let key = t.dailyDate {
            onJump(key, t.line) // fly to the note, landing in the editor at this line
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
        if d == today {
            return "today"
        }
        let days = daysBetween(today, d)
        if days == 1 {
            return "tomorrow"
        }
        if days == -1 {
            return "yesterday"
        }
        return days < 0 ? "\(-days)d ago" : "in \(days)d"
    }

    /// Memoized — Calendar/DateComponents math showed up per-row in the real-store profile
    /// (relDue runs for every row render); the same few (today, due) pairs repeat constantly.
    @MainActor private static var daysCache: [String: Int] = [:]
    @MainActor static func daysBetween(_ a: String, _ b: String) -> Int {
        let key = a + "|" + b
        if let hit = daysCache[key] {
            return hit
        }
        func date(_ s: String) -> Date? {
            let p = s.split(separator: "-").compactMap { Int($0) }
            guard p.count == 3 else { return nil }
            return utcCalendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
        }
        guard let da = date(a), let db = date(b) else { return 0 }
        let d = utcCalendar.dateComponents([.day], from: da, to: db).day ?? 0
        if daysCache.count > 4096 {
            daysCache.removeAll()
        }
        daysCache[key] = d
        return d
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
                .handCursor()
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
        .handCursor()
        .onHover { hovering = $0 }
    }
}

/// One fold-aware subtree, rendered recursively: the parent row, then its children inside a
/// ZERO-SPACING wrapper indented 18pt — whose leading border is ONE continuous guide line from
/// just below the parent's checkbox down through the last visible descendant (per the user's
/// wrapper-with-left-border design; per-row segments left dashed gaps at the inter-row margins).
/// The line carries a ~10pt hover band: hovering thickens the whole line; clicking folds THIS
/// parent and smoothly centers its row.
private struct TodoSubtree: View {
    /// A CLASS on purpose (flamegraph-driven): as a struct stored in EVERY recursive row view,
    /// SwiftUI's AttributeGraph deep-compared the embedded whole-feed `live` dictionary
    /// (Dictionary== over every ParsedTodo) on each row diff — rows × feed work that produced
    /// the 200-500ms frames on the real store. As a reference the graph compares a pointer.
    /// A fresh instance per panel body eval is fine: the Equatable host gate means the body
    /// only runs when content really changed, so rows should re-render then anyway.
    final class Ctx {
        let today: String
        let ownNoteKey: String
        let theme: Theme
        let live: [String: ParsedTodo]
        let nav: NativeDashNavModel?
        let toggle: (ParsedTodo) -> Void
        let open: (ParsedTodo) -> Void
        let fold: (ParsedTodo) -> Void
        let foldAndCenter: (ParsedTodo) -> Void

        init(today: String, ownNoteKey: String, theme: Theme, live: [String: ParsedTodo],
             nav: NativeDashNavModel?,
             toggle: @escaping (ParsedTodo) -> Void, open: @escaping (ParsedTodo) -> Void,
             fold: @escaping (ParsedTodo) -> Void, foldAndCenter: @escaping (ParsedTodo) -> Void) {
            self.today = today; self.ownNoteKey = ownNoteKey; self.theme = theme
            self.live = live; self.nav = nav
            self.toggle = toggle; self.open = open; self.fold = fold
            self.foldAndCenter = foldAndCenter
        }
    }

    let node: NativeDashPanel.RowNode
    let ctx: Ctx

    @State private var guideHover = false

    var body: some View {
        let t = ctx.live[NativeDashPanel.anchor(node.item.todo)] ?? node.item.todo
        let focused = ctx.nav.map {
            $0.active && $0.currentRow.map(NativeDashPanel.anchor) == NativeDashPanel.anchor(t)
        } ?? false
        VStack(alignment: .leading, spacing: 0) {
            TodoRow(todo: t, today: ctx.today, ownNoteKey: ctx.ownNoteKey, theme: ctx.theme,
                    focused: focused, foldable: node.item.foldable, folded: node.item.folded,
                    hiddenSubs: node.item.hidden,
                    onToggle: { ctx.toggle(t) },
                    onOpen: { ctx.open(t) },
                    onFold: { ctx.fold(t) })
                .id(NativeDashPanel.anchor(t))
            if !node.children.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(node.children.indices, id: \.self) { i in
                        TodoSubtree(node: node.children[i], ctx: ctx)
                    }
                }
                .padding(.leading, 18)
            }
        }
        .background(alignment: .topLeading) {
            if !node.children.isEmpty {
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(ctx.theme.accentGrey.opacity(guideHover ? 0.75 : 0.35))
                        .frame(width: guideHover ? 2 : 1)
                        .offset(x: guideHover ? 6.5 : 7)
                    Color.clear
                        .frame(width: 10)
                        .contentShape(Rectangle())
                        .offset(x: 2.5)
                        .handCursor()
                        .onHover { guideHover = $0 }
                        .onTapGesture { ctx.foldAndCenter(node.item.todo) }
                }
                .padding(.top, 25) // start just below the parent's checkbox (5 + 2 + 15 + gap)
                .padding(.bottom, 7) // stop just short of the last child's bottom padding
            }
        }
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
    @State private var sweeping = false // strike sweep IN FLIGHT → the masked pair is mounted

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            DashCheckbox(checked: todo.done, size: 15, action: onToggle)
                .padding(.top, 2) // .cc-dtodo-check margin-top
                .handCursor()
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
            .handCursor()
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
                .handCursor()
                .help("Fold / unfold sub-items")
            }
        }
        .onChange(of: todo.done, initial: true) { _, done in
            if strike < 0 {
                strike = done ? 1 : 0 // first render: settled, no animation
            } else {
                sweeping = true // mount the masked pair for the sweep, drop it after
                withAnimation(.easeInOut(duration: 0.26)) {
                    strike = done ? 1 : 0
                } completion: {
                    sweeping = false
                }
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
        // Indentation is STRUCTURAL now (TodoSubtree nests children in padded wrappers whose
        // borders are the continuous guide lines) — the row itself carries no indent.
    }

    /// Two copies of the SAME wrapped text with COMPLEMENTARY left/right masks — the struck copy
    /// replaces the plain one as the `strike` front sweeps (layering it on top let the
    /// full-strength base bleed through and killed the dimming). The struck presentation is the
    /// plain text with a PRONOUNCED text-color strike, then ONE opacity over the whole thing.
    /// SETTLED rows (the overwhelming majority) render ONE Text — the masked two-copy pair
    /// exists only while a sweep is actually animating (`sweeping`). Pixel-identical when
    /// settled (mask at 0/full ≡ plain/struck text), and it HALVES each row's standing
    /// view-graph footprint — the real-store profiles showed graph size is the perf currency.
    @ViewBuilder
    private var animatedTitle: some View {
        if !sweeping {
            if strike >= 0.999 {
                title(struck: true).opacity(hovering ? 0.62 : 0.45)
            } else {
                title(struck: false)
            }
        } else {
            sweepingTitle
        }
    }

    private var sweepingTitle: some View {
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
        let prefix = Text("\(todo.eventTitle) · ").foregroundStyle(theme.accentGrey)
        return Text("\(prefix)\(content)")
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
