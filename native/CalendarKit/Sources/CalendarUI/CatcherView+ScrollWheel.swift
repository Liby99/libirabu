// CatcherView's native-panel horizontal scroll forwarding: the local scroll-wheel monitor
// routing panel-origin horizontal gestures back to the catcher, plus the CC_DASH_DIAG
// tracing. The scrollWheel override itself stays in CalendarInputLayer.swift (overrides
// must live in the class body).
// Split from CalendarInputLayer.swift (audit round, 2026-08-02).

import AppKit
import CalendarEngine
import CalendarGeometry
import SwiftUI

extension CatcherView {
    // ── Native-panel horizontal forwarding ────────────────────────────────────────────────
    // The webview panel forwarded horizontal gestures to this catcher itself
    // (PassThroughWebView.scrollWheel: axis-lock once per gesture, route the WHOLE gesture —
    // its .ended and momentum tail included — to one target). The native panels' scroll views
    // belong to SwiftUI, so they can't inherit that override — horizontal swipes STARTING over
    // the panel were silently eaten (day paging dead over the dashboard; a diverted tail could
    // strand the day animation mid-flight). This local monitor recreates the exact routing:
    // gestures that BEGIN over the panel region latch their axis at the first real delta;
    // horizontal ones are re-dispatched to the catcher (native day/week paging + momentum),
    // vertical ones stay with the panel's own scroller. Phaseless legacy wheels are never
    // intercepted.
    /// CC_DASH_DIAG=1 → trace the day-swipe event path (routing decisions, gesture opens/closes,
    /// early-return reasons) to the console, throttled. For hunting the "stuck day swipe".
    static let diag = ProcessInfo.processInfo.environment["CC_DASH_DIAG"] != nil
    func dlog(_ msg: @autoclosure () -> String, always: Bool = false) {
        guard Self.diag else { return }
        if !always, Date().timeIntervalSince(lastDiag) < 0.2 {
            return
        }
        lastDiag = Date()
        print("[dash-diag] \(msg())")
    }

    func installPanelScrollMonitor() {
        guard panelScrollMonitor == nil else { return }
        panelScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self, let engine = self.engine,
                  e.window === self.window else { return e }
            if e.phase.isEmpty, e.momentumPhase.isEmpty {
                return e
            } // legacy wheel: hands off
            if e.phase.contains(.began) || e.phase.contains(.mayBegin) {
                self.panelAxis = .undecided
                // Who does this gesture belong to? Hit-test its start point once and latch.
                let cv = self.window?.contentView
                let sp = cv?.superview?.convert(e.locationInWindow, from: nil) ?? .zero
                self.catcherOwnsGesture = (cv?.hitTest(sp) === self)
                let levelOK = engine.chrome.level == 3
                    || (engine.dashPinned && (1 ... 2).contains(engine.chrome.level))
                self.panelGestureCaptured = !self.catcherOwnsGesture && levelOK
                    && !engine.drawerOpen && engine.inDayDashboard(self.point(e))
                self.dlog(
                    "monitor: gesture began, owns=\(self.catcherOwnsGesture) captured=\(self.panelGestureCaptured)",
                    always: true
                )
            }
            if self.catcherOwnsGesture {
                // Deliver directly (and consume) so pointer drift can't re-route the tail.
                self.scrollWheel(with: e)
                return nil
            }
            guard self.panelGestureCaptured else { return e }
            if self.panelAxis == .undecided {
                let dx = abs(e.scrollingDeltaX), dy = abs(e.scrollingDeltaY)
                if dx > 0 || dy > 0 {
                    self.panelAxis = dx > dy ? .horizontal : .vertical
                }
            }
            guard self.panelAxis == .horizontal else { return e } // vertical: the panel scrolls
            self
                .dlog(
                    "monitor: → catcher (horizontal over panel) phase=\(e.phase.rawValue) mom=\(e.momentumPhase.rawValue)"
                )
            self.scrollWheel(with: e) // day/week paging with native momentum, like the webview
            return nil
        }
    }
}
