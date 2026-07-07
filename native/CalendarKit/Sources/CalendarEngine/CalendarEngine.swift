// The mutable view-state + tween clock. Geometry is stateless; this is where z,
// focus, week, scroll, hover, and the animation live. SwiftUI observes it directly.

import Foundation
import CoreGraphics
import CalendarGeometry

// Plain reference type (not @Observable): the view redraws every frame via
// TimelineView(.animation), which reads a fresh SceneInput and advances the tween
// from the display clock — so observation isn't needed and can't cause update loops.
@MainActor
public final class CalendarEngine {
    // View state
    public private(set) var z: CGFloat = 0
    public private(set) var focus: Int
    public private(set) var week: CGFloat = 0
    public private(set) var scrollY: CGFloat = 0
    public private(set) var tlScroll: CGFloat = 0
    public private(set) var daily: DailyState
    public private(set) var hover: Hover = .none
    public private(set) var year: Int
    public private(set) var now: Date = Date()
    public var weekHourH: CGFloat = 60
    public private(set) var viewport: Viewport = Viewport(w: 1, h: 1)
    public private(set) var seedEvents: [TimedEvent] = []
    public let trackNames = TRACKS.map { $0.name }

    private var tween: Tween?
    private var weekTween: Tween?
    private var snapWork: DispatchWorkItem?
    private var wheelAccumX: CGFloat = 0
    // pinch state
    private var magStartZ: CGFloat = 0
    private var magAccum: CGFloat = 0
    private var nowTimer: Timer?

    private let ZOOM_DUR: TimeInterval = 0.52
    private let PINCH_SENS: CGFloat = 2.6

    public init() {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        year = c.year ?? 2026
        focus = (c.month ?? 1) - 1
        daily = DailyState(dom: c.day ?? 1, frac: 0.45)
        seedEvents = Self.makeSeeds(month: focus, day: c.day ?? 15)
        nowTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
    }

    // ── Frame snapshot ──────────────────────────────────────────────────────────
    private func snapshot() -> SceneInput {
        SceneInput(z: z, focus: focus, week: week, vp: viewport, scrollY: scrollY, tlScroll: tlScroll,
                   now: now, year: year, hover: hover, weekHourH: weekHourH, daily: daily)
    }

    /// Advance the tween to `date` and return the immutable input for this frame.
    public func sceneInput(at date: Date, viewport vp: Viewport) -> SceneInput {
        viewport = vp
        if let t = tween {
            z = t.value(at: date)
            if t.isComplete(at: date) { z = t.to; tween = nil }
        }
        if let wt = weekTween {
            week = wt.value(at: date)
            if wt.isComplete(at: date) { week = wt.to; weekTween = nil }
        }
        return snapshot()
    }

    public func setViewport(_ size: CGSize) {
        viewport = Viewport(w: size.width, h: size.height)
        scrollY = clamp(scrollY, 0, yearMaxScroll(viewport))
    }

    // ── Levels + tween helpers ────────────────────────────────────────────────────
    private func level(_ z: CGFloat) -> Int { z < 0.5 ? 0 : (z < 1.5 ? 1 : (z < 2.5 ? 2 : 3)) }

    private func cancelTween() {
        if let t = tween { z = t.value(at: Date()); tween = nil }
        if let wt = weekTween { week = wt.value(at: Date()); weekTween = nil }
        snapWork?.cancel()
    }

    private func scheduleWeekSnap(_ maxWeek: CGFloat) {
        snapWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let target = clamp((self.week * 7).rounded() / 7, 0, maxWeek)
            self.weekTween = Tween(from: self.week, to: target, start: Date(), duration: 0.2, ease: easeInOut)
        }
        snapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    public func tweenZ(to target: CGFloat, dur: TimeInterval? = nil) {
        tween = Tween(from: z, to: clamp(target, 0, 3), start: Date(), duration: dur ?? ZOOM_DUR, ease: easeInOut)
    }

    // ── Gestures ──────────────────────────────────────────────────────────────────
    public func onWheel(dx: CGFloat, dy: CGFloat) {
        cancelTween()
        let b = level(z)
        if b == 0 {
            scrollY = clamp(scrollY - dy, 0, yearMaxScroll(viewport))
        } else if abs(dy) >= abs(dx) {
            let tl = timelineInfo(snapshot())
            tlScroll = min(max(0, tlScroll - dy), tl.maxScroll)
        } else if b == 2 {
            weekTween = nil
            let maxWeek = CGFloat(max(0, weeksInMonth(year, focus) - 1))
            week = clamp(week - dx / (viewport.w - Layout.labelW), 0, maxWeek)  // swipe-left → later days
            scheduleWeekSnap(maxWeek)
        } else if b == 3 {
            wheelAccumX += dx
            if abs(wheelAccumX) > 55 {
                daily.dom = min(daysInMonth(focus), max(1, daily.dom + (wheelAccumX < 0 ? 1 : -1)))  // swipe-left → next day
                wheelAccumX = 0
            }
        }
    }

    public func onMagnify(delta: CGFloat, at p: CGPoint, began: Bool, ended: Bool) {
        if began {
            cancelTween()
            magStartZ = z
            magAccum = 0
            captureFocus(at: p)
        } else if ended {
            tweenZ(to: z.rounded())
        } else {
            magAccum += delta
            z = clamp(magStartZ + magAccum * PINCH_SENS, 0, 3)
        }
    }

    private func captureFocus(at p: CGPoint) {
        let g = snapshot()
        switch level(z) {
        case 0:
            if let m = monthAtPoint(p.x, p.y, g) { focus = m }
        case 1:
            if let w = weekAtPointInMonth(p.x, g) { week = CGFloat(w) }
        case 2:
            if let d = dayAtPointInWeek(p.x, g) { focus = d.month; week = CGFloat(d.week); daily.dom = d.day }
        default: break
        }
    }

    public func onClick(at p: CGPoint) {
        cancelTween()
        let g = snapshot()
        switch level(z) {
        case 0:
            if let m = monthAtPoint(p.x, p.y, g) ?? monthNameAtPoint(p.x, p.y, g) { focus = m; tweenZ(to: 1) }
        case 1:
            if let w = weekAtPointInMonth(p.x, g) { week = CGFloat(w); tweenZ(to: 2) }
        case 2:
            if let d = dayAtPointInWeek(p.x, g) { focus = d.month; week = CGFloat(d.week); daily.dom = d.day; tweenZ(to: 3) }
        default: break
        }
    }

    public func onEscape() {
        cancelTween()
        tweenZ(to: CGFloat(max(0, level(z) - 1)))
    }

    public func onHover(at p: CGPoint) {
        let g = snapshot()
        var hv = Hover()
        switch level(z) {
        case 0:
            let m = monthRowAtPoint(p.x, p.y, g)
            hv.month = m
            hv.nameMonth = monthNameAtPoint(p.x, p.y, g)
            if let m { hv.dom = domInMonthBand(p.x, m, g) }
        case 1:
            hv.dom = domInFocus(p.x, g)
            hv.week = weekAtPointInMonth(p.x, g)
        default:
            let c = cellInWeek(p.x, p.y, g)
            hv.dom = c.dom; hv.hour = c.hour; hv.hourFrac = c.hourFrac; hv.nearLeft = c.nearLeft
        }
        hover = hv
    }

    public func onHoverExit() { hover = .none }

    // ── Seed data (display only, until the sync layer lands) ─────────────────────
    private static func makeSeeds(month: Int, day: Int) -> [TimedEvent] {
        let d0 = max(1, min(daysInMonth(month) - 2, day))
        return [
            TimedEvent(id: "s1", month: month, day: d0, startHour: 9, endHour: 10, title: "Standup", color: "blue"),
            TimedEvent(id: "s2", month: month, day: d0, startHour: 11, endHour: 12.5, title: "Design review", color: "green"),
            TimedEvent(id: "s3", month: month, day: d0, startHour: 11.5, endHour: 13, title: "1:1 with Alex", color: "yellow"),
            TimedEvent(id: "s4", month: month, day: d0, startHour: 14, endHour: 15, title: "Lecture", color: "red"),
            TimedEvent(id: "s5", month: month, day: min(daysInMonth(month), d0 + 1), startHour: 10, endHour: 11.5, title: "Research sync", color: "blue"),
            TimedEvent(id: "s6", month: month, day: min(daysInMonth(month), d0 + 1), startHour: 16, endHour: 18, title: "Seminar", color: "purple"),
        ]
    }
}
