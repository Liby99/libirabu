// Layout constants + math helpers. Single source of truth for the calendar's fixed
// pixel dimensions. Ported from geometry/constants.ts.

import CoreGraphics

public enum Layout {
    public static let topPad: CGFloat = 56     // month/detail: date row (bandY-20) + breathing room
    public static let yearTop: CGFloat = 18    // year view: small top inset (no date row up there)
    public static let yearFlipOver: CGFloat = 38  // on-screen overscroll (px) that arms a year flip
    public static let barH: CGFloat = 32       // top nav bar height
    public static let bottomPad: CGFloat = 28  // breathing room below year content
    public static let labelW: CGFloat = 250    // left gutter width
    public static let mnameW: CGFloat = 28     // rotated month-name zone within the gutter
    public static let rightPad: CGFloat = 24   // gap between gutter editor and day grid
    public static let trackH: CGFloat = 40     // fixed lane height (room for 13pt labels)
    public static let monthH: CGFloat = trackH * 4  // a month band = 4 lanes
    public static let qHeaderH: CGFloat = 24   // day-number header row per quarter
    public static let qGap: CGFloat = 32       // separation between quarters
    public static let pastDim: CGFloat = 0.4   // "dim past events" opacity multiplier

    // Global insets for the whole calendar. The geometry works in a viewport shrunk
    // by padLeft+padRight; the render is translated right by padLeft (so x=0 in
    // geometry space lands padLeft px from the window's left edge).
    public static let padLeft: CGFloat = 20
    public static let padRight: CGFloat = 0
}

@inlinable public func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
@inlinable public func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), hi) }
@inlinable public func easeInOut(_ t: CGFloat) -> CGFloat {
    t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
}
@inlinable public func easeOut(_ t: CGFloat) -> CGFloat { 1 - pow(1 - t, 3) }
