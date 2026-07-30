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
    var onOpen: (String) -> Void // event todo row → open that event

    @State private var doneOpen: Set<String> = [] // per-view completed expansion (session-scoped)
    private static let doneShow = 10

    var body: some View {
        let today = Self.todayIso()
        let (start, end) = range
        let word = scope == "week" ? "this week" : "this month"
        let prefs: TodoFeedPrefs = scope == "week" ? .week : .month
        let todos = engine.todoFeed(today: today)
        let sections = TodoFeed.rangeSections(todos, start: start, end: end, word: word,
                                              prefs: prefs)
        let kids = TodoFeed.childrenIndex(todos)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if prefs.deadlines {
                    deadlineSection(start: start, end: end, today: today)
                }
                ForEach(sections, id: \.key) { s in
                    section(s, kids: kids, today: today)
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
                         today: String) -> some View {
        let capped = s.done && s.items.count > Self.doneShow
        let open = !capped || doneOpen.contains(s.key)
        let roots = open ? s.items : Array(s.items.prefix(Self.doneShow))
        let rows: [ParsedTodo] = roots.flatMap { TodoFeed.subtree($0, kids) }
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: s.title, count: s.items.count,
                          hidden: capped && !open ? s.items.count - Self.doneShow : 0,
                          chevron: capped, open: open, theme: theme) {
                if open { doneOpen.remove(s.key) } else { doneOpen.insert(s.key) }
            }
            ForEach(rows.indices, id: \.self) { i in
                let t = rows[i]
                TodoRow(todo: t, today: today, theme: theme,
                        onToggle: { toggle(t) },
                        onOpen: { openRow(t) })
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
    }

    private func toggle(_ t: ParsedTodo) {
        Self.toggleTodo(engine, t)
    }

    private func openRow(_ t: ParsedTodo) {
        if t.source == "event" {
            onOpen(t.eventId)
        }
        // Daily/scope rows: the note-jump flow (fly to the note + focus the line) arrives with the
        // native NOTE tab in phase 3 — until then the row's checkbox is the interaction.
    }

    static func clockNow() -> String {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
        return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// "today" / "3d over" / "in 3d" / the date — a compact relative-due label.
    static func relDue(_ today: String, _ iso: String) -> String {
        guard iso.count >= 10 else { return iso }
        let d = String(iso.prefix(10))
        if d == today { return "today" }
        let days = daysBetween(today, d)
        if days == 1 { return "tomorrow" }
        if days == -1 { return "yesterday" }
        if days < 0 { return "\(-days)d over" }
        if days <= 14 { return "in \(days)d" }
        return d
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
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(theme.text.opacity(0.55))
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

/// One deadline row: color dot, title, relative-due + time label; click navigates to it.
private struct DeadlineRowView: View {
    let deadline: Deadline
    let label: String
    let theme: Theme
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 6) {
                Circle().fill(theme.eventBorder(deadline.color)).frame(width: 7, height: 7)
                Text(deadline.title.isEmpty ? "(untitled)" : deadline.title)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.text.opacity(0.5))
            }
        }
        .buttonStyle(.plain)
    }
}

/// One todo row: checkbox, indented text with a provenance prefix, and compact meta chips
/// (priority bangs, relative due, tags). Toggling flips the source line in place.
private struct TodoRow: View {
    let todo: ParsedTodo
    let today: String
    let theme: Theme
    var onToggle: () -> Void
    var onOpen: () -> Void

    var body: some View {
        let overdue = !todo.done && TodoFeed.opDate(todo) < today
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            DashCheckbox(checked: todo.done, size: 13, action: onToggle)
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 0) {
                        if todo.parentLine == nil, !todo.eventTitle.isEmpty,
                           todo.source == "event" {
                            Text("\(todo.eventTitle) · ")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.text.opacity(0.4))
                        }
                        Text(todo.text)
                            .font(.system(size: 12))
                            .strikethrough(todo.done, color: theme.text.opacity(0.5))
                            .foregroundStyle(theme.text.opacity(todo.done ? 0.4 : 0.78))
                    }
                    .lineLimit(2)
                    HStack(spacing: 6) {
                        if let p = todo.priority {
                            Text(String(repeating: "!", count: p))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(theme.eventBorder("red"))
                        }
                        if !todo.done {
                            Text(NativeDashPanel.relDue(today, TodoFeed.opDate(todo)))
                                .font(.system(size: 10))
                                .foregroundStyle(overdue ? theme.eventBorder("red")
                                    : theme.text.opacity(0.5))
                        }
                        ForEach(todo.tags.prefix(3), id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.system(size: 10))
                                .foregroundStyle(theme.accentGrey)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, CGFloat(min(todo.indent, 6)) * 16)
    }
}
