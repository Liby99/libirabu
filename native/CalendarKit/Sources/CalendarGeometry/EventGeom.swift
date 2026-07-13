// Timed-event data ↔ screen geometry, mirroring scene.ts buildDetail so events line
// up exactly with the rendered day columns / hour timeline. Ported from geometry/eventGeom.ts.

import CoreGraphics

public let MIN_HOUR_H: CGFloat = 35
public let MAX_HOUR_H: CGFloat = 90

public func clampHourH(_ h: CGFloat) -> CGFloat { min(MAX_HOUR_H, max(MIN_HOUR_H, h)) }

public struct HourMetrics: Sendable {
    public var viewH: CGFloat
    public var hourH: CGFloat
    public var maxScroll: CGFloat
    public var zoomable: Bool
    public var scroll: CGFloat
}

/// Hour height + scroll for a timeline window. month (z≤1) fits the viewport; week
/// (z≥2) uses the slider height. `weekHourH` was a module global in the TS.
public func hourMetrics(_ tlTop: CGFloat, _ tlBottom: CGFloat, _ z: CGFloat, _ tlScroll: CGFloat, _ weekHourH: CGFloat) -> HourMetrics {
    let viewH = max(0, tlBottom - tlTop)
    let fitH = viewH > 0 ? viewH / 24 : 0
    let weekMin = max(MIN_HOUR_H, fitH)
    let weekMax = max(weekMin, MAX_HOUR_H)
    let weekH = min(weekMax, max(weekMin, weekHourH))
    let hourH = fitH + (weekH - fitH) * min(1, max(0, z - 1))
    let maxScroll = max(0, 24 * hourH - viewH)
    let zoomable = fitH < MAX_HOUR_H
    return HourMetrics(viewH: viewH, hourH: hourH, maxScroll: maxScroll, zoomable: zoomable,
                       scroll: min(max(0, tlScroll), maxScroll))
}

public func incomingDetailReveal(_ p: CGFloat) -> CGFloat { min(1, max(0, (p - 0.45) / 0.4)) }

public struct TimelineInfo: Sendable {
    public var x0: CGFloat
    public var colW: CGFloat
    public var tlTop: CGFloat
    public var tlBottom: CGFloat
    public var viewH: CGFloat
    public var hourH: CGFloat
    public var scroll: CGFloat
    public var maxScroll: CGFloat
    public var zoomable: Bool
    public var reveal: CGFloat
    public var wide: Bool
}

/// Single source of truth for the day-detail timeline geometry.
public func timelineInfo(_ g: SceneInput, detailMul: CGFloat = 1) -> TimelineInfo {
    let f = frameFor(g.focus, g)
    let tlTop = f.bandY + 4 * f.trackH + 18
    let tlBottom = g.vp.h - 8
    let m = hourMetrics(tlTop, tlBottom, g.z, g.tlScroll, g.weekHourH)
    let reveal = (g.z < 0.82 ? 0 : min(1, max(0, (g.z - 0.82) / 0.18))) * detailMul
    return TimelineInfo(x0: f.x0, colW: f.dayW, tlTop: tlTop, tlBottom: tlBottom, viewH: m.viewH,
                        hourH: m.hourH, scroll: m.scroll, maxScroll: m.maxScroll, zoomable: m.zoomable,
                        reveal: reveal, wide: f.dayW > 60)
}

/// An event's day expressed in `focus`'s numbering (≤0 / >dim for spillover); nil otherwise.
public func relDomOf(_ year: Int, _ focus: Int, _ month: Int, _ day: Int) -> Int? {
    if month == focus { return day }
    if month == focus - 1 { return day - daysInMonth(year, focus - 1) }
    if month == focus + 1 { return daysInMonth(year, focus) + day }
    return nil
}

// ── A minimal timed event for seed/display + its overlap layout ──────────────────

public let EVENT_COLORS = ["default", "blue", "indigo", "cyan", "green", "darkgreen", "yellow", "orange", "red", "purple"]

public struct TimedEvent: Sendable, Identifiable, Equatable, Codable {
    public var id: String
    public var month: Int
    public var day: Int
    public var startHour: CGFloat
    public var endHour: CGFloat
    public var title: String
    public var color: String
    public init(id: String, month: Int, day: Int, startHour: CGFloat, endHour: CGFloat, title: String, color: String) {
        self.id = id; self.month = month; self.day = day; self.startHour = startHour
        self.endHour = endHour; self.title = title; self.color = color
    }
}

public struct EventLayout: Sendable { public var col: Int; public var nCols: Int; public var level: Int; public var maxLevel: Int }

private let TITLE_H: CGFloat = 1
private let INDENT_PX: CGFloat = 9
private let MIN_W: CGFloat = 26

/// Side-by-side + cascade overlap packing within a day column. Ported from layoutDay().
public func layoutDay(_ events: [TimedEvent]) -> [String: EventLayout] {
    var out: [String: EventLayout] = [:]
    let sorted = events.sorted { a, b in a.startHour != b.startHour ? a.startHour < b.startHour : a.endHour > b.endHour }
    var level: [String: Int] = [:]
    struct PackCol { var events: [TimedEvent]; var maxTitleEnd: CGFloat }
    var cols: [PackCol] = []
    var clusterEnd: CGFloat = -.greatestFiniteMagnitude

    func flush() {
        if cols.isEmpty { return }
        let nCols = cols.count
        for (ci, c) in cols.enumerated() {
            var maxLevel = 0
            for e in c.events { maxLevel = max(maxLevel, level[e.id] ?? 0) }
            for e in c.events { out[e.id] = EventLayout(col: ci, nCols: nCols, level: level[e.id] ?? 0, maxLevel: maxLevel) }
        }
        cols = []
    }

    for ev in sorted {
        if ev.startHour >= clusterEnd { flush(); clusterEnd = -.greatestFiniteMagnitude }
        let titleEnd = min(ev.startHour + TITLE_H, ev.endHour)
        var idx = cols.firstIndex { $0.maxTitleEnd <= ev.startHour }
        if idx == nil { cols.append(PackCol(events: [], maxTitleEnd: -.greatestFiniteMagnitude)); idx = cols.count - 1 }
        var lvl = 0
        for p in cols[idx!].events where p.endHour > ev.startHour { lvl = max(lvl, (level[p.id] ?? 0) + 1) }
        level[ev.id] = lvl
        cols[idx!].events.append(ev)
        cols[idx!].maxTitleEnd = max(cols[idx!].maxTitleEnd, titleEnd)
        clusterEnd = max(clusterEnd, ev.endHour)
    }
    flush()
    return out
}

/// Placement of an event within the day-detail timeline. Ported from eventRect().
public func eventRect(_ ev: TimedEvent, _ year: Int, _ focus: Int, _ tl: TimelineInfo, _ vp: Viewport, _ layout: EventLayout? = nil) -> CGRect? {
    guard let dom = relDomOf(year, focus, ev.month, ev.day), tl.hourH > 0 else { return nil }
    let colX = tl.x0 + (CGFloat(dom) - 1) * tl.colW
    if colX + tl.colW < -40 || colX > vp.w + 40 { return nil }
    let col = layout?.col ?? 0
    let nCols = layout?.nCols ?? 1
    let level = layout?.level ?? 0
    let maxLevel = layout?.maxLevel ?? 0
    let subW = tl.colW / CGFloat(nCols)
    let indent = maxLevel > 0 ? min(INDENT_PX, max(0, (subW - MIN_W) / CGFloat(maxLevel))) : 0
    return CGRect(
        x: colX + CGFloat(col) * subW + CGFloat(level) * indent + 2,
        y: ev.startHour * tl.hourH + 1,
        width: max(3, subW - CGFloat(maxLevel) * indent - 4),
        height: max(3, (ev.endHour - ev.startHour) * tl.hourH - 2)
    )
}

/// Height-driven text scheme for an hourly event block (ported from eventTextLayout).
public struct EventText: Sendable { public var tiny: Bool; public var short: Bool; public var titleLines: Int }
public func eventTextLayout(_ h: CGFloat) -> EventText {
    let tiny = h < 26            // ~15 min
    let short = h < 40           // ~≤30 min: hide the time
    let lineH: CGFloat = tiny ? 11 : 14
    let avail = h - (tiny ? 2 : 10) - (short ? 0 : 13)
    return EventText(tiny: tiny, short: short, titleLines: max(1, Int(avail / lineH)))
}

/// "HH:MM – HH:MM" for an event's decimal-hour range (ported from fmtRange).
public func fmtHourRange(_ s: CGFloat, _ e: CGFloat) -> String {
    func hhmm(_ h: CGFloat) -> String { let t = Int((h * 60).rounded()); return String(format: "%02d:%02d", (t / 60) % 24, t % 60) }
    return "\(hhmm(s)) – \(hhmm(e))"
}

/// Pointer → focus-relative day column + fractional hour, accounting for scroll.
public func pointToSlot(_ px: CGFloat, _ py: CGFloat, _ tl: TimelineInfo) -> (dom: Int?, hourFrac: CGFloat) {
    let dom = (px >= Layout.labelW && tl.colW > 0) ? Int((px - tl.x0) / tl.colW) + 1 : nil
    let hourFrac = tl.hourH > 0 ? max(0, min(24, (py - tl.tlTop + tl.scroll) / tl.hourH)) : 0
    return (dom, hourFrac)
}
