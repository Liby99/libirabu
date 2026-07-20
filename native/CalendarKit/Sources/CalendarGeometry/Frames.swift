// Per-month geometry as a function of the zoom scalar `z`. Ported from geometry/frames.ts.
//   z = 0 → Year   (months stacked, 3/quarter, 4 quarters)
//   z = 1 → Month  (focused month's band on top, full width)
//   z = 2 → Week   (focused week's 7 days widened)
//   z = 3 → Day    (one day's column at the left + daily dashboard on the right)
// Year→Month is a vertical accordion (day width constant); Month→Week→Day are horizontal.
//
// The TS module-level daily/year/hour-height globals are read here from `SceneInput`.

import CoreGraphics

private func quarterBlock() -> CGFloat {
    Layout.qHeaderH + 3 * Layout.monthH
}

public func yearContentH() -> CGFloat {
    4 * quarterBlock() + 3 * Layout.qGap
}

public func yearMaxScroll(_ vp: Viewport) -> CGFloat {
    max(0, yearContentH() - (vp.h - Layout.yearTop - Layout.bottomPad))
}

/// Year-view day-cell width: fills the window, but never below `Layout.yearMinDayW`
/// (phone: 26 → each quarter overflows into its own horizontal scroll).
public func yearDayW(_ vp: Viewport) -> CGFloat {
    max((vp.w - Layout.labelW) / 31, Layout.yearMinDayW)
}

/// How far a quarter's 31-day strip can scroll horizontally (0 when the cells fit).
public func yearQuarterMaxX(_ vp: Viewport) -> CGFloat {
    max(0, 31 * yearDayW(vp) - (vp.w - Layout.labelW))
}

/// GridCal-style year layout: 4 quarters separated by Q_GAP; months flush within a quarter.
/// `qx` is the month's QUARTER horizontal scroll offset (phone overflow; 0 on desktop) —
/// the grid shifts left by it while the gutter (month name) stays, so names stick.
public func yearFrame(_ m: Int, _ vp: Viewport, _ scrollY: CGFloat, qx: CGFloat = 0) -> Frame {
    let q = m / 3
    let within = m % 3
    let quarterTop = CGFloat(q) * (quarterBlock() + Layout.qGap)
    // Year view uses its own small top inset (yearTop); the accordion below still lands
    // the focused month band at topPad when zooming in.
    let bandY = Layout.yearTop - scrollY + quarterTop + Layout.qHeaderH + CGFloat(within) * Layout.monthH
    return Frame(x0: Layout.labelW - qx, dayW: yearDayW(vp), bandY: bandY, trackH: Layout.trackH, opacity: 1)
}

/// Geometry of a month's band at Month level (also used for hit-testing). `mx` is the
/// month-view horizontal scroll offset (phone overflow; 0 on desktop) — pass g.monthQX.
public func focusGeom(_ vp: Viewport, mx: CGFloat = 0, pin: CGFloat = 0,
                      monthFrac: CGFloat = 0.25) -> (x0: CGFloat, dayW: CGFloat, bandY: CGFloat, trackH: CGFloat) {
    (Layout.labelW - mx, monthDayW(vp, pin: pin, frac: monthFrac), Layout.topPad, Layout.trackH)
}

/// Month-view day-cell width: the full-window width (== yearDayW) normally; squeezed left of the
/// pinned dashboard (at its MONTH width, floored at dashMonthMinW) when it's out. The phone's
/// min-width clamp applies.
public func monthDayW(_ vp: Viewport, pin: CGFloat, frac: CGFloat) -> CGFloat {
    let right = lerp(vp.w, vp.w - dashMonthPanelW(vp, frac: frac), pin)
    return max((right - Layout.labelW) / 31, Layout.yearMinDayW)
}

private func detailFullH(_ vp: Viewport) -> CGFloat {
    vp.h - Layout.topPad - Layout.monthH - 30
}

/// Year→Month accordion: the focus lane scrolls to the top; detail space opens below it.
/// The QUARTER scroll offset (qx) blends into the MONTH scroll offset (mx) as t→1 — the
/// engine seeds mx from the tapped month's qx, so the columns don't jump during the zoom.
/// Both are 0 on desktop; dayW keeps the min-width overflow at every t (yearDayW).
private func yearToMonthFrame(_ m: Int, _ t: CGFloat, _ focus: Int, _ vp: Viewport, _ scrollY: CGFloat,
                              qx: CGFloat = 0, mx: CGFloat = 0, pin: CGFloat = 0, monthFrac: CGFloat = 0.25) -> Frame {
    let yf = yearFrame(m, vp, scrollY, qx: qx)
    let yfocus = yearFrame(focus, vp, scrollY)
    let PAD: CGFloat = 80
    let scroll = (yfocus.bandY - Layout.topPad) * t
    var bandY = yf.bandY - scroll
    if m < focus {
        bandY -= PAD * t
    } else if m > focus {
        bandY += detailFullH(vp) * t + PAD * t
    }
    // Pinned dashboard: the year's full-width columns compress to the squeezed month width as the
    // accordion opens (year view itself never squeezes — the panel is retracted at z 0).
    return Frame(x0: lerp(yf.x0, Layout.labelW - mx, t),
                 dayW: lerp(yf.dayW, monthDayW(vp, pin: pin, frac: monthFrac), t),
                 bandY: bandY, trackH: Layout.trackH, opacity: 1)
}

private func weekFrame(_ m: Int, _ g: SceneInput) -> Frame {
    // Pinned dashboard: the whole 7-day window squeezes left of the panel (evaluated at the
    // panel's resting WEEK width — the month↔week frame blend morphs from the month width, and
    // the week→day blend handles the widening past z 2).
    let right = lerp(g.vp.w, dashPinLeft(g.vp, frac: g.dashWeekFrac), g.dashPin)
    let dayW = (right - Layout.labelW) / 7
    if m == g.focus {
        // fractional `week` slides the 7-day window per-day, exactly as the TS: the
        // (possibly fractional) Sunday DOM lands day-1 at LABEL_W.
        let startDOM = 1 - CGFloat(firstDOW(g.year, g.focus)) + g.week * 7
        let x0 = Layout.labelW - (startDOM - 1) * dayW
        return Frame(x0: x0, dayW: dayW, bandY: Layout.topPad, trackH: Layout.trackH, opacity: 1)
    }
    let dir = m < g.focus ? -1 : 1
    let off = dir < 0 ? -Layout.monthH - 80 : g.vp.h + 80
    return Frame(x0: Layout.labelW, dayW: dayW, bandY: off, trackH: Layout.trackH, opacity: 0)
}

/// Vertical month-to-month paging. dir +1 = next month, -1 = prev; p ∈ [0,1].
/// Keeps the min-width day columns AND the month's horizontal scroll offset (mx) through
/// the turn — otherwise the phone's overflowing month compresses to fit-width mid-swipe
/// and re-expands on settle. Both are inert on desktop (natural width, mx = 0).
private func monthSwipeFrame(_ m: Int, _ anim: PageAnim, _ focus: Int, _ vp: Viewport,
                             mx: CGFloat = 0, pin: CGFloat = 0, monthFrac: CGFloat = 0.25) -> Frame {
    let dir = anim.dir, p = anim.p
    let to = focus + dir
    let x0 = Layout.labelW - mx, dayW = monthDayW(vp, pin: pin, frac: monthFrac)
    let OFF_TOP = -Layout.monthH - 40
    let OFF_BOT = vp.h + 40
    // Compact (phone): the page turn is a FINGER-TRACKED drag, so both months follow `p`
    // linearly — direct manipulation, no dead zone. The desktop keeps its staggered
    // ease-in-out curves (its pager is momentum-driven: p sweeps quickly after a flick,
    // where the stagger reads as a page turn; under a slow finger it reads as lag).
    let track = Layout.isCompactGutter
    if m == focus {
        let bandY = track
            ? lerp(Layout.topPad, dir > 0 ? OFF_TOP : OFF_BOT, p)
            : (dir > 0
                ? lerp(Layout.topPad, OFF_TOP, easeInOut(clamp((p - 0.5) / 0.5, 0, 1)))
                : lerp(Layout.topPad, OFF_BOT, easeInOut(p)))
        return Frame(x0: x0, dayW: dayW, bandY: bandY, trackH: Layout.trackH, opacity: 1)
    }
    if m == to {
        let bandY = track
            ? lerp(dir > 0 ? OFF_BOT : OFF_TOP, Layout.topPad, p)
            : (dir > 0
                ? lerp(OFF_BOT, Layout.topPad, easeInOut(p))
                : lerp(OFF_TOP, Layout.topPad, easeInOut(clamp(p / 0.65, 0, 1))))
        return Frame(x0: x0, dayW: dayW, bandY: bandY, trackH: Layout.trackH, opacity: 1)
    }
    return Frame(x0: x0, dayW: dayW, bandY: OFF_BOT, trackH: Layout.trackH, opacity: 0)
}

/// Dim multiplier for an event/deadline whose calendar month is `month`, in week view. Normally a
/// neighbor-month (spillover) day is dimmed to `dim`. During a month-edge flip `focus` is ALREADY the
/// destination month (labels swap the instant you release), so the destination brightens IN and the
/// origin (the month you left) dims OUT as `weekFlipFade` runs 0→1 — the events cross-fade AFTER the
/// text has changed. At f=0 this matches the pre-release dim exactly, so nothing jumps on release.
public func spillFactor(_ month: Int, _ g: SceneInput, dim: CGFloat = 0.45) -> CGFloat {
    if g.weekFlipDir != 0 {
        let f = g.weekFlipFade
        let origin = (g.focus - g.weekFlipDir + 12) % 12 // month left behind (year-wrap safe)
        if month == g.focus {
            return lerp(dim, 1, f)
        } // destination brightens in
        if month == origin {
            return lerp(1, dim, f)
        } // origin dims out
        return dim
    }
    return month == g.focus ? 1 : dim
}

/// Day-detail opacity for a focus-relative day-of-month at zoom z.
public func dailyFade(_ dom: Int, _ g: SceneInput) -> CGFloat {
    // Week/month view shows EVERY day at full opacity — check this FIRST so a leftover day-paging
    // `anim` (e.g. zoomed out mid-day-scroll, before the pager settled) can't blank out all the other
    // days (and their grid/labels) here. The day-paging carousel only applies within day view (z>2).
    if g.z <= 2 {
        return 1
    }
    if let a = g.daily.anim {
        if dom == g.daily.dom {
            return 1 - a.p
        }
        if dom == g.daily.dom + a.dir {
            return a.p
        }
        return 0
    }
    return dom == g.daily.dom ? 1 : 1 - clamp(g.z - 2, 0, 1)
}

// Week→Day: the chosen day's column widens to daily.frac of the content area and pans to LABEL_W.
private func dayFrame(_ m: Int, _ g: SceneInput) -> Frame {
    let dayW = g.daily.frac * (g.vp.w - Layout.labelW)
    let pan = (g.daily.anim != nil ? -CGFloat(g.daily.anim!.dir) * g.daily.anim!.p * dayW : 0) + g.daily.over
    if m == g.focus {
        let x0 = Layout.labelW - (CGFloat(g.daily.dom) - 1) * dayW + pan
        return Frame(x0: x0, dayW: dayW, bandY: Layout.topPad, trackH: Layout.trackH, opacity: 1)
    }
    let off = m < g.focus ? -Layout.monthH - 80 : g.vp.h + 80
    return Frame(x0: Layout.labelW, dayW: dayW, bandY: off, trackH: Layout.trackH, opacity: 0)
}

private func blend(_ a: Frame, _ b: Frame, _ t: CGFloat) -> Frame {
    Frame(x0: lerp(a.x0, b.x0, t), dayW: lerp(a.dayW, b.dayW, t), bandY: lerp(a.bandY, b.bandY, t),
          trackH: lerp(a.trackH, b.trackH, t), opacity: lerp(a.opacity, b.opacity, t))
}

/// Left edge of the daily dashboard panel = the right edge of the (one-day-wide) timeline window.
/// Computed directly from the daily split (identical to the day frame's `daily.frac·content` day
/// width) rather than through frameFor — the week/day frames themselves consume the ANIMATED left
/// edge below, and going through frames here would recurse.
public func dashboardLeft(_ g: SceneInput) -> CGFloat {
    Layout.labelW + g.daily.frac * (g.vp.w - Layout.labelW)
}

/// A pinned panel's resting left edge for a given width fraction of the content area.
@inlinable public func dashPinLeft(_ vp: Viewport, frac: CGFloat) -> CGFloat {
    vp.w - frac * (vp.w - Layout.labelW)
}

/// The pinned MONTHLY panel's width in px: the persisted fraction, floored at dashMonthMinW.
@inlinable public func dashMonthPanelW(_ vp: Viewport, frac: CGFloat) -> CGFloat {
    max(Layout.dashMonthMinW, frac * (vp.w - Layout.labelW))
}

/// The PINNED panel's left edge for this z — defined as the GRID'S RIGHT EDGE, so the gap between
/// the canvas's right border and the panel is 0 by construction:
///   • z ≤ 1 (year→month accordion): labelW + 31·dayW(z) — the same eased column width the
///     accordion animates (yearToMonthFrame), so the panel starts EXACTLY outside the right
///     border (31 year columns fill the window) and enters at the grid's own contraction rate.
///   • z 1→2: month grid-right → week grid-right (the frames blend on the same eased ramp).
/// nil when the pin is (effectively) 0.
func pinnedDashLeft(_ g: SceneInput) -> CGFloat? {
    guard g.dashPin > 0.0001 else { return nil }
    let monthRight = Layout.labelW + 31 * monthDayW(g.vp, pin: g.dashPin, frac: g.dashMonthFrac)
    if g.z <= 1 {
        let yearRight = Layout.labelW + 31 * yearDayW(g.vp)
        return lerp(yearRight, monthRight, easeInOut(clamp(g.z, 0, 1)))
    }
    let weekRight = lerp(g.vp.w, dashPinLeft(g.vp, frac: g.dashWeekFrac), g.dashPin)
    return lerp(monthRight, weekRight, easeInOut(clamp(g.z - 1, 0, 1)))
}

/// The panel's TOTAL reveal this frame, 0…1 of "some panel is out" (chrome + webview alpha key on
/// this): the day-forced reveal (z 2→3), or — pinned — the panel's on-screen PRESENCE (how much of
/// its resting width has entered), so content fades in exactly as the panel edge enters the window
/// rather than on a separate timetable.
public func dashRevealTotal(_ g: SceneInput) -> CGFloat {
    let day = easeInOut(clamp(g.z - 2, 0, 1))
    guard let left = pinnedDashLeft(g) else { return day }
    let restingW = g.vp.w - (Layout.labelW + 31 * monthDayW(g.vp, pin: g.dashPin, frac: g.dashMonthFrac))
    let presence = clamp((g.vp.w - left) / max(1, restingW), 0, 1)
    return max(day, presence)
}

/// The dashboard's left edge, ANIMATED — every panel-region clip (content, bands, deadlines,
/// chrome) uses this so they reveal together. Three regimes, composed:
///   • unpinned: flush right until day opens; eases to the daily split across z 2→3 (classic).
///   • pinned: GLUED to the grid's right edge (see pinnedDashLeft) — enters with the accordion,
///     morphs month→week width with the frame blend, then WIDENS into the daily split as the
///     day opens.
public func dashboardLeftAnimated(_ g: SceneInput) -> CGFloat {
    var left = g.vp.w
    if let pinned = pinnedDashLeft(g) {
        left = pinned
    }
    let dayReveal = easeInOut(clamp(g.z - 2, 0, 1))
    if dayReveal > 0.0001 {
        left = lerp(left, dashboardLeft(g), dayReveal)
    }
    return left
}

/// Resolve month `m`'s frame at the current zoom. `anim` (month paging) overrides z when present.
public func frameFor(_ m: Int, _ g: SceneInput, anim: PageAnim? = nil) -> Frame {
    var f: Frame
    if let anim {
        f = monthSwipeFrame(m, anim, g.focus, g.vp, mx: g.monthQX, pin: g.dashPin, monthFrac: g.dashMonthFrac)
    } else if g.z <= 1 {
        f = yearToMonthFrame(m, easeInOut(clamp(g.z, 0, 1)), g.focus, g.vp, g.scrollY,
                             qx: g.qx(m), mx: g.monthQX, pin: g.dashPin, monthFrac: g.dashMonthFrac)
    } else if g.z <= 2 {
        let mf = yearToMonthFrame(m, 1, g.focus, g.vp, g.scrollY, mx: g.monthQX, pin: g.dashPin, monthFrac: g.dashMonthFrac)
        f = blend(mf, weekFrame(m, g), easeInOut(clamp(g.z - 1, 0, 1)))
    } else {
        f = blend(weekFrame(m, g), dayFrame(m, g), easeInOut(clamp(g.z - 2, 0, 1)))
    }
    if g.monthFlipShift != 0 {
        f.bandY += g.monthFlipShift
    } // month boundary-flip: shift the view
    return f
}
