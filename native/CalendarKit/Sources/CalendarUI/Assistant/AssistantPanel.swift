// The assistant dropdown — a Liquid-Glass, minimal panel resembling the web app's AI panel
// but native to macOS 26. No header bar/divider: the top controls are round glass buttons like
// the toolbar's. Big soft corners, no hairline borders, a large glass-backed composer.

import SwiftUI

// Fixed light palette so the white-frosted panel reads consistently regardless of app theme.
private let inkColor = Color(hex: 0x1c1c1e)        // primary text
private let greyColor = Color(hex: 0x6b6b70)       // secondary text
private let userBubble = Color(hex: 0x2b2b2e)      // dark user bubble
private let accent = Color(hex: 0xff3b6b)

// Standardized sizes — a touch larger than the web panel.
private let bodySize: CGFloat = 14.5
private let smallSize: CGFloat = 12

private let panelRadius: CGFloat = 28
// Single-line composer height (font 15 + 13pt vertical padding). The send button matches it.
private let fieldHeight: CGFloat = 44

struct AssistantPanel: View {
    @Bindable var state: AssistantState
    var onClose: () -> Void

    @AppStorage(AssistantModels.defaultsKey) private var model = AssistantModels.fallback
    @FocusState private var inputFocused: Bool

    private var panelShape: RoundedRectangle { RoundedRectangle(cornerRadius: panelRadius, style: .continuous) }

    var body: some View {
        VStack(spacing: 0) {
            header
            transcript
            composer
        }
        .frame(width: 460, height: 640)
        .background {                       // white-frosted glass, no border
            ZStack {
                panelShape.fill(.regularMaterial)
                panelShape.fill(.white.opacity(0.30))
            }
        }
        .clipShape(panelShape)
        .shadow(color: .black.opacity(0.20), radius: 34, x: 0, y: 16)
        .tint(accent)
        .onAppear { inputFocused = true }
    }

    // ── Header: minimal, floating round glass buttons (no title, no divider) ─────────
    private var header: some View {
        HStack(spacing: 8) {
            modelMenu
            Spacer()
            glassIcon("square.and.pencil", help: "New chat") { state.newChat() }
            glassIcon("xmark", help: "Close", action: onClose)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var modelMenu: some View {
        Menu {
            ForEach(AssistantModels.all) { m in
                Button {
                    model = m.id
                } label: {
                    if m.id == model { Label("\(m.label) · \(m.note)", systemImage: "checkmark") }
                    else { Text("\(m.label) · \(m.note)") }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(AssistantModels.label(for: model)).font(.system(size: smallSize, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .tint(inkColor)
        .fixedSize()
        .help("Model")
    }

    /// Top-right controls: round glass buttons (like the toolbar), with a dark (non-accent)
    /// glyph and a generous size. `.tint(inkColor)` overrides the panel's accent tint.
    private func glassIcon(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .tint(inkColor)
        .help(help)
    }

    // ── Transcript ────────────────────────────────────────────────────────────────
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if state.messages.isEmpty { emptyState }
                    ForEach(state.messages) { turn in row(turn) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
            .onChange(of: state.messages.count) { _, _ in scrollDown(proxy) }
            .onChange(of: state.messages.last?.text) { _, _ in scrollDown(proxy) }
        }
    }

    private func scrollDown(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask about your calendar")
                .font(.system(size: bodySize, weight: .semibold)).foregroundStyle(inkColor)
            Text("e.g. “What's on my calendar this month?” or “When am I free next week?”")
                .font(.system(size: smallSize)).foregroundStyle(greyColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    @ViewBuilder private func row(_ turn: ChatTurn) -> some View {
        switch turn.role {
        case .user:
            HStack { Spacer(minLength: 44); userBubbleView(turn.text) }
        case .assistant:
            HStack { asstBubbleView(turn.text); Spacer(minLength: 44) }
        case .typing:
            HStack {
                TypingDots().padding(.horizontal, 14).padding(.vertical, 12)
                    .background { Color.clear.glassEffect(.regular, in: bubbleShape) }
                Spacer(minLength: 44)
            }
        }
    }

    private var bubbleShape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }

    private func userBubbleView(_ text: String) -> some View {
        Text(text)
            .font(.system(size: bodySize))
            .foregroundStyle(.white)
            .textSelection(.enabled)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(userBubble, in: bubbleShape)
    }

    private func asstBubbleView(_ text: String) -> some View {
        Text(Self.markdown(text))
            .font(.system(size: bodySize))
            .foregroundStyle(inkColor)
            .textSelection(.enabled)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background { Color.clear.glassEffect(.regular, in: bubbleShape) }
    }

    /// Inline markdown (bold/italic/code/links) with newlines preserved.
    private static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    // ── Composer: large, rounded, glass-backed field + glass send button ─────────────
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message the assistant…", text: $state.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(inkColor)
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit { state.send() }
                .padding(.horizontal, 18).padding(.vertical, 13)
                .background { Color.clear.glassEffect(.regular, in: fieldShape) }
            sendButton
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 16)
    }

    private var fieldShape: RoundedRectangle { RoundedRectangle(cornerRadius: 22, style: .continuous) }

    private var sendButton: some View {
        // Built as an exact-size glass circle (not `.buttonStyle(.glass)`, whose intrinsic
        // padding inflates it past the field) so its height equals the composer field's.
        let empty = state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let disabled = !state.busy && empty
        return Image(systemName: state.busy ? "stop.fill" : "arrow.up")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: fieldHeight, height: fieldHeight)
            .background { Color.clear.glassEffect(.regular.tint(accent), in: Circle()) }
            .opacity(disabled ? 0.45 : 1)
            .contentShape(Circle())
            .onTapGesture { if state.busy { state.stop() } else if !empty { state.send() } }
            .help(state.busy ? "Stop" : "Send")
            .animation(.easeInOut(duration: 0.12), value: state.busy)
    }
}

/// Three blinking dots shown while the assistant's reply is in flight.
private struct TypingDots: View {
    @State private var on = false
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle().frame(width: 6, height: 6).foregroundStyle(greyColor)
                    .opacity(on ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2), value: on)
            }
        }
        .onAppear { on = true }
    }
}
