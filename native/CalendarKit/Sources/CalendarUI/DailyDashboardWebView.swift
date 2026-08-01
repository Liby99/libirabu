// ⚠️ WEBVIEW FALLBACK ONLY (cc.nativeDashOff / CC_NATIVE_DASH_OFF): the native dashboard is
// the default and this file's views are NOT MOUNTED under it. Slated for legacy/ retirement
// once the native path has soaked (phase 4a); the permanent native chrome moved to
// DashChrome.swift.
//
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

/// The dashboard's WKWebView, which forwards horizontal scroll + pinch to the calendar instead of
/// eating them. VERTICAL scroll stays here (the TODO list, with native rubber-band); horizontal
/// scroll pages days and pinch zooms — both handled by the InputCatcher underneath.
final class PassThroughWebView: WKWebView, FocusGatedControl {
    weak var forwarder: GestureForwarder?

    /// The reveal FADE, applied natively (view alphaValue — plain AppKit compositing of the hosted
    /// layer, safe). Panel MOTION stays in CSS: transforming the WKWebView's own layer
    /// (sublayerTransform) fought WebKit's remote-layer commits — each web-process commit
    /// re-asserted its geometry, alternating shifted/reset frames, i.e. flicker.
    /// `keepLive`: the ⌘B panel is PRESENTED (pin intent on — flips at press, clears at retract
    /// end). Un-hiding a WKWebView costs a full-document style/layout/paint in the web process
    /// (~30-50ms on a todo-heavy month), so doing it lazily on the first reveal tick dropped web
    /// frames right at the slide's start. While presented, floor the alpha just above the hide
    /// threshold — the view stays technically visible (invisible to the eye) and the repaint cost
    /// never lands mid-slide. Hidden semantics (mouse tracking, cursor, hit-test) stay for the
    /// genuinely-retracted state.
    func setPanelAlpha(_ alpha: CGFloat, keepLive: Bool = false) {
        let a = keepLive ? max(alpha, 0.011) : alpha
        if alphaValue != a {
            alphaValue = a
        }
        // Fully faded (year view / pre-reveal) → actually HIDDEN. An invisible-but-present
        // WKWebView still runs WebKit's own mouse tracking and sets the WEB cursor (CSS pointer
        // over its unseen rows) against the calendar's grab hand — the year-view hover flicker —
        // and its stale interactiveLeftX could swallow clicks. Hidden removes it from tracking,
        // hit-testing, and cursor updates in one move; the first reveal tick un-hides it.
        let hide = a < 0.01
        if isHidden != hide {
            isHidden = hide
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
              shiftX: Double = 0, keepLive: Bool = false) {
        // Native default: no webview is ever registered — skip building the per-frame
        // CK.tick JSON payload entirely (it was pure waste at 120Hz).
        if web == nil, NativeDash.enabled { return }
        let key = "\(from)|\(to)|\(dir)|\(Int((p * 1000).rounded()))|\(Int((reveal * 1000).rounded()))|\(Int((slide * 1000).rounded()))|\(scopeA)|\(scopeB)|\(Int((scopeT * 1000).rounded()))|\(Int(dy.rounded()))|\(mFrom)|\(mTo)|\(Int(mDy0.rounded()))|\(Int(mDy1.rounded()))|\(Int((mP * 1000).rounded()))|\(mKeyA)|\(mKeyB)|\(wFrom)|\(wTo)|\(Int((wP * 1000).rounded()))|\(wKeyA)|\(wKeyB)|\(Int(maskX.rounded()))|\(Int(maskW.rounded()))|\(aName)|\(Int(aX.rounded()))|\(Int(aW.rounded()))|\(Int((aOp * 1000).rounded()))|\(bName)|\(Int(bX.rounded()))|\(Int(bW.rounded()))|\(Int((bOp * 1000).rounded()))|\(Int(shiftX.rounded()))|\(keepLive)"
        if key == lastKey {
            return
        }
        lastKey = key
        // Reveal fade natively (safe: view-level alpha); motion stays in CSS — see setPanelAlpha.
        // The hit gate tracks the live mask edge so only the panel area belongs to the webview
        // (shifted left with the content while the drawer canvas-shift is riding).
        if let ptw = web as? PassThroughWebView {
            ptw.setPanelAlpha(CGFloat(reveal), keepLive: keepLive)
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

    /// ── Webview frame bench (CC_DEMO=bench-*) ──────────────────────────────────────────────────
    /// The panel's content renders in the WebKit CONTENT PROCESS — the app-side frame counter can
    /// read a flawless 120fps while the panel itself janks. These install/collect a rAF timestamp
    /// recorder in the page, so bench scenes can report the page's own frame cadence next to the
    /// native one. (rAF stops while WebKit considers the view invisible — interpret retracted
    /// phases accordingly; the swipe/toggle scenes keep the panel on screen.)
    func benchWebStart() {
        guard ready, web != nil else { return }
        // A/B: CC_WEB_DEFER_OFF=1 disables the on-demand row window (everything renders inline,
        // the pre-window behavior).
        if ProcessInfo.processInfo.environment["CC_WEB_DEFER_OFF"] != nil {
            eval("CK.setDeferBudget(1e9)")
        }
        // Alongside the rAF clock: SLOW CK.TICK APPLIES — every frame of page work is driven
        // through CK.tick (WebKit has no 'longtask' observer), so wrapping it catches real JS +
        // forced-layout cost directly. A big rAF gap with no slow tick = the page was merely
        // suspended while hidden (an artifact, nothing was on screen); WITH one = actual jank.
        eval("""
        (function(){ window.CKBENCH = { on: true, t: [], lt: [], epoch: [Date.now(), performance.now()] };
          if (window.CK && !CKBENCH.orig) {
            CKBENCH.orig = CK.tick; CKBENCH.origData = CK.setData;
            const wrap = function(fn){ return function(a){ const t0 = performance.now();
              fn.call(CK, a); const d = performance.now() - t0;
              if (d > 4) CKBENCH.lt.push([t0, Math.round(d * 10) / 10]); }; };
            CK.tick = wrap(CKBENCH.orig); CK.setData = wrap(CKBENCH.origData);
          }
          function lp(ts){ if (!CKBENCH.on) return; CKBENCH.t.push(ts); requestAnimationFrame(lp); }
          requestAnimationFrame(lp); })()
        """)
    }

    /// Stop the recorder and return the page's rAF timestamps (ms, performance.now clock), its
    /// slow CK.tick/setData applies [(start, duration)], and named render units >2ms (guarded()).
    func benchWebCollect() async -> (frames: [Double], longTasks: [[Double]], units: [[Any]],
                                     epoch: [Double]) {
        guard ready, let web else { return ([], [], [], []) }
        return await withCheckedContinuation { cont in
            web.evaluateJavaScript(
                """
                (window.CKBENCH ? (CKBENCH.on = false,
                  CKBENCH.orig && (CK.tick = CKBENCH.orig, CK.setData = CKBENCH.origData,
                                   CKBENCH.orig = null),
                  JSON.stringify({t: CKBENCH.t, lt: CKBENCH.lt, units: CKBENCH.units || [],
                                  epoch: CKBENCH.epoch, vis: document.visibilityState})) : '{}')
                """
            ) { r, _ in
                let obj = (r as? String).flatMap { s in
                    (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
                }
                cont.resume(returning: (obj?["t"] as? [Double] ?? [],
                                        obj?["lt"] as? [[Double]] ?? [],
                                        obj?["units"] as? [[Any]] ?? [],
                                        obj?["epoch"] as? [Double] ?? []))
            }
        }
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
    /// around the editor while the caret blinks inside it. `line`: a todo-row jump — once the
    /// editor lands, that source line is SELECTED (the clicked item arrives highlighted).
    /// `key` (same jump): the target note's storage key ("YYYY-MM-DD" / "week:…" / "month:…") —
    /// the JS side holds the focus as a callback until the live editor mounts THAT note (the end
    /// of the fly-to animation), and drops it if the flight is interrupted or superseded.
    func focusNoteEditor(ring: Bool = false, line: Int? = nil, key: String? = nil) {
        guard let w = web as? PassThroughWebView else { return }
        // Defer to the NEXT runloop tick: this is called from within the Enter keyDown dispatch, and
        // making the web view first responder synchronously mid-keyDown routes that same Enter into the
        // freshly-focused CodeMirror as a stray newline. Letting the keyDown finish first avoids that.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            w.allowFocus(); w.window?.makeFirstResponder(w)
            self.eval("CK.noteEdit(\(ring), \(line.map(String.init) ?? "null"), \(key.map(self.js) ?? "null"))")
        }
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
    var onNoteChange: (_ date: String, _ value: String, _ seq: Int) -> Void
    var onOpenLink: (URL) -> Void
    var onJumpDay: (_ date: String, _ line: Int?) -> Void
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
        // WebKit caps page rendering updates near 60fps by default (a power policy), so on a
        // 120Hz display the panel's CSS-driven slides trail the native canvas at half rate —
        // measured web 60.0fps flat vs native 118.5 (bench-dash-toggle web_* stats). Lift the cap
        // through the feature-flag SPI when present (guards make missing SPI a silent no-op →
        // stays at 60). CC_WEB120_OFF=1 restores the default for A/B.
        Self.liftWeb60Cap(cfg.preferences)
        let web = PassThroughWebView(frame: .zero, configuration: cfg) // forwards horizontal scroll + pinch
        // Bench/demo runs only: keep the page "visible" even when the window is occluded (bench
        // launches often land behind the active Space/full-screen app — occlusion suspends the
        // page's rendering updates and the web-side frame recorder flatlines). Real runs keep the
        // power-saving default. Guarded SPI: absent → occluded runs simply report no web frames.
        if CalendarEngine.isDemoMode {
            let sel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
            if web.responds(to: sel) {
                typealias SetBool = @convention(c) (NSObject, Selector, Bool) -> Void
                unsafeBitCast(web.method(for: sel), to: SetBool.self)(web, sel, false)
            }
        }
        // Launch state = fully-faded state: HIDDEN until the first reveal tick. The tick driver
        // isn't mounted at year level, so without this a fresh launch left the view present at
        // its default alpha 1 — visually blank (CSS reveal 0) but with WebKit's mouse tracking
        // live, fighting the calendar's hover cursor (the launch-only year-view flicker).
        web.setPanelAlpha(0)
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

    /// Disable WebKit's "PreferPageRenderingUpdatesNear60FPS" feature on `prefs` so the page
    /// renders at the display's real refresh rate (120 on ProMotion). No public API exists; the
    /// flag is reached through the WKPreferences feature-list SPI, every step guarded so an OS
    /// that renames/removes it degrades to the stock 60fps cap instead of crashing.
    static func liftWeb60Cap(_ prefs: WKPreferences) {
        guard ProcessInfo.processInfo.environment["CC_WEB120_OFF"] == nil else { return }
        let listSel = NSSelectorFromString("_features")
        let setSel = NSSelectorFromString("_setEnabled:forFeature:")
        guard let cls = WKPreferences.self as AnyObject as? NSObject.Type,
              cls.responds(to: listSel), prefs.responds(to: setSel),
              let features = cls.perform(listSel)?.takeUnretainedValue() as? [NSObject],
              let flag = features.first(where: {
                  ($0.value(forKey: "key") as? String) == "PreferPageRenderingUpdatesNear60FPSEnabled"
              })
        else { return }
        // _setEnabled: takes a BOOL — perform(_:with:) would box it as an object, so go
        // through the raw IMP with the proper C signature.
        typealias SetEnabled = @convention(c) (NSObject, Selector, Bool, NSObject) -> Void
        unsafeBitCast(prefs.method(for: setSel), to: SetEnabled.self)(prefs, setSel, false, flag)
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
        var onNoteChange: (_ date: String, _ value: String, _ seq: Int) -> Void
        var onOpenLink: (URL) -> Void
        var onJumpDay: (String, Int?) -> Void
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
             onNoteMode: @escaping (NotesMode) -> Void, onNoteChange: @escaping (String, String, Int) -> Void,
             onOpenLink: @escaping (URL) -> Void, onJumpDay: @escaping (String, Int?) -> Void,
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
            case "err":
                // A contained webview render failure (dashboard.ts guarded()) — the dashboard keeps
                // working; log the culprit so the underlying render bug is visible + fixable.
                print("⚠️ [dashboard] render error in \(body["where"] as? String ?? "?"): " +
                    (body["message"] as? String ?? "?"))
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
                    onNoteChange(date, v, body["seq"] as? Int ?? 0)
                }
            case "jumpDay":
                if let date = body["date"] as? String {
                    onJumpDay(date, body["line"] as? Int)
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
            // Day view owns the cursor — via the WEBVIEW only when the native panels aren't
            // standing in for it (cc.nativeDash blanks the page and takes the cursor yield).
            interactive: engine.chrome.level == 3 && !NativeDash.enabled
                || (engine.chrome.dashPinned && (1 ... 2).contains(engine.chrome.level)),
            todoPrefs: todoSettings?.jsJSON ?? "{}",
            todoMenu: todoMenu,
            theme: theme,
            onToggle: { id, occKey, value in engine.applyTodoNote(eventId: id, occKey: occKey, value: value) },
            onOpen: onOpen, onDeselect: { engine.deselect() },
            onTab: { tab = $0 }, onNoteMode: { noteMode = $0 },
            // Record the post's seq BEFORE applying it, so any JSON built from here on carries it
            // (the editor refuses payloads older than its latest post — see engine.dashNoteSeq).
            onNoteChange: { date, value, seq in
                engine.dashNoteSeq = seq
                engine.setDailyNote(date, value)
            },
            onOpenLink: { NSWorkspace.shared.open($0) },
            onJumpDay: { [carousel] date, line in
                // "YYYY-MM-DD" → fly to that day (like Today), then open its NOTE tab on landing.
                // Scope-note keys (weekly/monthly todos — TODO list rows and gantt titles alike):
                // "week:<sunday-iso>" → that week view; "month:<YYYY-MM>" → that month view — both
                // land with the panel pinned open on the NOTE tab (the note the todo lives in).
                // `line` (the clicked todo's source line): the editor focuses and SELECTS it once
                // the live editor mounts the target note — `date` doubles as that note's storage
                // key, so CK.noteEdit holds the focus as a callback until the fly-to animation
                // actually lands on it (and drops it if the flight is interrupted).
                // The NOTE tab is selected ON LANDING (not at flight start): CalendarView's
                // "leaving day view → snap to TODO" level reset fires during the travel and would
                // clobber an early switch; the landing callback runs after it by construction.
                if date.hasPrefix("week:") {
                    let c = date.dropFirst(5).split(separator: "-").compactMap { Int($0) }
                    guard c.count == 3 else { return }
                    engine.jumpToWeek(c[0], c[1] - 1, c[2], onLand: {
                        tab = .note
                        carousel.focusNoteEditor(line: line, key: date)
                    })
                    engine.pinDashboard()
                    return
                }
                if date.hasPrefix("month:") {
                    let c = date.dropFirst(6).split(separator: "-").compactMap { Int($0) }
                    guard c.count == 2 else { return }
                    engine.jumpToMonth(c[0], c[1] - 1, onLand: {
                        tab = .note
                        carousel.focusNoteEditor(line: line, key: date)
                    })
                    engine.pinDashboard()
                    return
                }
                let c = date.split(separator: "-").compactMap { Int($0) }
                guard c.count == 3 else { return }
                engine.jumpToDay(c[0], c[1] - 1, c[2], onLand: {
                    tab = .note
                    carousel.focusNoteEditor(line: line, key: date)
                })
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
