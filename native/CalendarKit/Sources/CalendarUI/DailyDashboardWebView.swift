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

import AppKit
import CalendarEngine
import CalendarGeometry
import SwiftUI
import WebKit

/// Shared handle to the calendar's input catcher, so the dashboard web view can forward the gestures
/// it shouldn't own (horizontal day-paging scroll + pinch-zoom) back to the calendar. Set by the
/// InputCatcher when its NSView is created.
@MainActor final class GestureForwarder { weak var catcher: NSView? }

/// The dashboard's WKWebView, which forwards horizontal scroll + pinch to the calendar instead of
/// eating them. VERTICAL scroll stays here (the TODO list, with native rubber-band); horizontal
/// scroll pages days and pinch zooms — both handled by the InputCatcher underneath.
final class PassThroughWebView: WKWebView, FocusGatedControl {
    weak var forwarder: GestureForwarder?

    /// The reveal FADE, applied natively (view alphaValue — plain AppKit compositing of the hosted
    /// layer, safe). Panel MOTION stays in CSS: transforming the WKWebView's own layer
    /// (sublayerTransform) fought WebKit's remote-layer commits — each web-process commit
    /// re-asserted its geometry, alternating shifted/reset frames, i.e. flicker.
    func setPanelAlpha(_ alpha: CGFloat) {
        if alphaValue != alpha {
            alphaValue = alpha
        }
    }

    /// Frame-local x of the live mask edge (set per tick): the frame spans the FULL content
    /// region, so pointer events left of the panel must fall through to the calendar beneath.
    var interactiveLeftX: CGFloat = .greatestFiniteMagnitude
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if local.x < interactiveLeftX {
            return nil
        }
        return super.hitTest(point)
    }
    private enum Axis { case undecided, horizontal, vertical }
    private var axis: Axis = .undecided
    /// The pointer is over a horizontally-scrollable element (a code block with a long line). Set from
    /// JS (pointermove → "hlocal"); read when a scroll gesture's axis locks, to keep it in the web view.
    var overHScroll = false
    private var gestureOverHScroll = false // latched at gesture start so the whole gesture routes one way

    // Focus gate (same idea as the notes editor's FocusGatedWebView): the web view does NOT grab first
    // responder on load, and refuses it until the user actually clicks. Otherwise the dashboard's list
    // items join the window's key-view loop, so Tab — e.g. while navigating the drawer — would cycle
    // INTO them. Scrolling doesn't need focus; a real click (checkbox / note) enables it. Readable so the
    // key monitor treats a clicked-into daily NOTE editor as text input (keys stay in the web view).
    private(set) var focusAllowed = false
    override func becomeFirstResponder() -> Bool {
        focusAllowed ? super.becomeFirstResponder() : false
    }

    override func mouseDown(with event: NSEvent) {
        focusAllowed = true; super.mouseDown(with: event)
    }

    /// Programmatically permit focus — used when the keyboard Tab-stops into the daily NOTE editor (the
    /// calendar's key system decides to hand keys to the WebView), mirroring a real click.
    func allowFocus() {
        focusAllowed = true
    }

    /// Re-gate and drop focus off the web content — called when the dashboard goes inactive (drawer
    /// open), so keyboard navigation in the drawer can never land inside the dashboard.
    func regateFocus() {
        focusAllowed = false
        guard let w = window else { return }
        let fr = w.firstResponder as? NSView
        if fr === self || fr?.isDescendant(of: self) == true {
            w.makeFirstResponder(forwarder?.catcher)
        }
    }

    override func scrollWheel(with e: NSEvent) {
        // Lock the axis ONCE per gesture (at the first real delta) and route the WHOLE gesture — its
        // zero-delta .ended AND its momentum tail included — to a single target. Routing per-event
        // instead would send the delta-less .ended to the wrong place, so the day-pager scroll view
        // never gets a clean gesture end and snaps instead of decelerating (momentum dies on lift).
        if e.phase.contains(.began) || e.phase.contains(.mayBegin) {
            axis = .undecided
        }
        if axis == .undecided {
            let dx = abs(e.scrollingDeltaX), dy = abs(e.scrollingDeltaY)
            if dx > 0 || dy > 0 {
                axis = dx > dy ? .horizontal : .vertical; gestureOverHScroll = overHScroll
            }
        }
        // Horizontal → the calendar (day paging, with native momentum); vertical/undecided → the web list
        // (native rubber-band). EXCEPTION: horizontal over a scrollable code block stays local, so the
        // block scrolls sideways instead of swiping the day. Latched per-gesture so `.ended` isn't split.
        if axis == .horizontal, !gestureOverHScroll, let c = forwarder?.catcher {
            c.scrollWheel(with: e)
        } else {
            super.scrollWheel(with: e)
        }
    }

    /// Pinch is always the calendar's (zoom), never the web view's page magnification.
    override func magnify(with e: NSEvent) {
        (forwarder?.catcher ?? superview)?.magnify(with: e)
    }

    // The web view's frame spans the full window (its content slides in via CSS), so its cursor tracking
    // fires even where the CALENDAR shows through on the left — fighting the calendar's grab/i-beam cursor
    // (e.g. over a deadline tag in week view → flicker). Only drive the cursor when we're the active day
    // view; otherwise yield so the calendar's cursor (set by the input catcher) stands.
    var cursorActive = false
    override func cursorUpdate(with event: NSEvent) {
        if cursorActive {
            super.cursorUpdate(with: event)
        }
    }

    /// TODO-tab layering menu (the cog's menu): set by the host while the TODO panel is active.
    /// Right-clicking inside the panel pops it instead of WebKit's default context menu; clicks
    /// left of the panel never reach here (hitTest gates on interactiveLeftX). nil → default menu
    /// (kept on the NOTE tab, where copy/paste in the editor is genuinely useful).
    var todoContextMenu: (() -> NSMenu?)?
    override func rightMouseDown(with event: NSEvent) {
        if let m = todoContextMenu?() {
            NSMenu.popUpContextMenu(m, with: event, for: self)
            return
        }
        super.rightMouseDown(with: event)
    }
}

/// Shared conduit: the web view registers itself here; the per-frame driver pushes carousel ticks.
@MainActor final class DashboardCarousel {
    weak var web: WKWebView?
    private var lastKey = ""
    private var lastCall: String? // the most recent CK.tick(...), replayed once the page is ready
    private var ready = false
    func register(_ w: WKWebView?) {
        web = w; lastKey = ""; lastCall = nil; ready = false
    }

    /// Hand keyboard focus back to the calendar catcher (and re-gate the web view) — e.g. ⌘B
    /// while the note editor holds first responder: the TODO arrows belong to the calendar's key
    /// system, which never sees keys while the WKWebView is first responder.
    func regateWebFocus() {
        (web as? PassThroughWebView)?.regateFocus()
    }

    /// The page signalled ready — replay the latest tick so its reveal/carousel state lands even if
    /// the driver's earlier tick fired before CK was defined (which would otherwise be lost).
    func markReady() {
        ready = true; if let c = lastCall {
            web?.evaluateJavaScript(c)
        }
    }

    /// Push a frame of the day carousel + the zoom-scope carousel (month/week/day panels sliding
    /// along z); skips the JS round-trip when nothing visible changed.
    ///
    /// The payload is ONE JSON object (CK.tick({...})) — the JS merges it over its defaults, so
    /// adding a field can never desynchronize a positional-argument arity again (that bug blanked
    /// the whole webview once: dy arrived as undefined and apply() threw before painting).
    func tick(from: String, to: String, dir: Int, p: Double, reveal: Double, slide: Double,
              scopeA: String = "day", scopeB: String = "day", scopeT: Double = 1,
              dy: Double = 0, mFrom: String = "", mTo: String = "",
              mDy0: Double = 0, mDy1: Double = 0, mP: Double = 0,
              mKeyA: String = "", mKeyB: String = "",
              wFrom: String = "", wTo: String = "", wP: Double = 0,
              wKeyA: String = "", wKeyB: String = "",
              maskX: Double = 0, maskW: Double = 0,
              aName: String = "", aX: Double = 0, aW: Double = 0, aOp: Double = 0,
              bName: String = "", bX: Double = 0, bW: Double = 0, bOp: Double = 0,
              shiftX: Double = 0) {
        let key = "\(from)|\(to)|\(dir)|\(Int((p * 1000).rounded()))|\(Int((reveal * 1000).rounded()))|\(Int((slide * 1000).rounded()))|\(scopeA)|\(scopeB)|\(Int((scopeT * 1000).rounded()))|\(Int(dy.rounded()))|\(mFrom)|\(mTo)|\(Int(mDy0.rounded()))|\(Int(mDy1.rounded()))|\(Int((mP * 1000).rounded()))|\(mKeyA)|\(mKeyB)|\(wFrom)|\(wTo)|\(Int((wP * 1000).rounded()))|\(wKeyA)|\(wKeyB)|\(Int(maskX.rounded()))|\(Int(maskW.rounded()))|\(aName)|\(Int(aX.rounded()))|\(Int(aW.rounded()))|\(Int((aOp * 1000).rounded()))|\(bName)|\(Int(bX.rounded()))|\(Int(bW.rounded()))|\(Int((bOp * 1000).rounded()))|\(Int(shiftX.rounded()))"
        if key == lastKey {
            return
        }
        lastKey = key
        // Reveal fade natively (safe: view-level alpha); motion stays in CSS — see setPanelAlpha.
        // The hit gate tracks the live mask edge so only the panel area belongs to the webview
        // (shifted left with the content while the drawer canvas-shift is riding).
        if let ptw = web as? PassThroughWebView {
            ptw.setPanelAlpha(CGFloat(reveal))
            ptw.interactiveLeftX = CGFloat(maskX - shiftX)
        }
        func r4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
        let payload: [String: Any] = [
            "from": from, "to": to, "dir": dir,
            "p": r4(p), "reveal": r4(reveal), "slide": r4(slide),
            "scopeA": scopeA, "scopeB": scopeB, "scopeT": r4(scopeT),
            "dy": (dy * 10).rounded() / 10,
            "mFrom": mFrom, "mTo": mTo,
            "mDy0": (mDy0 * 10).rounded() / 10, "mDy1": (mDy1 * 10).rounded() / 10,
            "mP": r4(mP), "mKeyA": mKeyA, "mKeyB": mKeyB,
            "wFrom": wFrom, "wTo": wTo, "wP": r4(wP), "wKeyA": wKeyA, "wKeyB": wKeyB,
            "maskX": (maskX * 10).rounded() / 10, "maskW": (maskW * 10).rounded() / 10,
            "aName": aName, "aX": (aX * 10).rounded() / 10, "aW": (aW * 10).rounded() / 10,
            "aOp": r4(aOp),
            "bName": bName, "bX": (bX * 10).rounded() / 10, "bW": (bW * 10).rounded() / 10,
            "bOp": r4(bOp),
            "shift": (shiftX * 10).rounded() / 10,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let call = "CK.tick(\(json))"
        lastCall = call
        if ready {
            web?.evaluateJavaScript(call)
        }
    }

    private func js(_ s: String) -> String {
        (try? String(data: JSONEncoder().encode(s), encoding: .utf8) ?? "\"\"") ??
            "\"\""
    }

    /// ── Keyboard-nav bridge (Tab into the dashboard TODO / NOTE stops) ──
    private func eval(_ s: String) {
        if ready {
            web?.evaluateJavaScript(s)
        }
    }

    /// Set/clear the dashboard's keyboard focus ring (TODO row cursor or NOTE outline).
    func navFocus(_ stop: CalendarEngine.DashStop?) {
        eval("CK.navSet(\(js(stop == .todo ? "todo" : (stop == .note ? "note" : "none"))))")
    }

    func navMove(_ delta: Int) {
        eval("CK.navMove(\(delta))")
    } // ↑/↓ TODO rows
    func navActivate() {
        eval("CK.navActivate()")
    } // Space → toggle the focused TODO
    func navOpen() {
        eval("CK.navOpen()")
    } // Enter → open the focused TODO
    func navFold(_ open: Bool) {
        eval("CK.navFold(\(open))")
    } // ←/→ → fold/unfold the focused TODO's subtree
    /// Enter on the NOTE stop → let the WebView own the keys (allow focus + first responder) and focus
    /// the CodeMirror editor.
    /// `ring: true` (⌘E while keyboard mode was already on) keeps the dashed nav ring visible
    /// around the editor while the caret blinks inside it.
    func focusNoteEditor(ring: Bool = false) {
        guard let w = web as? PassThroughWebView else { return }
        // Defer to the NEXT runloop tick: this is called from within the Enter keyDown dispatch, and
        // making the web view first responder synchronously mid-keyDown routes that same Enter into the
        // freshly-focused CodeMirror as a stray newline. Letting the keyDown finish first avoids that.
        DispatchQueue.main.async { [weak self] in
            w.allowFocus(); w.window?.makeFirstResponder(w)
            self?.eval("CK.noteEdit(\(ring))")
        }
    }
}

/// Per-frame carousel state for the NATIVE SwiftUI tabs, so they slide + fade in lockstep with the
/// Canvas title and the WebView content when paging days. Written by the driver (inside TimelineView),
/// read by DashTabs. Guarded sets → no re-render while idle (p=0, reveal=1, slide=0 constant).
@MainActor @Observable final class DashCarouselAnim {
    var dir = 0
    var p = 0.0
    var reveal = 1.0
    var slide = 0.0
    var gutterShift = 0.0 // engine.gutterShift mirrored per frame (gutter hide slide)
    var headerTopY = Double(Layout.topPad) // the focused band's ANIMATED top (accordion / page-turn)
    var headerTopY2 = Double(Layout.topPad) // the INCOMING month band's top during a page-turn
    var panelLeft = 0.0 // dashboardLeftAnimated — the panel's live left edge (pinned width morphs)
    var monthP = 0.0 // month page-turn progress
    var monthDir = 0
    var scopeT = 1.0 // zoom-scope carousel fraction (0 = lower scope at rest … 1 = upper at rest)
    var weekP = 0.0 // week-turn progress (weekly dashboard; rests at BOTH 0 and 1)
    // Per-panel scope geometry (GEOMETRY-space px, same numbers the Canvas header draws with) —
    // the tab rows anchor to each panel's RIGHT edge and fade with its opacity.
    var aName = ""
    var aX = 0.0
    var aW = 0.0
    var aOp = 0.0
    var bName = ""
    var bX = 0.0
    var bW = 0.0
    var bOp = 0.0
    func set(dir: Int, p: Double, reveal: Double, slide: Double,
             headerTopY: Double, headerTopY2: Double, panelLeft: Double,
             monthP: Double, monthDir: Int, scopeT: Double, weekP: Double,
             aName: String, aX: Double, aW: Double, aOp: Double,
             bName: String, bX: Double, bW: Double, bOp: Double,
             gutterShift: Double = 0) {
        if self.gutterShift != gutterShift {
            self.gutterShift = gutterShift
        }
        if self.dir != dir {
            self.dir = dir
        }
        if self.p != p {
            self.p = p
        }
        if self.reveal != reveal {
            self.reveal = reveal
        }
        if self.slide != slide {
            self.slide = slide
        }
        if self.headerTopY != headerTopY {
            self.headerTopY = headerTopY
        }
        if self.panelLeft != panelLeft {
            self.panelLeft = panelLeft
        }
        if self.monthP != monthP {
            self.monthP = monthP
        }
        if self.headerTopY2 != headerTopY2 {
            self.headerTopY2 = headerTopY2
        }
        if self.monthDir != monthDir {
            self.monthDir = monthDir
        }
        if self.scopeT != scopeT {
            self.scopeT = scopeT
        }
        if self.weekP != weekP {
            self.weekP = weekP
        }
        if self.aName != aName {
            self.aName = aName
        }
        if self.aX != aX {
            self.aX = aX
        }
        if self.aW != aW {
            self.aW = aW
        }
        if self.aOp != aOp {
            self.aOp = aOp
        }
        if self.bName != bName {
            self.bName = bName
        }
        if self.bX != bX {
            self.bX = bX
        }
        if self.bW != bW {
            self.bW = bW
        }
        if self.bOp != bOp {
            self.bOp = bOp
        }
    }
}

/// Invisible per-frame driver — lives INSIDE the TimelineView so `updateNSView` runs every frame with
/// fresh carousel values, forwarding them to the shared conduit (WebView) + anim state (SwiftUI tabs).
struct CarouselDriver: NSViewRepresentable {
    let carousel: DashboardCarousel
    let anim: DashCarouselAnim
    let from: String, to: String
    let dir: Int, p: Double, reveal: Double, slide: Double
    var scopeA: String = "day", scopeB: String = "day" // zoom-scope carousel (month/week/day)
    var scopeT: Double = 1 // eased fraction between scopeA (lower) and scopeB (upper)
    var headerTopY: Double = Double(Layout.topPad) // focused band's animated top (canvas-anchored)
    var headerTopY2: Double = Double(Layout.topPad) // incoming month band's top (page-turns)
    var panelLeft: Double = 0 // dashboardLeftAnimated (for the native tab overlay)
    var webDy: Double = 0 // vertical shift of the webview CONTENT (accordion; excludes page-turns)
    var mFrom: String = "", mTo: String = "" // month page-turn labels (webview vertical carousel)
    var mDir: Int = 0
    var mP: Double = 0
    var mDy0: Double = 0, mDy1: Double = 0 // month-turn PIXEL offsets (band-frame deltas; see caller)
    var mKeyA: String = "", mKeyB: String = "" // month machine keys "YYYY-MM" (notes + filters)
    var wFrom: String = "", wTo: String = "" // week-turn labels (weekly-dashboard carousel)
    var wP: Double = 0 // week-turn progress (0 = base week at rest … 1 = next week at rest)
    var wKeyA: String = "", wKeyB: String = "" // week machine keys: the Sunday, "YYYY-MM-DD"
    // Per-panel scope geometry from dashScopePanels, frame-local px (frame left = labelW):
    var maskX: Double = 0, maskW: Double = 0 // the clip region (dashboardLeftAnimated → right edge)
    var aName: String = "", aX: Double = 0, aW: Double = 0, aOp: Double = 0 // current/outgoing panel
    var bName: String = "", bX: Double = 0, bW: Double = 0, bOp: Double = 0 // incoming (transitions)
    var shiftX: Double = 0 // drawer canvas-shift (engine.drawerShift): content rides the canvas slide
    var gutterShiftX: Double = 0 // gutter hide (engine.gutterShift): body-level frame/offset rides it
    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ v: NSView, context: Context) {
        carousel.tick(from: from, to: to, dir: dir, p: p, reveal: reveal, slide: slide,
                      scopeA: scopeA, scopeB: scopeB, scopeT: scopeT,
                      dy: webDy, mFrom: mFrom, mTo: mTo, mDy0: mDy0, mDy1: mDy1, mP: mP,
                      mKeyA: mKeyA, mKeyB: mKeyB,
                      wFrom: wFrom, wTo: wTo, wP: wP, wKeyA: wKeyA, wKeyB: wKeyB,
                      maskX: maskX, maskW: maskW,
                      aName: aName, aX: aX, aW: aW, aOp: aOp,
                      bName: bName, bX: bX, bW: bW, bOp: bOp,
                      shiftX: shiftX)
        anim.set(dir: dir, p: p, reveal: reveal, slide: slide,
                 headerTopY: headerTopY, headerTopY2: headerTopY2, panelLeft: panelLeft,
                 monthP: mP, monthDir: mDir, scopeT: scopeT, weekP: wP,
                 aName: aName, aX: aX, aW: aW, aOp: aOp,
                 bName: bName, bX: bX, bW: bW, bOp: bOp,
                 gutterShift: gutterShiftX)
    }
}

struct DailyDashboardWebView: NSViewRepresentable {
    let carousel: DashboardCarousel
    let forwarder: GestureForwarder
    var data: String // engine.dashboardDataJSON() — includes the daily-notes map
    var tab: DashTab // TODO/NOTE (Swift is the source of truth)
    var noteMode: NotesMode // note edit/preview (the native toggle mirrors the WebView)
    var inactive: Bool // drawer open → in-page scrim blurs + blocks the dashboard
    var interactive: Bool // the active day view → the web view may drive the cursor
    var todoPrefs: String = "{}" // per-scope layering prefs JSON (DashTodoSettings.jsJSON)
    var todoMenu: DashTodoMenuController? = nil // shared cog/context menu (nil → no menu)
    var theme: Theme
    var onToggle: (_ eventId: String, _ occKey: String?, _ value: String) -> Void
    var onOpen: (_ eventId: String) -> Void
    var onDeselect: () -> Void
    var onTab: (DashTab) -> Void
    var onNoteMode: (NotesMode) -> Void
    var onNoteChange: (_ date: String, _ value: String) -> Void
    var onOpenLink: (URL) -> Void
    var onJumpDay: (_ date: String) -> Void
    var onCloseDrawer: () -> Void
    var onNoteExit: () -> Void // daily NOTE editor handed focus back (Esc / ⌘S)
    var onNavTab: (Bool) -> Void // Tab in the web view → app keyboard nav (true = forward)

    func makeCoordinator() -> Coordinator {
        Coordinator(carousel: carousel, onToggle: onToggle, onOpen: onOpen, onDeselect: onDeselect,
                    onTab: onTab, onNoteMode: onNoteMode, onNoteChange: onNoteChange, onOpenLink: onOpenLink,
                    onJumpDay: onJumpDay, onCloseDrawer: onCloseDrawer, onNoteExit: onNoteExit, onNavTab: onNavTab)
    }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(context.coordinator, name: "ck")
        let web = PassThroughWebView(frame: .zero, configuration: cfg) // forwards horizontal scroll + pinch
        web.forwarder = forwarder
        web.setValue(false, forKey: "drawsBackground") // transparent → window glass shows through
        web.navigationDelegate = context.coordinator // http(s) links → system browser
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
        c.onJumpDay = onJumpDay; c.onCloseDrawer = onCloseDrawer; c.onNoteExit = onNoteExit; c.onNavTab = onNavTab
        c.apply(data: data, tab: tab, noteMode: noteMode, inactive: inactive, theme: themeVars(),
                todoPrefs: todoPrefs)
        // Only own the cursor as the active day view; at week level (slid out) yield so the calendar's
        // grab/i-beam cursor over the timeline doesn't flicker against the web view's arrow.
        (web as? PassThroughWebView)?.cursorActive = interactive && !inactive
        // Right-click inside the TODO panel → the layering menu (the cog's), not WebKit's default.
        if let ptw = web as? PassThroughWebView {
            let menu = todoMenu
            ptw.todoContextMenu = (tab == .todo && !inactive && menu != nil) ? { menu?.menu() } : nil
        }
        // Drawer open → the dashboard is blocked; make sure it isn't holding keyboard focus so Tab
        // navigation in the drawer can't cycle into its list items.
        if inactive {
            (web as? PassThroughWebView)?.regateFocus()
        }
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "ck")
    }

    private var dashRoot: URL? {
        Bundle.module.resourceURL?.appendingPathComponent("editor", isDirectory: true)
    }

    private func themeVars() -> [String: String] {
        [
            "--accent-dark": cssColor(theme.text),
            "--accent-grey": cssColor(theme.accentGrey),
            "--highlight": String(format: "#%06x", AccentPref.hex), // follows Settings ▸ Accent Color
            "--check-mark": cssColor(theme.bg), // ✓ punched from the filled box → window bg tone
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
        var onCloseDrawer: () -> Void
        var onNoteExit: () -> Void
        var onNavTab: (Bool) -> Void
        weak var web: WKWebView?
        private var ready = false
        private var lastData = "", lastTab = "", lastMode = "" // sentinels force first push
        private var lastInactive: Bool?
        private var lastTodoPrefs = ""
        private var want: (data: String, tab: DashTab, noteMode: NotesMode, inactive: Bool,
                           theme: [String: String], todoPrefs: String)?
        init(carousel: DashboardCarousel,
             onToggle: @escaping (String, String?, String) -> Void, onOpen: @escaping (String) -> Void,
             onDeselect: @escaping () -> Void, onTab: @escaping (DashTab) -> Void,
             onNoteMode: @escaping (NotesMode) -> Void, onNoteChange: @escaping (String, String) -> Void,
             onOpenLink: @escaping (URL) -> Void, onJumpDay: @escaping (String) -> Void,
             onCloseDrawer: @escaping () -> Void, onNoteExit: @escaping () -> Void,
             onNavTab: @escaping (Bool) -> Void) {
            self.carousel = carousel; self.onToggle = onToggle; self.onOpen = onOpen; self.onDeselect = onDeselect
            self.onTab = onTab; self.onNoteMode = onNoteMode; self.onNoteChange = onNoteChange; self
                .onOpenLink = onOpenLink
            self.onJumpDay = onJumpDay; self.onCloseDrawer = onCloseDrawer; self.onNoteExit = onNoteExit; self
                .onNavTab = onNavTab
        }

        func apply(data: String, tab: DashTab, noteMode: NotesMode, inactive: Bool, theme: [String: String],
                   todoPrefs: String) {
            want = (data, tab, noteMode, inactive, theme, todoPrefs)
            guard ready else { return }
            push(theme)
            // Prefs BEFORE data: both re-render, but data's echo-suppression window (setData) should
            // see the final filter state so the panels never paint one frame with stale layering.
            if todoPrefs != lastTodoPrefs {
                lastTodoPrefs = todoPrefs; eval("CK.setTodoPrefs(\(jsString(todoPrefs)))")
            }
            if data != lastData {
                lastData = data; eval("CK.setData(\(jsString(data)))")
            }
            pushState(tab: tab, noteMode: noteMode, inactive: inactive)
        }

        /// Push tab + mode + inactive (echo-guarded). Note CONTENT rides the data map. The WebView also
        /// changes mode itself (content-based default / ⌘S / ⌘-click) and posts it back so the native
        /// toggle mirrors; `lastMode` is adopted in the message handler so that post doesn't echo.
        private func pushState(tab: DashTab, noteMode: NotesMode, inactive: Bool) {
            let t = tab.js
            if t != lastTab {
                lastTab = t; eval("CK.setTab('\(t)')")
            }
            let m = noteMode == .preview ? "preview" : "edit"
            if m != lastMode {
                lastMode = m; eval("CK.setNoteMode('\(m)')")
            }
            if inactive != lastInactive {
                lastInactive = inactive; eval("CK.setInactive(\(inactive))")
            }
        }

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                if let w = want {
                    push(w.theme)
                    lastTodoPrefs = w.todoPrefs; eval("CK.setTodoPrefs(\(jsString(w.todoPrefs)))")
                    lastData = w.data; eval("CK.setData(\(jsString(w.data)))")
                    pushState(tab: w.tab, noteMode: w.noteMode, inactive: w.inactive)
                }
                carousel.markReady() // replay the latest tick so reveal/carousel state lands post-load
            case "toggle":
                if let id = body["eventId"] as? String, let value = body["value"] as? String {
                    onToggle(id, body["occKey"] as? String, value)
                }
            case "open":
                if let id = body["eventId"] as? String {
                    onOpen(id)
                }
            case "deselect":
                onDeselect() // clicked empty dashboard space → clear the calendar selection
            // JS-driven tab/mode changes are NOT adopted into lastTab/lastMode: adopting could eat a
            // legitimate diff when the post crossed a simultaneous Swift push in flight (each side
            // ends on the other's stale value with the guard satisfied → toggle says edit, preview
            // shows, forever). Instead the binding round-trips and the next updateNSView re-pushes;
            // the JS setters are idempotent and never post back, so it converges without a loop.
            case "tab":
                onTab(DashTab.fromJS(body["tab"] as? String))
            case "noteMode":
                onNoteMode((body["mode"] as? String) == "preview" ? .preview : .edit)
            case "noteChange":
                if let date = body["date"] as? String, let v = body["value"] as? String {
                    onNoteChange(date, v)
                }
            case "jumpDay":
                if let date = body["date"] as? String {
                    onJumpDay(date)
                }
            case "hlocal":
                // Pointer moved over / off a horizontally-scrollable element (code block) — route the
                // next horizontal scroll gesture locally vs. to the calendar accordingly.
                (web as? PassThroughWebView)?.overHScroll = (body["on"] as? Bool) ?? false
            case "navTab":
                // Tab pressed while the web view holds focus (not in the note editor) → drop the web
                // view's focus and hand Tab to the app's keyboard navigation (no native focus rings).
                (web as? PassThroughWebView)?.regateFocus()
                onNavTab((body["shift"] as? Bool) != true) // shift → backward
            case "navNoteExit":
                // Esc / ⌘S in the keyboard-focused daily NOTE editor → drop the WebView's focus back to
                // the calendar catcher, then let the host restore the NOTE ring (engine.dashNoteExit).
                (web as? PassThroughWebView)?.regateFocus()
                onNoteExit()
            case "closeDrawer":
                onCloseDrawer() // clicked the in-page scrim while the drawer is open
            case "openLink":
                if let s = body["url"] as? String, let u = URL(string: s) {
                    onOpenLink(u)
                }
            default: break
            }
        }

        /// http(s) link clicks (from the note preview) → system browser, not in-webview navigation.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, let s = url.scheme?.lowercased(), s == "http" || s == "https" {
                NSWorkspace.shared.open(url); decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        private func push(_ theme: [String: String]) {
            guard !theme.isEmpty, let data = try? JSONSerialization.data(withJSONObject: theme),
                  let json = String(data: data, encoding: .utf8) else { return }
            eval("CK.setTheme(\(json))")
        }

        private func eval(_ js: String) {
            web?.evaluateJavaScript(js)
        }

        private func jsString(_ s: String) -> String {
            (try? String(data: JSONEncoder().encode(s), encoding: .utf8) ?? "\"\"") ?? "\"\""
        }
    }
}

/// The dashboard's two tabs: the TODO list (default) and a per-day markdown NOTE.
public enum DashTab: Hashable { case todo, note, proj }

extension DashTab {
    /// The JS-side tab key (CK.setTab / the "tab" message).
    var js: String {
        switch self {
        case .todo: "todo"
        case .note: "note"
        case .proj: "proj"
        }
    }

    static func fromJS(_ s: String?) -> DashTab {
        s == "note" ? .note : (s == "proj" ? .proj : .todo)
    }
}

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
    let inactive: Bool // drawer open → in-page scrim
    let frac: CGFloat
    let vp: Viewport
    let containerWidth: CGFloat
    let height: CGFloat
    let theme: Theme
    var onOpen: (String) -> Void
    var onCloseDrawer: () -> Void
    var onNoteExit: () -> Void = {}
    var onNavTab: (Bool) -> Void = { _ in }
    var todoSettings: DashTodoSettings? = nil // per-scope TODO layering prefs (pushed as JSON)
    var todoMenu: DashTodoMenuController? = nil // shared cog/right-click callout menu

    var body: some View {
        // The frame spans the FULL content region (labelW → right edge) and NEVER moves — panels
        // are positioned inside in pixels (dashScopePanels geometry via the tick), so there is no
        // frame snap at any level boundary. Clicks left of the live mask pass through to the
        // calendar via PassThroughWebView's hit gate.
        let left = Layout.padLeft + Layout.labelW
        let right = containerWidth - Layout.padRight
        let top = Layout.topPad + Layout.monthH + 14 // below the title + date rows
        let w = max(1, right - left)
        let h = max(1, height - top - Layout.bottomPad)

        DailyDashboardWebView(
            carousel: carousel, forwarder: forwarder, data: engine.dashboardDataJSON(),
            tab: tab, noteMode: noteMode, inactive: inactive,
            // Day view owns the cursor; a PINNED panel at month/week is interactive too.
            interactive: engine.chrome.level == 3
                || (engine.chrome.dashPinned && (1 ... 2).contains(engine.chrome.level)),
            todoPrefs: todoSettings?.jsJSON ?? "{}",
            todoMenu: todoMenu,
            theme: theme,
            onToggle: { id, occKey, value in engine.applyTodoNote(eventId: id, occKey: occKey, value: value) },
            onOpen: onOpen, onDeselect: { engine.deselect() },
            onTab: { tab = $0 }, onNoteMode: { noteMode = $0 },
            onNoteChange: { date, value in engine.setDailyNote(date, value) },
            onOpenLink: { NSWorkspace.shared.open($0) },
            onJumpDay: { date in
                // "YYYY-MM-DD" → fly to that day (like Today), then open its NOTE tab on landing.
                // Scope-note keys (weekly/monthly todos — TODO list rows and gantt titles alike):
                // "week:<sunday-iso>" → that week view; "month:<YYYY-MM>" → that month view — both
                // land with the panel pinned open on the NOTE tab (the note the todo lives in).
                if date.hasPrefix("week:") {
                    let c = date.dropFirst(5).split(separator: "-").compactMap { Int($0) }
                    guard c.count == 3 else { return }
                    engine.jumpToWeek(c[0], c[1] - 1, c[2])
                    engine.pinDashboard()
                    tab = .note
                    return
                }
                if date.hasPrefix("month:") {
                    let c = date.dropFirst(6).split(separator: "-").compactMap { Int($0) }
                    guard c.count == 2 else { return }
                    engine.setView(year: c[0], zoom: "month", focusedMonth: c[1] - 1)
                    engine.pinDashboard()
                    tab = .note
                    return
                }
                let c = date.split(separator: "-").compactMap { Int($0) }
                guard c.count == 3 else { return }
                engine.jumpToDay(c[0], c[1] - 1, c[2], onLand: { tab = .note })
            },
            onCloseDrawer: onCloseDrawer,
            onNoteExit: onNoteExit,
            onNavTab: onNavTab
        )
        .frame(width: w, height: h)
        // The WebView sits above the AppKit catcher and eats mouse-moves, so the catcher never gets to
        // run its `p.x >= dashLeft` hover guard → a timeline cursor line + time tag would stay frozen
        // (peeking out of the left edge). Clear the calendar hover the instant it's entered.
        .onHover {
            hovering in if hovering {
                engine.onHoverExit()
            }
        }
        .position(x: left + w / 2, y: top + h / 2)
    }
}

/// The TODO/NOTE tabs — a SEPARATE overlay (above the WebView, so the hosted WKWebView NSView can't
/// hit-test over them). Text-only, right-aligned in the title zone (mirrors the web's `.cc-dd-tabs`).
/// Placement is per-PANEL: each scope panel from dashScopePanels (via `anim`) gets its own row,
/// right-aligned to that panel's right edge and fading with the panel's opacity — so the tabs are
/// glued to their sliding sheet through every scope transition, exactly like the Canvas headers.
struct DashTabsOverlay: View {
    let engine: CalendarEngine
    let anim: DashCarouselAnim
    @Binding var tab: DashTab
    let frac: CGFloat
    let vp: Viewport
    let containerWidth: CGFloat
    let theme: Theme

    var body: some View {
        if engine.chrome.level >= 2 || (engine.chrome.dashPresented && engine.chrome.level >= 1) {
            // Each scope panel carries ITS OWN tabs row, right-aligned to THAT panel's right edge
            // (`x + w` from dashScopePanels — the same numbers the Canvas header and webview place
            // with), fading with the panel's cross-fade. So during a scope transition the rows
            // travel glued to their sliding sheets instead of jumping between mask formulas.
            panelTabs(name: anim.aName, x: anim.aX, w: anim.aW, op: anim.aOp)
            if anim.bOp > 0.001 {
                panelTabs(name: anim.bName, x: anim.bX, w: anim.bW, op: anim.bOp)
            }
        }
    }

    /// One panel's tabs row. `x`/`w` are the panel's own geometry (frame-local px, frame left =
    /// labelW). The month panel rides its band's animated top — a month page-turn shows TWO copies,
    /// each on its own band (identical rows: the pair reads as the tabs traveling with the sheets).
    /// Rows are additionally clipped at the live mask edge so an entering panel's tabs never draw
    /// over the calendar grid to the mask's left.
    @ViewBuilder private func panelTabs(name: String, x: Double, w: Double, op: Double) -> some View {
        let left = Layout.padLeft + Layout.labelW + CGFloat(x)
        let width = max(1, CGFloat(w))
        let opac = anim.reveal * op
        let clipLeft = max(0, CGFloat(anim.panelLeft) - (Layout.labelW + CGFloat(x)))
        if opac > 0.001 {
            let y0 = name == "month" ? CGFloat(anim.headerTopY) : CGFloat(Layout.topPad)
            // Inner horizontal paging within the panel: the day panel rides day page-turns, the
            // week panel rides the week-to-week turn (rests at BOTH ends of its progress).
            let (pageDir, pageP): (Int, Double) = name == "day"
                ? (anim.dir, anim.p)
                : (name == "week" ? (1, anim.weekP) : (0, 0))
            DashTabs(tab: $tab, theme: theme, anim: anim, w: width, op: opac,
                     clipLeft: clipLeft, pageDir: pageDir, pageP: pageP)
                .position(x: left + width / 2, y: y0 + Layout.monthH - 14)
            if name == "month", anim.monthP > 0.001 {
                DashTabs(tab: $tab, theme: theme, anim: anim, w: width, op: opac,
                         clipLeft: clipLeft, pageDir: 0, pageP: 0)
                    .position(x: left + width / 2, y: CGFloat(anim.headerTopY2) + Layout.monthH - 14)
            }
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
        // Day view, or the pinned weekly/monthly dashboard — every scope has a live note editor.
        if tab == .note,
           engine.chrome.level == 3 || (engine.chrome.dashPresented && engine.chrome.level >= 1) {
            let right = containerWidth - Layout.padRight
            let bottom = height - Layout.bottomPad
            // Visible only at FULL rest: revealed, no day-page, no scope-zoom, no month/week turn
            // (the week turn rests at 1 as well as 0).
            let atRest = anim.reveal > 0.5 && anim.p < 0.01
                && (anim.scopeT < 0.01 || anim.scopeT > 0.99) && anim.monthP < 0.01
                && (anim.weekP < 0.01 || anim.weekP > 0.99)
            Picker("", selection: $noteMode) {
                Image(systemName: "pencil").tag(NotesMode.edit)
                Image(systemName: "eye").tag(NotesMode.preview)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .tint(Theme.accent)
            .opacity(atRest ? 1 : 0) // hide during swipe / while zooming
            .position(x: right - 46, y: bottom - 2)
            .animation(.easeOut(duration: 0.12), value: atRest)
        }
    }
}

/// The TODO layering cog — bottom-right of the dashboard panel on the TODO tab (the NOTE tab's
/// edit/preview toggle sibling, same placement + rest gating). Left-click pops the native callout
/// menu (Display Deadlines / Show Collections ▸ / Collect from… ▸); right-clicking inside the
/// TODO panel pops the SAME menu (PassThroughWebView.todoContextMenu). The menu targets whichever
/// dashboard scope is currently visible (day / pinned week / pinned month).
struct TodoCogOverlay: View {
    let engine: CalendarEngine
    let anim: DashCarouselAnim
    let tab: DashTab
    let controller: DashTodoMenuController
    let containerWidth: CGFloat
    let height: CGFloat
    let theme: Theme

    var body: some View {
        if tab == .todo,
           engine.chrome.level == 3 || (engine.chrome.dashPresented && engine.chrome.level >= 1) {
            let right = containerWidth - Layout.padRight
            let bottom = height - Layout.bottomPad
            // Visible only at FULL rest — same gating as the note edit/preview toggle.
            let atRest = anim.reveal > 0.5 && anim.p < 0.01
                && (anim.scopeT < 0.01 || anim.scopeT > 0.99) && anim.monthP < 0.01
                && (anim.weekP < 0.01 || anim.weekP > 0.99)
            CogMenuButton(controller: controller, color: NSColor(theme.textMuted))
                .frame(width: 24, height: 24)
                .opacity(atRest ? 1 : 0)
                .allowsHitTesting(atRest)
                // Equal breathing room to the window's right and bottom edges: the center sits
                // bottomPad+2 (=30px) above the bottom, so match it horizontally (padRight is 0).
                .position(x: right - 30, y: bottom - 2)
                .animation(.easeOut(duration: 0.12), value: atRest)
        }
    }
}

/// AppKit gear button: NSViewRepresentable because popping the shared NSMenu needs a real NSView
/// anchor (NSMenu.popUp), and the menu itself is AppKit so the right-click path can share it.
private struct CogMenuButton: NSViewRepresentable {
    let controller: DashTodoMenuController
    let color: NSColor

    func makeNSView(context: Context) -> NSButton {
        let img = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "TODO list options")!
        let b = NSButton(image: img, target: context.coordinator, action: #selector(Coord.pop(_:)))
        b.isBordered = false
        b.contentTintColor = color
        context.coordinator.controller = controller
        return b
    }

    func updateNSView(_ b: NSButton, context: Context) {
        b.contentTintColor = color
        context.coordinator.controller = controller
    }

    func makeCoordinator() -> Coord { Coord() }

    @MainActor final class Coord: NSObject {
        var controller: DashTodoMenuController?
        @objc func pop(_ sender: NSButton) {
            guard let m = controller?.menu() else { return }
            m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
        }
    }
}

private struct DashTabs: View {
    @Binding var tab: DashTab
    let theme: Theme
    let anim: DashCarouselAnim
    let w: CGFloat // the OWNING panel's width — the row right-aligns inside it
    let op: Double // owning panel's opacity (cross-fade × reveal); the row inherits it
    let clipLeft: CGFloat // local x below which the row is masked (the live mask edge)
    let pageDir: Int // inner page-turn direction (day paging / week turn); 0 = none
    let pageP: Double // inner page-turn progress; the WEEK turn rests at both 0 AND 1
    var body: some View {
        ZStack {
            if pageDir != 0, pageP > 0.001, pageP < 0.999 {
                // Mid page-turn: two identical copies slide within the panel, one per sheet.
                row.offset(x: -CGFloat(pageDir) * pageP * w).opacity(op * (1 - pageP))
                row.offset(x: CGFloat(pageDir) * (1 - pageP) * w).opacity(op * pageP)
            } else {
                row.opacity(op)
            }
        }
        .frame(width: w, height: 24)
        .clipped() // clip a sliding copy at the panel edge
        .mask(alignment: .leading) { Rectangle().padding(.leading, clipLeft) }
        // Interactive only at rest: panel fully opaque (no scope transition), no inner page-turn
        // mid-flight (the week turn rests at 1 too), no month-turn in flight. The mid-flight term
        // mirrors the two-copy render condition above EXACTLY — if a single resting row is drawn,
        // it is clickable (a mismatched epsilon here once left a visible row that ignored clicks).
        .allowsHitTesting(op > 0.999 && !(pageDir != 0 && pageP > 0.001 && pageP < 0.999) && anim.monthP < 0.01)
    }

    private var row: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            TabLabel(title: "TODO", selected: tab == .todo, theme: theme) { tab = .todo }
            TabLabel(title: "PROJ", selected: tab == .proj, theme: theme) { tab = .proj }
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
                .tracking(0.9) // ~0.08em on 11px
                .foregroundStyle(theme.text)
                .opacity(selected ? 1 : (hovering ? 0.75 : 0.4))
                .padding(.horizontal, 5).padding(.vertical, 2).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
