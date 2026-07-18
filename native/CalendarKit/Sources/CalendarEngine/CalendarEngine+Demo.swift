// CalendarEngine+Demo — GIF-recording mode (env CC_DEMO): deterministic scene seeding and
// scripted input that drives the REAL pointer/pinch paths. Never touches personal data.

import Foundation
import CoreGraphics
import CalendarGeometry

extension CalendarEngine {
    // ── Demo / GIF-recording mode ──────────────────────────────────────────────────────────────
    /// True when launched for automated tutorial-GIF recording (env CC_DEMO=<scene>). In this mode the
    /// store is redirected to a throwaway dir (see ItemStore) and Apple Calendar import is skipped, so a
    /// recording never touches personal data. The DemoController scripts the on-screen scene.
    public static var isDemoMode: Bool { !(ProcessInfo.processInfo.environment["CC_DEMO"] ?? "").isEmpty }
    public static var demoScene: String { ProcessInfo.processInfo.environment["CC_DEMO"] ?? "" }
    /// Wipe the calendar to an empty state (recording scenes build their own deterministic content).
    public func demoClearEvents() {
        items.events = []; items.bands = []; items.deadlines = []; items.richById = [:]
        selectedId = nil; caches.editGen &+= 1; caches.deadlineGen &+= 1; wake()
    }
    /// Insert one ambient timed event (recording scenes; not on the undo stack, not selected).
    @discardableResult
    public func demoAddTimed(month: Int, day: Int, startHour: CGFloat, endHour: CGFloat, title: String, color: String) -> String {
        let id = "demo-\(items.events.count)"
        items.events.append(TimedEvent(id: id, year: year, month: month, day: day, startHour: startHour, endHour: endHour, title: title, color: color))
        caches.editGen &+= 1; caches.deadlineGen &+= 1; wake()
        return id
    }
    /// Insert one ambient all-day band (recording scenes; not selected).
    @discardableResult
    public func demoAddBand(month: Int, track: Int, startDay: Int, endDay: Int, title: String, color: String) -> String {
        let id = "demob-\(items.bands.count)"
        items.bands.append(BandEvent(id: id, year: year, month: month, track: track, startDay: startDay, endDay: endDay, title: title, color: color))
        caches.editGen &+= 1; caches.deadlineGen &+= 1; wake()
        return id
    }
    // Drive the REAL pointer/create path from VIEW-local points (GeometryReader space, 0,0 = top-left), so a
    // scripted drag creates an event exactly under the synthetic cursor — with the live create-preview. This
    // mirrors CatcherView.point(): geometry space = view − padLeft (+ the live drawer shift).
    private func demoViewToGeometry(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - Layout.padLeft + drawerShift, y: p.y) }
    public func demoPointerDown(atView p: CGPoint) { onPointerDown(at: demoViewToGeometry(p)) }
    public func demoPointerDrag(atView p: CGPoint) { onPointerDrag(at: demoViewToGeometry(p)) }
    public func demoPointerUp(atView p: CGPoint)   { onPointerUp(at: demoViewToGeometry(p)) }
    /// Rename the currently-selected event (recording scenes give a freshly drag-created event a real title).
    public func demoRenameSelected(_ title: String) {
        guard let id = selectedId, let i = items.events.firstIndex(where: { $0.id == id }) else { return }
        items.events[i].title = title; caches.editGen &+= 1; wake()
    }
    /// Rename the currently-selected BAND (band scenes name their freshly drag-created band).
    public func demoRenameSelectedBand(_ title: String) {
        guard let id = selectedId, let i = items.bands.firstIndex(where: { $0.id == id }) else { return }
        items.bands[i].title = title; caches.editGen &+= 1; wake()
    }
    /// Snap the view to year level, scrolled so `centerMonth` is visible (deterministic scene setup).
    public func demoGoToYear(centerMonth: Int) {
        cancelTween()
        z = 0; focus = centerMonth
        ensureMonthVisible(centerMonth, animated: false)
        caches.editGen &+= 1; caches.deadlineGen &+= 1; wake()
    }
    /// Drive the REAL pinch path (`onMagnify`) from a view point, so the month/week/day under `v` is exactly
    /// what fills the screen (`captureFocus` anchors on the pinch point — unlike the keyboard/block zoom,
    /// which snaps to the block cursor / today). The recording's pinch visual is drawn at this same point, so
    /// the gesture and the zoom target always line up. `delta` is trackpad-style magnification (Motion.pinchSens
    /// scales it into z); a full single-level pinch accumulates ≈0.7 (see DemoController.pinch).
    public func demoMagnify(delta: CGFloat, atView v: CGPoint, began: Bool, ended: Bool) {
        onMagnify(delta: delta, at: demoViewToGeometry(v), began: began, ended: ended)
    }
    /// Double-click an item at a view point: select it (so it highlights) and open its drawer — the same
    /// outcome as a real double-click. Returns the item id, or nil if nothing was under the point.
    @discardableResult
    public func demoDoubleClick(atView v: CGPoint) -> String? {
        guard let id = itemId(at: demoViewToGeometry(v)) else { return nil }
        selectedId = id
        onRequestOpenDrawer?(id, false)
        caches.editGen &+= 1; wake()
        return id
    }
    /// Select an item by id (highlight it), e.g. a just-created event in the AI scene.
    public func demoSelect(_ id: String?) { selectedId = id; caches.editGen &+= 1; wake() }
}
