// Screen geometry for all-day (band) events and deadlines. Ported from geometry/bandGeom.ts
// and the deadline placement in DeadlinesLayer (xOf(day) × yOf(hour)).

import CoreGraphics

// ── All-day band events ──────────────────────────────────────────────────────────
public struct BandEvent: Sendable, Identifiable, Equatable, Codable {
    public var id: String
    public var year: Int
    public var month: Int       // 0–11
    public var track: Int       // 0–3 lane
    public var startDay: Int    // 1..daysInMonth
    public var endDay: Int      // inclusive, >= startDay
    public var title: String
    public var color: String
    public init(id: String, year: Int, month: Int, track: Int, startDay: Int, endDay: Int, title: String, color: String) {
        self.id = id; self.year = year; self.month = month; self.track = track
        self.startDay = startDay; self.endDay = endDay; self.title = title; self.color = color
    }
}

public struct BandRect: Sendable {
    public var x: CGFloat; public var y: CGFloat; public var w: CGFloat; public var h: CGFloat
    public var clipStart: Bool; public var clipEnd: Bool
}

private func bandOnScreen(_ bandY: CGFloat, _ trackH: CGFloat, _ vp: Viewport) -> Bool {
    bandY <= vp.h + 10 && bandY + 4 * trackH >= -10
}

public func bandEventRect(_ ev: BandEvent, _ g: SceneInput, anim: PageAnim? = nil) -> BandRect? {
    let f = frameFor(ev.month, g, anim: anim)
    if f.opacity < 0.02 || !bandOnScreen(f.bandY, f.trackH, g.vp) { return nil }
    let x = f.x0 + CGFloat(ev.startDay - 1) * f.dayW
    let w = CGFloat(ev.endDay - ev.startDay + 1) * f.dayW
    let leftRaw = x + 2   // 2px inset from the enclosing day-cell borders
    let rightRaw = x + w - 2
    let left = max(leftRaw, Layout.labelW)
    let right = min(rightRaw, g.vp.w)
    if right - left < 2 { return nil }
    return BandRect(
        x: left,
        y: f.bandY + CGFloat(ev.track) * f.trackH + 1,   // 1px from top/bottom
        w: max(2, right - left),
        h: max(3, f.trackH - 2),
        clipStart: leftRaw < Layout.labelW - 0.5,
        clipEnd: rightRaw > g.vp.w + 0.5
    )
}

/// Which month band / track lane / day is under the cursor (for create + move, later).
public func bandSlotAtPoint(_ px: CGFloat, _ py: CGFloat, _ g: SceneInput) -> (month: Int, track: Int, day: Int)? {
    if px < Layout.labelW { return nil }
    for m in 0..<12 {
        let f = frameFor(m, g)
        if f.opacity < 0.02 || !bandOnScreen(f.bandY, f.trackH, g.vp) { continue }
        if py < f.bandY || py >= f.bandY + 4 * f.trackH { continue }
        let dim = daysInMonth(g.year, m)
        let day = Int((px - f.x0) / f.dayW) + 1
        if day < 1 || day > dim { continue }
        return (m, min(3, max(0, Int((py - f.bandY) / f.trackH))), day)
    }
    return nil
}

// ── Deadlines ──────────────────────────────────────────────────────────────────────
public struct Deadline: Sendable, Identifiable, Equatable, Codable {
    public var id: String
    public var year: Int
    public var month: Int
    public var day: Int
    public var hour: CGFloat    // 0–24 fractional
    public var title: String
    public var color: String
    public init(id: String, year: Int, month: Int, day: Int, hour: CGFloat, title: String, color: String) {
        self.id = id; self.year = year; self.month = month; self.day = day
        self.hour = hour; self.title = title; self.color = color
    }
}

/// A deadline's line position on the day-detail timeline: a horizontal rule across the
/// day column at the deadline's hour. nil when off the focused window or scrolled out.
public func deadlinePos(_ d: Deadline, _ g: SceneInput) -> (x: CGFloat, y: CGFloat, w: CGFloat)? {
    let tl = timelineInfo(g)
    guard tl.reveal > 0.05, tl.hourH > 0, let rd = relDomOf(g.year, g.focus, d.month, d.day) else { return nil }
    let x = tl.x0 + CGFloat(rd - 1) * tl.colW
    let y = tl.tlTop + d.hour * tl.hourH - tl.scroll
    if y < tl.tlTop || y > tl.tlBottom { return nil }
    return (x, y, tl.colW)
}
