// One conversation — the transcript (iMessage-style bubbles) + composer. Fills its container;
// the window (AssistantWindowView) provides the chrome. Extracted from the old in-window panel.

import SwiftUI

private let accent = Color(hex: 0xff3b6b)
private let bodySize: CGFloat = 14.5
private let smallSize: CGFloat = 12
private let sendDiameter: CGFloat = 28   // send circle; sits inside the pill with a ~6px inset

struct ConversationView: View {
    @Bindable var state: AssistantState
    let theme: Theme
    /// Callout mode: clear background so the popover's glass material shows through.
    var translucent: Bool = false


    /// Received-bubble gray — iMessage-like, adapts to the light/dark surface.
    private var receivedFill: Color { theme.dark ? Color(hex: 0x3B3B3D) : Color(hex: 0xE9E9EB) }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            composer
        }
        .background(translucent ? AnyShapeStyle(.clear)
            : theme.dark ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(theme.bg))
        .tint(accent)
    }

    // ── Transcript ────────────────────────────────────────────────────────────────
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if state.messages.isEmpty { emptyState }
                    ForEach(state.messages) { turn in row(turn) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
            .onChange(of: state.messages.count) { _, _ in scrollDown(proxy) }
            .onChange(of: state.messages.last?.text) { _, _ in scrollDown(proxy) }
        }
    }

    @ViewBuilder private func row(_ turn: ChatTurn) -> some View {
        switch turn.role {
        case .user:
            HStack { Spacer(minLength: 56); sentBubble(turn.text) }
        case .assistant:
            HStack { receivedBubble(MarkdownText(text: turn.text, theme: theme)); Spacer(minLength: 56) }
        case .typing:
            HStack { receivedBubble(TypingDots(color: theme.textMuted)); Spacer(minLength: 56) }
        case .action:
            actionChip(turn)
        case .confirm:
            if let req = turn.confirm { confirmCard(turn.id, req) }
        case .resume:
            resumeCard(turn)
        case .blocked:
            if let req = turn.blockedReq { blockedCard(turn.id, req) }
        }
    }

    /// A tool-activity bubble. Collapsed: a small centered pill. Tapping it expands the bubble
    /// ITSELF into a card of structured rows (Title / When / Color / results / …) — ported from the
    /// web app's ActionCard + ActionDetail, not a raw JSON dump.
    @ViewBuilder private func actionChip(_ turn: ChatTurn) -> some View {
        if turn.expanded, let d = turn.detail {
            expandedActionCard(turn, d)
        } else {
            collapsedActionPill(turn)
        }
    }

    private func collapsedActionPill(_ turn: ChatTurn) -> some View {
        HStack(spacing: 5) {
            if let icon = turn.icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
            Text(turn.text).font(.system(size: 11.5, weight: .medium)).lineLimit(2)
            if turn.detail != nil {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
        }
        .foregroundStyle(theme.textMuted)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(theme.textMuted.opacity(0.12), in: Capsule(style: .continuous))
        .contentShape(Capsule(style: .continuous))
        .onTapGesture {
            guard turn.detail != nil else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { state.toggleExpanded(turn.id) }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func expandedActionCard(_ turn: ChatTurn, _ d: ActionDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Head — same content as the pill; tapping collapses back.
            HStack(spacing: 6) {
                if let icon = turn.icon {
                    Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textMuted)
                }
                Text(turn.text).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text).lineLimit(2)
                Spacer(minLength: 8)
                Text(String(format: "%.1fs", d.seconds)).font(.system(size: 10)).foregroundStyle(theme.textMuted)
                Image(systemName: "chevron.up").font(.system(size: 8, weight: .bold)).foregroundStyle(theme.textMuted)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { state.toggleExpanded(turn.id) }
            }
            Divider()
            ActionDetailView(paramsJSON: d.params, resultJSON: d.result, theme: theme)
        }
        .padding(12)
        .frame(maxWidth: 340, alignment: .leading)
        .background(receivedFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .center)
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
    }

    private func scrollDown(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask about your calendar")
                .font(.system(size: bodySize, weight: .semibold)).foregroundStyle(theme.text)
            Text("e.g. “What's on my calendar this month?” or “When am I free next week?”")
                .font(.system(size: smallSize)).foregroundStyle(theme.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    /// "Continue" card shown when a turn hit the step ceiling — resumes the stashed run.
    private func resumeCard(_ turn: ChatTurn) -> some View {
        HStack(spacing: 6) {
            if turn.resumeConsumed {
                Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                Text("Continuing…").font(.system(size: 11.5, weight: .medium))
            } else {
                Image(systemName: "arrow.forward.circle.fill").font(.system(size: 11, weight: .semibold))
                Text("Continue").font(.system(size: 12, weight: .semibold))
            }
        }
        .foregroundStyle(turn.resumeConsumed ? theme.textMuted : accent)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background((turn.resumeConsumed ? theme.textMuted : accent).opacity(0.12), in: Capsule(style: .continuous))
        .contentShape(Capsule())
        .onTapGesture { if !turn.resumeConsumed { state.continueChat(turn.id) } }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Interactive delete-confirmation card: title + kind/date + Delete/Cancel, or a resolved state.
    private func confirmCard(_ turnId: UUID, _ req: ConfirmRequest) -> some View {
        let danger = Color(hex: 0xE0483B)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "trash").font(.system(size: 12, weight: .semibold)).foregroundStyle(danger)
                Text(req.occurrenceDate == nil ? "Delete “\(req.title)”?" : "Skip “\(req.title)”?")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
            }
            if let od = req.occurrenceDate {
                Text("Only the \(od) occurrence — the series stays.")
                    .font(.system(size: 11)).foregroundStyle(theme.textMuted)
            } else if !req.kind.isEmpty || !req.date.isEmpty {
                Text([req.kind.capitalized, req.date].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(theme.textMuted)
            }
            switch req.status {
            case .pending:
                HStack(spacing: 8) {
                    Button("Delete") { state.resolveDelete(turnId, confirmed: true) }
                        .buttonStyle(.bouncy)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .background(danger, in: Capsule())
                    Button("Cancel") { state.resolveDelete(turnId, confirmed: false) }
                        .buttonStyle(.bouncy)
                        .foregroundStyle(theme.text)
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .background(theme.textMuted.opacity(0.15), in: Capsule())
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.top, 2)
            case .confirmed:
                Label("Deleted", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(theme.textMuted)
            case .cancelled:
                Label("Cancelled", systemImage: "xmark.circle.fill")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(theme.textMuted)
            }
        }
        .padding(12)
        .frame(maxWidth: 300, alignment: .leading)
        .background(receivedFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Safety-check card: the auditor denied a mutating call. "Allow" is the user's explicit
    /// override — it re-runs the call unaudited and resumes; "Tell it what to do" hands control
    /// back to the composer.
    private func blockedCard(_ turnId: UUID, _ req: BlockedRequest) -> some View {
        let danger = Color(hex: 0xE0483B)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(danger)
                Text("Safety check blocked \(req.toolName)")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
            }
            if !req.reason.isEmpty {
                Text(req.reason).font(.system(size: 11)).foregroundStyle(theme.textMuted)
            }
            switch req.status {
            case .pending:
                HStack(spacing: 8) {
                    Button("Allow") { state.allowBlocked(turnId) }
                        .buttonStyle(.bouncy)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .background(danger, in: Capsule())
                    Button("Tell it what to do") {
                        state.dismissBlocked(turnId)
                        state.requestInputFocus()
                    }
                        .buttonStyle(.bouncy)
                        .foregroundStyle(theme.text)
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .background(theme.textMuted.opacity(0.15), in: Capsule())
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.top, 2)
            case .allowed:
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(theme.textMuted)
            case .dismissed:
                Label("Waiting for your guidance", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(theme.textMuted)
            }
        }
        .padding(12)
        .frame(maxWidth: 320, alignment: .leading)
        .background(receivedFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// iMessage-style bubble shape: rounded, with a tight "tail" corner on the sender's side.
    private func bubbleShape(isUser: Bool) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 18,
            bottomLeadingRadius: isUser ? 18 : 5,
            bottomTrailingRadius: isUser ? 5 : 18,
            topTrailingRadius: 18,
            style: .continuous)
    }

    private func sentBubble(_ text: String) -> some View {
        Text(text)
            .font(.system(size: bodySize))
            .foregroundStyle(.white)
            .textSelection(.enabled)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(accent, in: bubbleShape(isUser: true))
    }

    private func receivedBubble(_ content: some View) -> some View {
        content
            .font(.system(size: bodySize))
            .foregroundStyle(theme.text)
            .textSelection(.enabled)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(receivedFill, in: bubbleShape(isUser: false))
    }

    // ── Composer: a full-width glass-white pill with the send circle inset on the right ──
    // The input is an AppKit-backed editor (ComposerTextView): it rewraps at its real live width
    // (no stale sidebar-open wrap width), grows with the text up to `maxEditorHeight`, and scrolls
    // internally beyond that. Enter sends; Shift+Enter inserts a newline.
    @State private var editorHeight: CGFloat = 20
    private var maxEditorHeight: CGFloat { 6 * 18 }   // ~6 lines before the inner scroll takes over

    private var composer: some View {
        HStack(alignment: .center, spacing: 6) {   // center → send stays inside the pill's rounded cap
            ZStack(alignment: .topLeading) {
                if state.draft.isEmpty {
                    Text("Message the assistant…")
                        .font(.system(size: 14)).foregroundStyle(theme.textMuted)
                        .padding(.top, 2)
                        .allowsHitTesting(false)
                }
                ComposerTextView(text: $state.draft,
                                 textColor: NSColor(theme.text),
                                 focusToken: state.focusInput,
                                 onSend: { state.send() },
                                 onHeightChange: { h in
                                     if abs(h - editorHeight) > 0.5 { editorHeight = h }
                                 })
                    .frame(height: min(editorHeight, maxEditorHeight))
            }
            .padding(.leading, 16)
            .padding(.vertical, 9)
            sendButton
        }
        .padding(.trailing, 6)   // inset so the send circle sits comfortably inside the pill's edge
        .animation(.easeOut(duration: 0.12), value: editorHeight)
        // Frosted-glass pill (radius = half the height, so it stays a pill as it grows) + soft shadow.
        // Translucent material lets the surface behind blur through, rather than a solid fill.
        .background {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.12), radius: 5, x: 0, y: 1.5)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private var sendButton: some View {
        let empty = state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let disabled = !state.busy && empty
        return Button {
            if state.busy { state.stop() } else if !empty { state.send() }
        } label: {
            Image(systemName: state.busy ? "stop.fill" : "arrow.up")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: sendDiameter, height: sendDiameter)
                .background(accent, in: Circle())
                .opacity(disabled ? 0.4 : 1)
        }
        .buttonStyle(.bouncy)
        .disabled(disabled)
        .help(state.busy ? "Stop" : "Send")
        .animation(.easeInOut(duration: 0.12), value: state.busy)
    }
}

/// The expanded action card's body: the tool's request/result rendered as REAL elements —
/// label/value rows, color swatches, tag pills, result links — dispatched on the payload's shape.
/// Ported from the web app's ActionDetail (AssistantPanel.tsx); raw JSON only as a last resort.
private struct ActionDetailView: View {
    let paramsJSON: String
    let resultJSON: String
    let theme: Theme

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                 "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    var body: some View {
        let args = JSONValue.parse(paramsJSON).asObject ?? [:]
        let res = JSONValue.parse(resultJSON).asObject ?? [:]
        VStack(alignment: .leading, spacing: 6) {
            content(args: args, res: res)
        }
    }

    @ViewBuilder private func content(args: [String: JSONValue], res: [String: JSONValue]) -> some View {
        if let err = res["error"]?.stringValue {
            row("Error") { Text(err).foregroundStyle(Color(hex: 0xE0483B)) }
        } else if args["title"] != nil, args["date"] != nil {                    // create_event
            eventRows(args)
        } else if let patch = args["patch"]?.asObject {                          // update_event
            patchRows(patch)
        } else if let results = res["results"]?.arrayValue {                     // web_search
            searchRows(results)
        } else if let url = res["url"]?.stringValue, res["text"] != nil {        // web_open
            webOpenRows(url: url, title: res["title"]?.stringValue,
                        text: res["text"]?.stringValue ?? "")
        } else if let events = res["events"]?.arrayValue {                       // list_events
            listRows(res, events: events)
        } else if let todos = res["todos"]?.arrayValue {                         // list_todos
            todoRows(res, todos: todos)
        } else if res["zoom"] != nil || res["focusedMonth"] != nil {             // set_view / screen
            viewRows(res)
        } else if let key = args["key"]?.stringValue {                           // remember / forget
            row("Key") { plain(key) }
            if let v = args["value"] { row("Value") { plain(compact(v)) } }
        } else if res["staged"]?.boolValue == true {                             // delete (resolved)
            row("Event") { plain(res["title"]?.stringValue ?? "") }
            row("Date") { plain(res["date"]?.stringValue ?? "") }
        } else {                                                                 // fallback
            Text(paramsJSON == "{}" ? resultJSON : paramsJSON)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.textMuted).lineLimit(10).textSelection(.enabled)
        }
    }

    // ── Per-shape renderers ────────────────────────────────────────────────────────

    /// Event-shaped args (create_event): Title / Kind / When / Color / Lane / Tags / Notes.
    @ViewBuilder private func eventRows(_ a: [String: JSONValue]) -> some View {
        row("Title") { plain(a["title"]?.stringValue ?? "") }
        if let kind = a["kind"]?.stringValue { row("Kind") { badge(kind) } }
        row("When") { plain(whenLabel(a)) }
        if let color = a["color"]?.stringValue { row("Color") { swatch(color) } }
        if let lane = (a["promoteTrack"] ?? a["track"])?.intValue { row("Lane") { plain("\(lane)") } }
        if let tags = a["tags"]?.arrayValue?.compactMap({ $0.stringValue }), !tags.isEmpty {
            row("Tags") { tagPills(tags) }
        }
        if let notes = a["notes"]?.stringValue, !notes.isEmpty {
            row("Notes") { plain(String(notes.prefix(200))).foregroundStyle(theme.textMuted) }
        }
    }

    /// update_event: one row per patched field.
    @ViewBuilder private func patchRows(_ patch: [String: JSONValue]) -> some View {
        ForEach(patch.keys.sorted(), id: \.self) { key in
            row(key.capitalized) {
                if key == "color", let c = patch[key]?.stringValue { swatch(c) }
                else if key == "tags", let t = patch[key]?.arrayValue?.compactMap({ $0.stringValue }) { tagPills(t) }
                else { plain(compact(patch[key] ?? .null)) }
            }
        }
    }

    @ViewBuilder private func searchRows(_ results: [JSONValue]) -> some View {
        ForEach(Array(results.prefix(6).enumerated()), id: \.offset) { _, r in
            if let urlStr = r["url"]?.stringValue, let url = URL(string: urlStr) {
                Link(r["title"]?.stringValue ?? urlStr, destination: url)
                    .font(.system(size: 11.5)).lineLimit(1)
            }
        }
    }

    @ViewBuilder private func webOpenRows(url: String, title: String?, text: String) -> some View {
        row("Page") {
            if let u = URL(string: url) { Link(title?.isEmpty == false ? title! : url, destination: u)
                .font(.system(size: 11.5)).lineLimit(1) }
            else { plain(url) }
        }
        Text(String(text.prefix(400)) + (text.count > 400 ? "…" : ""))
            .font(.system(size: 11)).foregroundStyle(theme.textMuted).lineLimit(6).textSelection(.enabled)
    }

    @ViewBuilder private func listRows(_ res: [String: JSONValue], events: [JSONValue]) -> some View {
        if let year = res["year"]?.intValue { row("Year") { plain("\(year)") } }
        row("Items") { plain("\(res["count"]?.intValue ?? events.count)") }
        ForEach(Array(events.prefix(6).enumerated()), id: \.offset) { _, ev in
            HStack(spacing: 6) {
                if let c = ev["color"]?.stringValue {
                    Circle().fill(theme.eventColor(c)).frame(width: 6, height: 6)
                }
                Text(ev["title"]?.stringValue ?? "")
                    .font(.system(size: 11)).foregroundStyle(theme.text).lineLimit(1)
                Spacer(minLength: 4)
                Text(ev["date"]?.stringValue ?? ev["start"]?.stringValue ?? "")
                    .font(.system(size: 10)).foregroundStyle(theme.textMuted)
            }
        }
        if events.count > 6 {
            Text("…and \(events.count - 6) more").font(.system(size: 10)).foregroundStyle(theme.textMuted)
        }
    }

    @ViewBuilder private func todoRows(_ res: [String: JSONValue], todos: [JSONValue]) -> some View {
        row("Items") { plain("\(res["count"]?.intValue ?? todos.count)") }
        ForEach(Array(todos.prefix(6).enumerated()), id: \.offset) { _, t in
            HStack(spacing: 6) {
                Image(systemName: t["done"]?.boolValue == true ? "checkmark.square" : "square")
                    .font(.system(size: 9)).foregroundStyle(theme.textMuted)
                Text(t["text"]?.stringValue ?? "")
                    .font(.system(size: 11)).foregroundStyle(theme.text).lineLimit(1)
                Spacer(minLength: 4)
                Text(t["due"]?.stringValue ?? "")
                    .font(.system(size: 10)).foregroundStyle(theme.textMuted)
            }
        }
        if todos.count > 6 {
            Text("…and \(todos.count - 6) more").font(.system(size: 10)).foregroundStyle(theme.textMuted)
        }
    }

    @ViewBuilder private func viewRows(_ res: [String: JSONValue]) -> some View {
        if let y = res["year"]?.intValue { row("Year") { plain("\(y)") } }
        if let z = res["zoom"]?.stringValue { row("Zoom") { badge(z) } }
        if let m = res["focusedMonth"]?.intValue, Self.months.indices.contains(m) {
            row("Month") { plain(Self.months[m]) }
        }
    }

    // ── Row + element helpers ──────────────────────────────────────────────────────

    private func row(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(theme.textMuted)
                .frame(width: 48, alignment: .trailing)
            value().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func plain(_ s: String) -> Text {
        Text(s).font(.system(size: 11.5)).foregroundStyle(theme.text)
    }

    private func badge(_ s: String) -> some View {
        Text(s).font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.textMuted)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(theme.textMuted.opacity(0.14), in: Capsule())
    }

    private func swatch(_ color: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(theme.eventColor(color)).frame(width: 9, height: 9)
            plain(color)
        }
    }

    private func tagPills(_ tags: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(tags.prefix(5), id: \.self) { t in badge("#" + t) }
        }
    }

    /// "Jul 18 · 09:00–10:00" style summary from create_event args.
    private func whenLabel(_ a: [String: JSONValue]) -> String {
        func pretty(_ iso: String?) -> String {
            guard let iso, let (_, m, d) = parseDate(iso), Self.months.indices.contains(m)
            else { return iso ?? "" }
            return "\(Self.months[m]) \(d)"
        }
        let date = pretty(a["date"]?.stringValue)
        switch a["kind"]?.stringValue {
        case "band":
            let end = a["endDate"]?.stringValue.map { pretty($0) }
            return end != nil && end != date ? "\(date) – \(end!)" : date
        case "deadline":
            let t = a["start"]?.stringValue ?? "17:00"
            return "\(date) · \(t)"
        default:
            let s = a["start"]?.stringValue ?? ""
            let e = a["end"]?.stringValue ?? ""
            if s.isEmpty { return date }
            return "\(date) · \(s)\(e.isEmpty ? "" : "–\(e)")"
        }
    }

    private func compact(_ v: JSONValue) -> String {
        switch v {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "yes" : "no"
        case .null: return "—"
        case .array(let a):
            let strs = a.compactMap { $0.stringValue }
            return strs.count == a.count ? strs.joined(separator: ", ") : "\(a.count) items"
        case .object:
            return String(v.jsonString.prefix(120))
        }
    }
}

/// Three blinking dots shown while the assistant's reply is in flight.
private struct TypingDots: View {
    let color: Color
    @State private var on = false
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle().frame(width: 6, height: 6).foregroundStyle(color)
                    .opacity(on ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2), value: on)
            }
        }
        .onAppear { on = true }
    }
}
