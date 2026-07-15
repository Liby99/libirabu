// The notes markdown editor: a transparent WKWebView hosting the bundled CodeMirror + remark/KaTeX
// editor (see webeditor/). Reusable — bind `text`, flip `mode` (.edit / .preview); the drawer owns
// the toggle. Background is transparent so the drawer's glass shows through.

import SwiftUI
import WebKit
import AppKit

enum NotesMode: Hashable { case edit, preview }

struct MarkdownWebEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var mode: NotesMode
    var theme: Theme
    // When set (daily-note tab), horizontal scroll + pinch forward to the calendar instead of being
    // eaten by the editor; vertical scroll stays here. Unset in the drawer (no calendar underneath).
    var forwarder: GestureForwarder? = nil

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, mode: $mode) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(context.coordinator, name: "ck")
        let web: WKWebView
        if let forwarder {
            let pt = PassThroughWebView(frame: .zero, configuration: cfg); pt.forwarder = forwarder; web = pt
        } else {
            web = WKWebView(frame: .zero, configuration: cfg)
        }
        web.setValue(false, forKey: "drawsBackground")   // transparent → glass shows through
        web.navigationDelegate = context.coordinator     // open link clicks in the system browser
        context.coordinator.web = web
        if let root = editorRoot {
            web.loadFileURL(root.appendingPathComponent("editor.html"), allowingReadAccessTo: root)
        }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.apply(text: text, mode: mode, theme: themeVars())
    }

    private var editorRoot: URL? { Bundle.module.resourceURL?.appendingPathComponent("editor", isDirectory: true) }

    private func themeVars() -> [String: String] {
        [
            "--accent-dark": cssColor(theme.text),
            "--accent-grey": cssColor(theme.accentGrey),
            "--highlight": "#ff3b6b",
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
        private let text: Binding<String>
        private let mode: Binding<NotesMode>
        weak var web: WKWebView?
        private var ready = false
        private var lastSent = ""                     // last value pushed to / received from JS (echo guard)
        private var want: (text: String, mode: NotesMode, theme: [String: String])?
        private var pendingCursorLine: Int?           // ⌘-clicked preview line → place caret after mode flip
        init(text: Binding<String>, mode: Binding<NotesMode>) { self.text = text; self.mode = mode }

        func apply(text: String, mode: NotesMode, theme: [String: String]) {
            want = (text, mode, theme)
            guard ready else { return }
            push(theme)
            if text != lastSent { lastSent = text; eval("CK.setValue(\(jsString(text)))") }
            eval("CK.setMode('\(mode == .edit ? "edit" : "preview")')")
            if mode == .edit, let ln = pendingCursorLine { pendingCursorLine = nil; eval("CK.setCursorLine(\(ln))") }
        }

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                if let w = want { push(w.theme); lastSent = w.text; eval("CK.setValue(\(jsString(w.text)))"); eval("CK.setMode('\(w.mode == .edit ? "edit" : "preview")')") }
            case "change":
                if let v = body["value"] as? String { lastSent = v; text.wrappedValue = v }
            case "openLink":
                if let s = body["url"] as? String, let u = URL(string: s) { NSWorkspace.shared.open(u) }
            case "editAt":
                // ⌘-click in preview → remember the line, flip to edit; apply() places the caret.
                if let line = body["line"] as? Int { pendingCursorLine = line; mode.wrappedValue = .edit }
            case "preview":
                mode.wrappedValue = .preview   // ⌘S in the editor
            default: break
            }
        }

        // A clicked http(s) link opens in the default browser instead of navigating the editor away.
        // file:// (the editor bundle itself) and other schemes load normally.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, let s = url.scheme?.lowercased(), s == "http" || s == "https" {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
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
