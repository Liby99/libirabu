// The onboarding "tutorial" — a simple carousel of animated GIFs with captions. Shown once on first
// launch (see CalendarView's @AppStorage "cc.tutorial.seen") and re-openable from Help ▸ Tutorial. The
// body isn't really a tutorial: each slide is just a GIF demoing one gesture/feature.

import SwiftUI
import AppKit

/// One carousel slide: a GIF (loaded by name from the bundle's `tutorial/` folder) + a caption.
struct TutorialSlide: Identifiable {
    let id = UUID()
    let gif: String        // resource name without extension (see Resources/tutorial/README.md)
    let caption: String
}

struct TutorialView: View {
    let theme: Theme
    var ui: CalendarUIState        // reads/writes ui.tutorialIndex (also driven by the key monitor)
    var onClose: () -> Void

    static let slides: [TutorialSlide] = [
        .init(gif: "drag-create",    caption: "Drag on the calendar to create events."),
        .init(gif: "pinch-zoom",     caption: "Pinch to zoom into monthly, weekly, or daily view."),
        .init(gif: "ai-assistant",   caption: "Click the AI button to let AI help you manage your calendar."),
        .init(gif: "markdown-notes", caption: "Edit markdown notes in events or the daily notepad to add TODO items."),
    ]

    private var idx: Int { min(max(0, ui.tutorialIndex), Self.slides.count - 1) }
    private var isLast: Bool { idx == Self.slides.count - 1 }

    var body: some View {
        ZStack {
            // Dimmed backdrop — the CatcherView's modal guards also block the canvas behind it. Tap closes.
            Color.black.opacity(0.28).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            VStack(spacing: 18) {
                HStack {
                    Text("Getting Started").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textMuted)
                    Spacer()
                    Button { onClose() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(theme.textMuted)
                        .help("Close")
                }

                // The GIF stage — fixed 16:9 so slides don't jump as sizes vary.
                GIFStage(name: Self.slides[idx].caption.isEmpty ? "" : Self.slides[idx].gif, theme: theme)
                    .frame(width: 560, height: 315)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.sep.opacity(0.4), lineWidth: 1))
                    .id(idx)   // swap the NSImageView when the slide changes
                    .transition(.opacity)

                Text(Self.slides[idx].caption)
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(theme.text)
                    .multilineTextAlignment(.center)
                    .frame(width: 480)
                    .fixedSize(horizontal: false, vertical: true)

                // Page dots
                HStack(spacing: 7) {
                    ForEach(Self.slides.indices, id: \.self) { i in
                        Circle().fill(i == idx ? theme.text : theme.text.opacity(0.22))
                            .frame(width: 6, height: 6)
                            .onTapGesture { go(to: i) }
                    }
                }

                HStack {
                    Button("Back") { go(to: idx - 1) }
                        .disabled(idx == 0)
                    Spacer()
                    Button(isLast ? "Done" : "Next") { if isLast { onClose() } else { go(to: idx + 1) } }
                }
                .buttonStyle(.bordered)
                .frame(width: 560)
            }
            .padding(28)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(theme.sep.opacity(0.5), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 28, y: 10)
            .fixedSize()
            .animation(.easeOut(duration: 0.18), value: ui.tutorialIndex)
        }
    }

    private func go(to i: Int) { ui.tutorialIndex = min(max(0, i), Self.slides.count - 1) }
}

/// The GIF display area: an animating NSImageView loaded from the bundle, or a placeholder when the GIF
/// isn't present yet (so the carousel is fully usable before the assets are added).
private struct GIFStage: View {
    let name: String
    let theme: Theme
    var body: some View {
        if let url = Bundle.module.url(forResource: name, withExtension: "gif", subdirectory: "tutorial"),
           let img = NSImage(contentsOf: url) {
            AnimatedGIFView(image: img)
        } else {
            ZStack {
                Rectangle().fill(theme.text.opacity(0.06))
                VStack(spacing: 10) {
                    Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 30)).foregroundStyle(theme.textMuted)
                    Text("Demo GIF").font(.system(size: 12)).foregroundStyle(theme.textMuted)
                }
            }
        }
    }
}

/// Wraps NSImageView so a multi-frame GIF actually animates (SwiftUI.Image renders only the first frame).
private struct AnimatedGIFView: NSViewRepresentable {
    let image: NSImage
    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.image = image
        v.animates = true
        v.imageScaling = .scaleProportionallyUpOrDown
        v.canDrawSubviewsIntoLayer = true
        return v
    }
    func updateNSView(_ v: NSImageView, context: Context) {
        if v.image !== image { v.image = image; v.animates = true }
    }
}
