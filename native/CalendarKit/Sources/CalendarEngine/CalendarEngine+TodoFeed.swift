// Engine access to the native TODO feed (webview retirement phase 1): builds TodoSources straight
// from the store (display-converted, like the webview's todoContexts did via JSON) and caches the
// fully-parsed index per (editGen, noteGen, today) — no serialization, no IPC. The native
// dashboard panels read THIS; dashboardDataJSON stays only for the webview fallback path.

import CalendarGeometry
import Foundation

extension CalendarEngine {
    /// A stamp that changes whenever the todo feed's inputs change (edits or note edits) —
    /// the native panels use it to tell THEIR OWN toggle's echo apart from external changes
    /// (the stay-in-place rule: a self-toggle must not re-sort the visible list).
    public var todoDataStamp: String { "\(caches.editGen)|\(caches.noteGen)" }


    /// The store as tokenizer inputs. Timed events + deadlines are anchor→view-tz converted (like
    /// the timeline) so the feed's dates match what's drawn; bands are all-day, no conversion.
    func todoSources() -> [TodoSource] {
        var out: [TodoSource] = []
        func wall(_ y: Int, _ m0: Int, _ d: Int, _ hour: CGFloat? = nil) -> String {
            var s = String(format: "%04d-%02d-%02d", y, m0 + 1, d)
            if let hour {
                let t = Int((hour * 60).rounded())
                s += String(format: "T%02d:%02d:00", (t / 60) % 24, t % 60)
            }
            return s
        }
        for e0 in items.events {
            let rf = items.richById[e0.id]
            let e = displayEvent(e0)
            out.append(TodoSource(id: e0.id, kind: "timed", title: e.title, color: e.color,
                                  tags: rf?.tags ?? [],
                                  start: wall(e.year, e.month, e.day, e.startHour),
                                  end: wall(e.year, e.month, e.day, min(e.endHour, 24)),
                                  notes: rf?.notes, occurrenceNotes: rf?.occurrenceNotes))
        }
        for b in items.bands {
            let rf = items.richById[b.id]
            out.append(TodoSource(id: b.id, kind: "band", title: b.title, color: b.color,
                                  tags: rf?.tags ?? [],
                                  start: wall(b.year, b.month, b.startDay),
                                  end: wall(b.year, b.month, b.endDay),
                                  notes: rf?.notes, occurrenceNotes: rf?.occurrenceNotes))
        }
        for d0 in items.deadlines {
            let rf = items.richById[d0.id]
            let d = displayDeadline(d0)
            let w = wall(d.year, d.month, d.day, d.hour)
            out.append(TodoSource(id: d0.id, kind: "deadline", title: d.title, color: d.color,
                                  tags: rf?.tags ?? [], start: w, end: w,
                                  notes: rf?.notes, occurrenceNotes: rf?.occurrenceNotes))
        }
        return out
    }

    /// The full parsed feed — event todos + every daily/weekly/monthly note's todos — cached per
    /// (editGen, noteGen, today). This is what the native panels section per view. A cache miss
    /// must stay OFF the frame path: gen-only staleness (an edit or an import/sync burst) serves
    /// the STALE feed and rebuilds ONCE, coalesced shortly after the burst — sync storms can
    /// bump editGen many times in a row, and each inline rebuild (several× slower in debug)
    /// landed as a dropped frame. Only a cold start (no cache — pre-warmed at launch anyway) or
    /// a day rollover builds inline.
    public func todoFeed(today: String) -> [ParsedTodo] {
        if let c = todoFeedCache, c.today == today {
            if c.gen == caches.editGen, c.noteGen == caches.noteGen {
                return c.todos
            }
            scheduleTodoFeedRefresh(today: today)
            return c.todos
        }
        todoFeedWork?.cancel(); todoFeedWork = nil
        return buildTodoFeed(today: today)
    }

    /// Immediate rebuild for a SELF-EDIT (a checkbox toggle the panel itself just made): the
    /// row's visuals must reflect the write on the very next frame — one inline parse per user
    /// click is fine; it's the burst/frame path that must never pay it.
    public func todoFeedRefreshNow(today: String) {
        todoFeedWork?.cancel(); todoFeedWork = nil
        _ = buildTodoFeed(today: today)
    }

    /// One rebuild, shortly after the last edit of a burst; wake() so the settled frame re-reads.
    private func scheduleTodoFeedRefresh(today: String) {
        guard todoFeedWork == nil else { return } // later edits ride the same window
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.todoFeedWork = nil
            _ = self.buildTodoFeed(today: today)
            self.wake()
        }
        todoFeedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    @discardableResult
    private func buildTodoFeed(today: String) -> [ParsedTodo] {
        var todos = TodoIndex.indexTodos(todoSources(), today: today)
        for (key, text) in items.dailyNotes.sorted(by: { $0.key < $1.key }) {
            if key.hasPrefix("week:") {
                let sun = String(key.dropFirst(5))
                todos.append(contentsOf: scopeNoteTodos(
                    key: key, anchor: sun, end: TodoIndex.addDuration(sun, 6, "d"),
                    title: "Weekly note · \(sun)", text: text, today: today
                ))
            } else if key.hasPrefix("month:") {
                let ym = String(key.dropFirst(6))
                todos.append(contentsOf: scopeNoteTodos(
                    key: key, anchor: "\(ym)-01", end: Self.monthEndIso(ym),
                    title: "Monthly note · \(ym)", text: text, today: today
                ))
            } else {
                todos.append(contentsOf: TodoIndex.parseDailyNoteTodos(date: key, notes: text,
                                                                       today: today))
            }
        }
        todoFeedCache = (caches.editGen, caches.noteGen, today, todos)
        return todos
    }

    /// A scope note's todos join the index like daily-note lines do — parsed against the range
    /// START (relative `due:` tokens resolve inside the range) then re-anchored: the soft-link key
    /// stays the storage key (toggling rewrites the right note), and undated items default their
    /// due to the range END ("finish within the week/month"). Mirrors dashboard.ts scopeNoteTodos.
    private func scopeNoteTodos(key: String, anchor: String, end: String, title: String,
                                text: String, today: String) -> [ParsedTodo] {
        TodoIndex.parseDailyNoteTodos(date: anchor, notes: text, today: today).map { t in
            var t = t
            t.dailyDate = key
            t.eventTitle = title
            if t.dueSource != "line" { t.due = end }
            return t
        }
    }

    /// "YYYY-MM" → its last day's ISO date.
    public static func monthEndIso(_ ym: String) -> String {
        let p = ym.split(separator: "-").compactMap { Int($0) }
        guard p.count == 2 else { return ym }
        return String(format: "%04d-%02d-%02d", p[0], p[1], daysInMonth(p[0], p[1] - 1))
    }
}
