// The day-view daily dashboard: a transparent WKWebView hosting the bundled dashboard (see
// webeditor/dashboard.ts). Reuses the web's TODO index + day-relative sectioning; Swift pushes the
// data (dashboardDataJSON), the JS posts back {toggle|open|ready}. Sits in the dashboard content
// region to the right of the day-view timeline (below the "DAILY DASHBOARD" title bars drawn by
// SceneRenderer). Background transparent so the window glass shows through.
//
// CAROUSEL: the day pager (finger-following) drives a continuous animation. The engine isn't
// @Observable — the canvas redraws every frame via TimelineView — so a per-frame `CarouselDriver`
// placed inside that TimelineView pushes {from,to,dir,p} to the web view each frame (CK.tick), which
// slides + cross-fades two day panels in CSS (both reliable in web content, unlike SwiftUI .opacity
// on a WKWebView). The web view itself lives in a hit-testable overlay so checkbox/open clicks work.

import SwiftUI
import WebKit
import AppKit
import CalendarGeometry
import CalendarEngine

/// Shared handle to the calendar's input catcher, so the dashboard web view can forward the gestures
/// it shouldn't own (horizontal day-paging scroll + pinch-zoom) back to the calendar. Set by the
/// InputCatcher when its NSView is created.
@MainActor final class GestureForwarder { weak var catcher: NSView? }

/// The dashboard's WKWebView, which forwards horizontal scroll + pinch to the calendar instead of
/// eating them. VERTICAL scroll stays here (the TODO list, with native rubber-band); horizontal
/// scroll pages days and pinch zooms — both handled by the InputCatcher underneath.
final class PassThroughWebView: WKWebView {
    weak var forwarder: GestureForwarder?
    private enum Axis { case undecided, horizontal, vertical }
    private var axis: Axis = .undecided

    override func scrollWheel(with e: NSEvent) {
        // Lock the axis ONCE per gesture (at the first real delta) and route the WHOLE gesture — its
        // zero-delta .ended AND its momentum tail included — to a single target. Routing per-event
        // instead would send the delta-less .ended to the wrong place, so the day-pager scroll view
        // never gets a clean gesture end and snaps instead of decelerating (momentum dies on lift).
        if e.phase.contains(.began) || e.phase.contains(.mayBegin) { axis = .undecided }
        if axis == .undecided {
            let dx = abs(e.scrollingDeltaX), dy = abs(e.scrollingDeltaY)
            if dx > 0 || dy > 0 { axis = dx > dy ? .horizontal : .vertical }
        }
        // Horizontal → the calendar (day paging, with native momentum); vertical/undecided → the web
        // list (native rubber-band).
        if axis == .horizontal, let c = forwarder?.catcher {
            c.scrollWheel(with: e)
        } else {
            super.scrollWheel(with: e)
        }
    }
    // Pinch is always the calendar's (zoom), never the web view's page magnification.
    override func magnify(with e: NSEvent) { (forwarder?.catcher ?? superview)?.magnify(with: e) }
}

/// Shared conduit: the web view registers itself here; the per-frame driver pushes carousel ticks.
@MainActor final class DashboardCarousel {
    weak var web: WKWebView?
    private var lastKey = ""
    private var lastCall: String?   // the most recent CK.tick(...), replayed once the page is ready
    private var ready = false
    func register(_ w: WKWebView?) { web = w; lastKey = ""; lastCall = nil; ready = false }
    /// The page signalled ready — replay the latest tick so its reveal/carousel state lands even if
    /// the driver's earlier tick fired before CK was defined (which would otherwise be lost).
    func markReady() { ready = true; if let c = lastCall { web?.evaluateJavaScript(c) } }
    /// Push a frame of the day carousel; skips the JS round-trip when nothing visible changed.
    func tick(from: String, to: String, dir: Int, p: Double, reveal: Double, slide: Double) {
        let key = "\(from)|\(to)|\(dir)|\(Int((p * 1000).rounded()))|\(Int((reveal * 1000).rounded()))|\(Int((slide * 1000).rounded()))"
        if key == lastKey { return }
        lastKey = key
        let call = "CK.tick(\(js(from)),\(js(to)),\(dir),\(String(format: "%.4f", p)),\(String(format: "%.4f", reveal)),\(String(format: "%.4f", slide)))"
        lastCall = call
        if ready { web?.evaluateJavaScript(call) }
    }
    private func js(_ s: String) -> String { (try? String(data: JSONEncoder().encode(s), encoding: .utf8) ?? "\"\"") ?? "\"\"" }
}

/// Per-frame carousel state for the NATIVE SwiftUI tabs, so they slide + fade in lockstep with the
/// Canvas title and the WebView content when paging days. Written by the driver (inside TimelineView),
/// read by DashTabs. Guarded sets → no re-render while idle (p=0, reveal=1, slide=0 constant).
@MainActor @Observable final class DashCarouselAnim {
    var dir = 0
    var p = 0.0
    var reveal = 1.0
    var slide = 0.0
    func set(dir: Int, p: Double, reveal: Double, slide: Double) {
        if self.dir != dir { self.dir = dir }
        if self.p != p { self.p = p }
        if self.reveal != reveal { self.reveal = reveal }
        if self.slide != slide { self.slide = slide }
    }
}

/// Invisible per-frame driver — lives INSIDE the TimelineView so `updateNSView` runs every frame with
/// fresh carousel values, forwarding them to the shared conduit (WebView) + anim state (SwiftUI tabs).
struct CarouselDriver: NSViewRepresentable {
    let carousel: DashboardCarousel
    let anim: DashCarouselAnim
    let from: String, to: String
    let dir: Int, p: Double, reveal: Double, slide: Double
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        carousel.tick(from: from, to: to, dir: dir, p: p, reveal: reveal, slide: slide)
        anim.set(dir: dir, p: p, reveal: reveal, slide: slide)
    }
}

struct DailyDashboardWebView: NSViewRepresentable {
    let carousel: DashboardCarousel
    let forwarder: GestureForwarder
    var data: String                       // engine.dashboardDataJSON() — includes the daily-notes map
    var tab: DashTab                        // TODO/NOTE (Swift is the source of truth)
    var noteMode: NotesMode                 // note edit/preview (the native toggle mirrors the WebView)
    var theme: Theme
    var onToggle: (_ eventId: String, _ occKey: String?, _ value: String) -> Void
    var onOpen: (_ eventId: String) -> Void
    var onDeselect: () -> Void
    var onTab: (DashTab) -> Void
    var onNoteMode: (NotesMode) -> Void
    var onNoteChange: (_ date: String, _ value: String) -> Void
    var onOpenLink: (URL) -> Void
    var onJumpDay: (_ date: String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(carousel: carousel, onToggle: onToggle, onOpen: onOpen, onDeselect: onDeselect,
                    onTab: onTab, onNoteMode: onNoteMode, onNoteChange: onNoteChange, onOpenLink: onOpenLink,
                    onJumpDay: onJumpDay)
    }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(context.coordinator, name: "ck")
        let web = PassThroughWebView(frame: .zero, configuration: cfg)   // forwards horizontal scroll + pinch
        web.forwarder = forwarder
        web.setValue(false, forKey: "drawsBackground")   // transparent → window glass shows through
        web.navigationDelegate = context.coordinator     // http(s) links → system browser
        context.coordinator.web = web
        carousel.register(web)
        if let root = dashRoot {
            web.loadFileURL(root.appendingPathComponent("dashboard.html"), allowingReadAccessTo: root)
        }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let c = context.coordinator
        c.onToggle = onToggle; c.onOpen = onOpen; c.onDeselect = onDeselect
        c.onTab = onTab; c.onNoteMode = onNoteMode; c.onNoteChange = onNoteChange; c.onOpenLink = onOpenLink
        c.onJumpDay = onJumpDay
        c.apply(data: data, tab: tab, noteMode: noteMode, theme: themeVars())
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "ck")
    }

    private var dashRoot: URL? { Bundle.module.resourceURL?.appendingPathComponent("editor", isDirectory: true) }

    private func themeVars() -> [String: String] {
        [
            "--accent-dark": cssColor(theme.text),
            "--accent-grey": cssColor(theme.accentGrey),
            "--highlight": "#ff3b6b",
            "--check-mark": cssColor(theme.bg),        // ✓ punched from the filled box → window bg tone
            "color-scheme": theme.dark ? "dark" : "light",
        ]
    }
    private func cssColor(_ c: Color) -> String {
        guard let n = NSColor(c).usingColorSpace(.sRGB) else { return "#e8e8ea" }
        return String(format: "rgba(%d,%d,%d,%.3f)", Int(n.redComponent * 255), Int(n.greenComponent * 255),
                      Int(n.blueComponent * 255), n.alphaComponent)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let carousel: DashboardCarousel
        var onToggle: (_ eventId: String, _ occKey: String?, _ value: String) -> Void
        var onOpen: (_ eventId: String) -> Void
        var onDeselect: () -> Void
        var onTab: (DashTab) -> Void
        var onNoteMode: (NotesMode) -> Void
        var onNoteChange: (_ date: String, _ value: String) -> Void
        var onOpenLink: (URL) -> Void
        var onJumpDay: (String) -> Void
        weak var web: WKWebView?
        private var ready = false
        private var lastData = "", lastTab = "", lastMode = ""   // sentinels force first push
        private var want: (data: String, tab: DashTab, noteMode: NotesMode, theme: [String: String])?
        init(carousel: DashboardCarousel,
             onToggle: @escaping (String, String?, String) -> Void, onOpen: @escaping (String) -> Void,
             onDeselect: @escaping () -> Void, onTab: @escaping (DashTab) -> Void,
             onNoteMode: @escaping (NotesMode) -> Void, onNoteChange: @escaping (String, String) -> Void,
             onOpenLink: @escaping (URL) -> Void, onJumpDay: @escaping (String) -> Void) {
            self.carousel = carousel; self.onToggle = onToggle; self.onOpen = onOpen; self.onDeselect = onDeselect
            self.onTab = onTab; self.onNoteMode = onNoteMode; self.onNoteChange = onNoteChange; self.onOpenLink = onOpenLink
            self.onJumpDay = onJumpDay
        }

        func apply(data: String, tab: DashTab, noteMode: NotesMode, theme: [String: String]) {
            want = (data, tab, noteMode, theme)
            guard ready else { return }
            push(theme)
            if data != lastData { lastData = data; eval("CK.setData(\(jsString(data)))") }
            pushState(tab: tab, noteMode: noteMode)
        }

        // Push tab + mode (echo-guarded). Note CONTENT rides the data map. The WebView also changes
        // mode itself (content-based default / ⌘S / ⌘-click) and posts it back so the native toggle
        // mirrors; `lastMode` is adopted in the message handler so that post doesn't echo.
        private func pushState(tab: DashTab, noteMode: NotesMode) {
            let t = tab == .note ? "note" : "todo"
            if t != lastTab { lastTab = t; eval("CK.setTab('\(t)')") }
            let m = noteMode == .preview ? "preview" : "edit"
            if m != lastMode { lastMode = m; eval("CK.setNoteMode('\(m)')") }
        }

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                if let w = want {
                    push(w.theme); lastData = w.data; eval("CK.setData(\(jsString(w.data)))")
                    pushState(tab: w.tab, noteMode: w.noteMode)
                }
                carousel.markReady()   // replay the latest tick so reveal/carousel state lands post-load
            case "toggle":
                if let id = body["eventId"] as? String, let value = body["value"] as? String {
                    onToggle(id, body["occKey"] as? String, value)
                }
            case "open":
                if let id = body["eventId"] as? String { onOpen(id) }
            case "deselect":
                onDeselect()   // clicked empty dashboard space → clear the calendar selection
            case "tab":
                let t: DashTab = (body["tab"] as? String) == "note" ? .note : .todo
                lastTab = t == .note ? "note" : "todo"   // adopt the JS-driven value (avoid an echo)
                onTab(t)
            case "noteMode":
                let m: NotesMode = (body["mode"] as? String) == "preview" ? .preview : .edit
                lastMode = m == .preview ? "preview" : "edit"   // adopt (WebView-driven) → no echo push
                onNoteMode(m)
            case "noteChange":
                if let date = body["date"] as? String, let v = body["value"] as? String { onNoteChange(date, v) }
            case "jumpDay":
                if let date = body["date"] as? String { onJumpDay(date) }
            case "openLink":
                if let s = body["url"] as? String, let u = URL(string: s) { onOpenLink(u) }
            default: break
            }
        }

        // http(s) link clicks (from the note preview) → system browser, not in-webview navigation.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, let s = url.scheme?.lowercased(), s == "http" || s == "https" {
                NSWorkspace.shared.open(url); decisionHandler(.cancel)
            } else { decisionHandler(.allow) }
        }

        private func push(_ theme: [String: String]) {
            guard !theme.isEmpty, let data = try? JSONSerialization.data(withJSONObject: theme),
                  let json = String(data: data, encoding: .utf8) else { return }
            eval("CK.setTheme(\(json))")
        }
        private func eval(_ js: String) { web?.evaluateJavaScript(js) }
        private func jsString(_ s: String) -> String {
            (try? String(data: JSONEncoder().encode(s), encoding: .utf8) ?? "\"\"") ?? "\"\""
        }
    }
}

/// The dashboard's two tabs: the TODO list (default) and a per-day markdown NOTE.
public enum DashTab: Hashable { case todo, note }

/// Places the dashboard in the day-view content region — one WebView spanning the full panel
/// (dashLeft → window edge) that hosts BOTH tabs (TODO carousel + per-day NOTE editor) and the
/// title-zone TODO/NOTE toggle, so everything slides/fades with the panel and the tabs never overlap.
/// Reads `frac` (a CalendarView @State mirror of `daily.frac`, live from the split handle) to re-lay-out.
struct DailyDashboardOverlay: View {
    let engine: CalendarEngine
    let carousel: DashboardCarousel
    let forwarder: GestureForwarder
    @Binding var tab: DashTab
    @Binding var noteMode: NotesMode
    let frac: CGFloat
    let vp: Viewport
    let containerWidth: CGFloat
    let height: CGFloat
    let theme: Theme
    var onOpen: (String) -> Void

    var body: some View {
        let contentW = max(1, vp.w - Layout.labelW)
        let dashLeftGeo = Layout.labelW + frac * contentW      // mirrors SceneRenderer.dashboardLeft
        let left = Layout.padLeft + dashLeftGeo                 // full panel: no gutter inset (CSS pads it)
        let right = containerWidth - Layout.padRight
        let top = Layout.topPad + Layout.monthH + 14           // below the title + date rows
        let w = max(1, right - left)
        let h = max(1, height - top - Layout.bottomPad)

        DailyDashboardWebView(
            carousel: carousel, forwarder: forwarder, data: engine.dashboardDataJSON(),
            tab: tab, noteMode: noteMode, theme: theme,
            onToggle: { id, occKey, value in engine.applyTodoNote(eventId: id, occKey: occKey, value: value) },
            onOpen: onOpen, onDeselect: { engine.deselect() },
            onTab: { tab = $0 }, onNoteMode: { noteMode = $0 },
            onNoteChange: { date, value in engine.setDailyNote(date, value) },
            onOpenLink: { NSWorkspace.shared.open($0) },
            onJumpDay: { date in
                // "YYYY-MM-DD" → fly to that day (like Today), then open its NOTE tab on landing.
                let c = date.split(separator: "-").compactMap { Int($0) }
                guard c.count == 3 else { return }
                engine.jumpToDay(c[0], c[1] - 1, c[2], onLand: { tab = .note })
            }
        )
        .frame(width: w, height: h)
        // The WebView sits above the AppKit catcher and eats mouse-moves, so the catcher never gets to
        // run its `p.x >= dashLeft` hover guard → a timeline cursor line + time tag would stay frozen
        // (peeking out of the left edge). Clear the calendar hover the instant it's entered.
        .onHover { hovering in if hovering { engine.onHoverExit() } }
        .position(x: left + w / 2, y: top + h / 2)
    }
}

/// The TODO/NOTE tabs — a SEPARATE overlay (above the WebView, so the hosted WKWebView NSView can't
/// hit-test over them). Text-only, right-aligned in the title zone (mirrors the web's `.cc-dd-tabs`).
/// They carousel with the page via `anim` (same state the Canvas title + WebView use): the current
/// copy slides out by −dir·p fading to 1−p, an incoming copy slides in from dir·(1−p) fading to p, the
/// whole thing offset by the zoom `slide` and faded by `reveal` — so it moves as one with the page.
struct DashTabsOverlay: View {
    let engine: CalendarEngine
    let anim: DashCarouselAnim
    @Binding var tab: DashTab
    let frac: CGFloat
    let vp: Viewport
    let containerWidth: CGFloat
    let theme: Theme

    var body: some View {
        if engine.chrome.level >= 2 {
            let contentW = max(1, vp.w - Layout.labelW)
            let left = Layout.padLeft + Layout.labelW + frac * contentW
            let right = containerWidth - Layout.padRight
            let w = max(1, right - left)
            let titleY = Layout.topPad + Layout.monthH - 14
            DashTabs(tab: $tab, theme: theme, anim: anim, w: w)
                .position(x: left + w / 2, y: titleY)
        }
    }
}

/// The note edit/preview toggle — a native segmented control (pencil/eye), same as the drawer's foot,
/// pinned bottom-right of the dashboard panel. Shown at rest on the NOTE tab (day level). Drives the
/// `noteMode` binding (→ CK.setNoteMode); the WebView also updates it (content-based / ⌘S / ⌘-click).
struct NoteModeToggleOverlay: View {
    let engine: CalendarEngine
    let anim: DashCarouselAnim
    let tab: DashTab
    @Binding var noteMode: NotesMode
    let containerWidth: CGFloat
    let height: CGFloat
    let theme: Theme

    var body: some View {
        if engine.chrome.level == 3, tab == .note {
            let right = containerWidth - Layout.padRight
            let bottom = height - Layout.bottomPad
            Picker("", selection: $noteMode) {
                Image(systemName: "pencil").tag(NotesMode.edit)
                Image(systemName: "eye").tag(NotesMode.preview)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .tint(Color(hex: 0xff3b6b))
            .opacity(anim.reveal > 0.5 && anim.p < 0.01 ? 1 : 0)   // hide during swipe / while zooming
            .position(x: right - 46, y: bottom - 2)
            .animation(.easeOut(duration: 0.12), value: anim.p < 0.01)
        }
    }
}

private struct DashTabs: View {
    @Binding var tab: DashTab
    let theme: Theme
    let anim: DashCarouselAnim
    let w: CGFloat
    var body: some View {
        let base = anim.slide * w
        ZStack {
            row.offset(x: base - CGFloat(anim.dir) * anim.p * w).opacity(anim.reveal * (1 - anim.p))
            if anim.p > 0.001 {
                row.offset(x: base + CGFloat(anim.dir) * (1 - anim.p) * w).opacity(anim.reveal * anim.p)
            }
        }
        .frame(width: w, height: 24)
        .clipped()                                             // clip a sliding copy at the panel edge
        .allowsHitTesting(anim.reveal > 0.5 && anim.p < 0.01)  // interactive only at rest, revealed
    }
    @ViewBuilder private var row: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            TabLabel(title: "TODO", selected: tab == .todo, theme: theme) { tab = .todo }
            TabLabel(title: "NOTE", selected: tab == .note, theme: theme) { tab = .note }
        }
        .padding(.trailing, 18)
        .frame(width: w, alignment: .trailing)
    }
}

private struct TabLabel: View {
    let title: String
    let selected: Bool
    let theme: Theme
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: selected ? .bold : .regular))
                .tracking(0.9)                                   // ~0.08em on 11px
                .foregroundStyle(theme.text)
                .opacity(selected ? 1 : (hovering ? 0.75 : 0.4))
                .padding(.horizontal, 5).padding(.vertical, 2).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
