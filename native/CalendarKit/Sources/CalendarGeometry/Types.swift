// Shared value types for the calendar layout. Ported from geometry/types.ts.
// Everything here is a pure value type — Sendable, no reference semantics.

import CoreGraphics
import Foundation

public struct Viewport: Sendable, Equatable {
    public var w: CGFloat
    public var h: CGFloat
    public init(w: CGFloat, h: CGFloat) { self.w = w; self.h = h }
}

/// A month's geometry at the current zoom: where day 1 sits, day width, band top,
/// track-row height, and overall opacity.
public struct Frame: Sendable, Equatable {
    public var x0: CGFloat       // pixel of day-1's left edge
    public var dayW: CGFloat     // per-day column width
    public var bandY: CGFloat    // top of the 4-lane band
    public var trackH: CGFloat   // lane height
    public var opacity: CGFloat
    public init(x0: CGFloat, dayW: CGFloat, bandY: CGFloat, trackH: CGFloat, opacity: CGFloat) {
        self.x0 = x0; self.dayW = dayW; self.bandY = bandY; self.trackH = trackH; self.opacity = opacity
    }
}

/// Cursor-driven hover targets, resolved per zoom bucket.
public struct Hover: Sendable, Equatable {
    public var month: Int?
    public var dom: Int?
    public var week: Int?
    public var hour: Int?
    public var hourFrac: CGFloat?
    public var nameMonth: Int?
    public var nearLeft: Bool?
    public init(month: Int? = nil, dom: Int? = nil, week: Int? = nil, hour: Int? = nil,
                hourFrac: CGFloat? = nil, nameMonth: Int? = nil, nearLeft: Bool? = nil) {
        self.month = month; self.dom = dom; self.week = week; self.hour = hour
        self.hourFrac = hourFrac; self.nameMonth = nameMonth; self.nearLeft = nearLeft
    }
    public static let none = Hover()
}

public enum ItemKind: Sendable {
    case row, event, monthLabel, dayLabel, gridline, dim, hl, today, now
    case todayTag, nowLabel, timeTag, cursor, weekdayTag, weekend
}

public enum TextAlign: Sendable { case left, center, right }
public enum LineStyle: Sendable { case dashed, dotted }

/// One positioned visual primitive produced by buildScene(). Mirrors types.ts Item;
/// x/y/w/h are kept separate (as in the TS) so the port stays literal.
public struct Item: Sendable {
    public var key: String
    public var kind: ItemKind
    public var x: CGFloat
    public var y: CGFloat
    public var w: CGFloat
    public var h: CGFloat
    public var opacity: CGFloat
    public var z: Int = 0
    public var color: String? = nil      // palette key (red/blue/…) — rows & events
    public var text: String? = nil
    public var fontSize: CGFloat? = nil
    public var align: TextAlign = .center
    public var cols: Int? = nil          // row: number of day cells for the dotted verticals
    public var lineStyle: LineStyle? = nil
    public var inner: Bool = false       // row: inner lane (t>0) → dotted top separator
    public var instant: Bool = false     // now/label: drop the opacity transition
    public var today: Bool = false       // dayLabel: red capsule + white text
    public var gutter: Bool = false      // lives in the left gutter [0, LABEL_W]:
                                         // month name, hour labels, gutter borders, gutter hover

    public var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }

    // NOTE: `z` is declared LAST-ish (Swift call-site args must follow declared order),
    // so every call lists styling before z: color, text, fontSize, align, cols,
    // lineStyle, inner, instant, today, then z, then gutter.
    public init(key: String, kind: ItemKind, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                opacity: CGFloat, color: String? = nil, text: String? = nil,
                fontSize: CGFloat? = nil, align: TextAlign = .center, cols: Int? = nil,
                lineStyle: LineStyle? = nil, inner: Bool = false, instant: Bool = false,
                today: Bool = false, z: Int = 0, gutter: Bool = false) {
        self.key = key; self.kind = kind; self.x = x; self.y = y; self.w = w; self.h = h
        self.opacity = opacity; self.z = z; self.color = color; self.text = text; self.gutter = gutter
        self.fontSize = fontSize; self.align = align; self.cols = cols; self.lineStyle = lineStyle
        self.inner = inner; self.instant = instant; self.today = today
    }
}

public struct Scene: Sendable {
    public var items: [Item]
    public init(items: [Item]) { self.items = items }
}

// ── Page-turn + daily state (was module-level globals in frames.ts) ──────────────

public struct PageAnim: Sendable, Equatable {
    public var dir: Int        // +1 next, -1 prev
    public var p: CGFloat      // 0…1 progress
    public init(dir: Int, p: CGFloat) { self.dir = dir; self.p = p }
}

public struct DailyState: Sendable, Equatable {
    public var dom: Int        // chosen day (focus-relative day-of-month)
    public var frac: CGFloat   // timeline width as a fraction of the content area
    public var anim: PageAnim? // day↔day paging
    public var over: CGFloat   // month-boundary overscroll (px)
    public init(dom: Int = 1, frac: CGFloat = 0.45, anim: PageAnim? = nil, over: CGFloat = 0) {
        self.dom = dom; self.frac = frac; self.anim = anim; self.over = over
    }
}

/// Everything a frame/scene needs, by value. Replaces the TS module-level singletons
/// (setDaily / syncWeekHourH / setCalendarYear) — so all geometry is a pure function
/// of its arguments and safe under strict concurrency.
public struct SceneInput: Sendable {
    public var z: CGFloat
    public var focus: Int
    public var week: CGFloat
    public var vp: Viewport
    public var scrollY: CGFloat
    public var tlScroll: CGFloat
    public var now: Date
    public var year: Int
    public var hover: Hover
    public var weekHourH: CGFloat
    public var daily: DailyState
    public var monthAnim: PageAnim?
    public var detailMul: CGFloat
    public var altDeltaHours: CGFloat?
    public var altLabel: String?
    public var dimPast: Bool

    public init(z: CGFloat, focus: Int, week: CGFloat, vp: Viewport, scrollY: CGFloat,
                tlScroll: CGFloat, now: Date, year: Int, hover: Hover = .none,
                weekHourH: CGFloat = 60, daily: DailyState = DailyState(), monthAnim: PageAnim? = nil,
                detailMul: CGFloat = 1, altDeltaHours: CGFloat? = nil, altLabel: String? = nil,
                dimPast: Bool = false) {
        self.z = z; self.focus = focus; self.week = week; self.vp = vp; self.scrollY = scrollY
        self.tlScroll = tlScroll; self.now = now; self.year = year; self.hover = hover
        self.weekHourH = weekHourH; self.daily = daily; self.monthAnim = monthAnim
        self.detailMul = detailMul; self.altDeltaHours = altDeltaHours; self.altLabel = altLabel
        self.dimPast = dimPast
    }
}
