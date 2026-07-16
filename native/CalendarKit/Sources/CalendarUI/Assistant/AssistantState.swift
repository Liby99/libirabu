// The assistant conversation: transcript + send/stop/newChat, the system prompt, and the
// read-only calendar-context block built from the engine's public read APIs. v1 has no tool
// loop — the calendar snapshot is injected into the system context so the model can *discuss*
// the calendar; mutations + a real tool loop are Phase 2.

import Foundation
import Observation
import CalendarGeometry
import CalendarEngine

@MainActor
@Observable
final class AssistantState {
    var messages: [ChatTurn] = []
    var draft: String = ""
    var busy: Bool = false

    /// Set once by CalendarView (.onAppear). The panel reads live calendar context from it.
    unowned var engine: CalendarEngine?

    @ObservationIgnored private var task: Task<Void, Never>?

    /// The model id currently selected in the picker (persisted by the panel via @AppStorage).
    private var model: String {
        UserDefaults.standard.string(forKey: AssistantModels.defaultsKey) ?? AssistantModels.fallback
    }

    // ── Actions ─────────────────────────────────────────────────────────────────────

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        draft = ""
        messages.append(ChatTurn(role: .user, text: text))
        messages.append(ChatTurn(role: .typing, text: ""))
        busy = true

        let wire = buildWireMessages()
        let model = self.model
        task = Task { [weak self] in
            let result: Result<ChatResponse, Error>
            do { result = .success(try await LLMClient.chat(messages: wire, model: model)) }
            catch { result = .failure(error) }
            guard let self, !Task.isCancelled else { return }
            switch result {
            case .success(let resp):
                let body = resp.content.trimmingCharacters(in: .whitespacesAndNewlines)
                self.replaceTyping(with: body.isEmpty ? "_(no response)_" : body)
            case .failure(let error):
                self.replaceTyping(with: "⚠️ " + (error.localizedDescription))
            }
            self.busy = false
        }
    }

    func stop() {
        task?.cancel(); task = nil
        messages.removeAll { $0.role == .typing }
        busy = false
    }

    func newChat() {
        task?.cancel(); task = nil
        messages.removeAll()
        busy = false
    }

    private func replaceTyping(with text: String) {
        if let i = messages.lastIndex(where: { $0.role == .typing }) {
            messages[i] = ChatTurn(role: .assistant, text: text)
        } else {
            messages.append(ChatTurn(role: .assistant, text: text))
        }
    }

    // ── Prompt assembly ──────────────────────────────────────────────────────────────

    private func buildWireMessages() -> [ChatMessage] {
        var wire: [ChatMessage] = [ChatMessage(role: "system", content: systemPrompt())]
        for turn in messages {
            switch turn.role {
            case .user:      wire.append(ChatMessage(role: "user", content: turn.text))
            case .assistant: wire.append(ChatMessage(role: "assistant", content: turn.text))
            case .typing:    break
            }
        }
        return wire
    }

    private func systemPrompt() -> String {
        let today = Self.dateFmt.string(from: Date())
        var p = """
        You are the assistant embedded in the user's personal calendar app. Today is \(today).

        The calendar has three kinds of items:
        • timed event — has a start and end time on a single day.
        • band — an all-day bar spanning one or more days on a monthly track lane.
        • deadline — a single due moment (a day + time).

        You can currently DISCUSS and answer questions about the user's calendar (read-only). \
        You cannot yet create, edit, delete, or navigate — say so plainly if asked to.

        Respond in concise GitHub-flavored Markdown. Do not use tables or raw HTML.

        """
        p += "\n" + calendarContext()
        return p
    }

    /// A compact, read-only snapshot of what's on the calendar right now.
    private func calendarContext() -> String {
        guard let engine else { return "Current calendar context is unavailable." }
        let zoom = engine.isDayLevel ? "day" : engine.isWeekLevel ? "week" : engine.isMonthLevel ? "month" : "year"
        var lines = ["Current view: \(zoom) view, focused on \(Self.months[safe: engine.focus] ?? "?") \(engine.year)."]

        var items: [(sort: Int, line: String)] = []
        for e in engine.viewEvents() {
            items.append((key(e.year, e.month, e.day),
                "- [timed] \(md(e.month, e.day)) \(hhmm(e.startHour))–\(hhmm(e.endHour)) \(e.title) (\(e.color))"))
        }
        for b in engine.viewBands() {
            items.append((key(b.year, b.month, b.startDay),
                "- [band] \(md(b.month, b.startDay))–\(md(b.month, b.endDay)) \(b.title) (\(b.color))"))
        }
        for d in engine.viewDeadlines() {
            items.append((key(d.year, d.month, d.day),
                "- [deadline] \(md(d.month, d.day)) \(hhmm(d.hour)) \(d.title) (\(d.color))"))
        }
        items.sort { $0.sort < $1.sort }

        if items.isEmpty {
            lines.append("There are no events in the current range.")
        } else {
            let capped = items.prefix(80)
            lines.append("Events in view (\(items.count)):")
            lines.append(contentsOf: capped.map(\.line))
            if items.count > capped.count { lines.append("…and \(items.count - capped.count) more.") }
        }
        return lines.joined(separator: "\n")
    }

    // ── Formatting helpers ───────────────────────────────────────────────────────────
    private func key(_ y: Int, _ m: Int, _ d: Int) -> Int { y * 10000 + m * 100 + d }
    private func md(_ month: Int, _ day: Int) -> String { "\(Self.months[safe: month] ?? "?") \(day)" }
    private func hhmm(_ h: CGFloat) -> String {
        let total = max(0, Int((h * 60).rounded())); return String(format: "%02d:%02d", (total / 60) % 24, total % 60)
    }

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMMM d, yyyy"; return f
    }()
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
