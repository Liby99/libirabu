// Per-month geometry as a function of the zoom scalar `z`. Ported from geometry/frames.ts.
//   z = 0 → Year   (months stacked, 3/quarter, 4 quarters)
//   z = 1 → Month  (focused month's band on top, full width)
//   z = 2 → Week   (focused week's 7 days widened)
//   z = 3 → Day    (one day's column at the left + daily dashboard on the right)
// Year→Month is a vertical accordion (day width constant); Month→Week→Day are horizontal.
//
// The TS module-level daily/year/hour-height globals are read here from `SceneInput`.

import CoreGraphics

private func quarterBlock() -> CGFloat { Layout.qHeaderH + 3 * Layout.monthH }
public func yearContentH() -> CGFloat { 4 * quarterBlock() + 3 * Layout.qGap }
public func yearMaxScroll(_ vp: Viewport) -> CGFloat {
    max(0, yearContentH() - (vp.h - Layout.topPad - Layout.bottomPad))
}

/// GridCal-style year layout: 4 quarters separated by Q_GAP; months flush within a quarter.
public func yearFrame(_ m: Int, _ vp: Viewport, _ scrollY: CGFloat) -> Frame {
    let dayW = (vp.w - Layout.labelW) / 31
    let q = m / 3
    let within = m % 3
    let quarterTop = CGFloat(q) * (quarterBlock() + Layout.qGap)
    let bandY = Layout.topPad - scrollY + quarterTop + Layout.qHeaderH + CGFloat(within) * Layout.monthH
    return Frame(x0: Layout.labelW, dayW: dayW, bandY: bandY, trackH: Layout.trackH, opacity: 1)
}

/// Geometry of a month's band at Month level (also used for hit-testing).
public func focusGeom(_ vp: Viewport) -> (x0: CGFloat, dayW: CGFloat, bandY: CGFloat, trackH: CGFloat) {
    (Layout.labelW, (vp.w - Layout.labelW) / 31, Layout.topPad, Layout.trackH)
}

private func detailFullH(_ vp: Viewport) -> CGFloat { vp.h - Layout.topPad - Layout.monthH - 30 }

// Year→Month accordion: the focus lane scrolls to the top; detail space opens below it.
private func yearToMonthFrame(_ m: Int, _ t: CGFloat, _ focus: Int, _ vp: Viewport, _ scrollY: CGFloat) -> Frame {
    let yf = yearFrame(m, vp, scrollY)
    let yfocus = yearFrame(focus, vp, scrollY)
    let PAD: CGFloat = 80
    let scroll = (yfocus.bandY - Layout.topPad) * t
    var bandY = yf.bandY - scroll
    if m < focus { bandY -= PAD * t }
    else if m > focus { bandY += detailFullH(vp) * t + PAD * t }
    return Frame(x0: Layout.labelW, dayW: yf.dayW, bandY: bandY, trackH: Layout.trackH, opacity: 1)
}

private func weekFrame(_ m: Int, _ g: SceneInput) -> Frame {
    let dayW = (g.vp.w - Layout.labelW) / 7
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

// Vertical month-to-month paging. dir +1 = next month, -1 = prev; p ∈ [0,1].
private func monthSwipeFrame(_ m: Int, _ anim: PageAnim, _ focus: Int, _ vp: Viewport) -> Frame {
    let dir = anim.dir, p = anim.p
    let to = focus + dir
    let x0 = Layout.labelW, dayW = (vp.w - Layout.labelW) / 31
    let OFF_TOP = -Layout.monthH - 40
    let OFF_BOT = vp.h + 40
    if m == focus {
        let bandY = dir > 0
            ? lerp(Layout.topPad, OFF_TOP, easeInOut(clamp((p - 0.5) / 0.5, 0, 1)))
            : lerp(Layout.topPad, OFF_BOT, easeInOut(p))
        return Frame(x0: x0, dayW: dayW, bandY: bandY, trackH: Layout.trackH, opacity: 1)
    }
    if m == to {
        let bandY = dir > 0
            ? lerp(OFF_BOT, Layout.topPad, easeInOut(p))
            : lerp(OFF_TOP, Layout.topPad, easeInOut(clamp(p / 0.65, 0, 1)))
        return Frame(x0: x0, dayW: dayW, bandY: bandY, trackH: Layout.trackH, opacity: 1)
    }
    return Frame(x0: x0, dayW: dayW, bandY: OFF_BOT, trackH: Layout.trackH, opacity: 0)
}

/// Day-detail opacity for a focus-relative day-of-month at zoom z.
public func dailyFade(_ dom: Int, _ g: SceneInput) -> CGFloat {
    if let a = g.daily.anim {
        if dom == g.daily.dom { return 1 - a.p }
        if dom == g.daily.dom + a.dir { return a.p }
        return 0
    }
    if g.z <= 2 { return 1 }
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

/// Left edge of the daily dashboard panel (right of the chosen day's column).
public func dashboardLeft(_ g: SceneInput) -> CGFloat {
    let f = frameFor(g.focus, g)
    return max(Layout.labelW, f.x0 + CGFloat(g.daily.dom) * f.dayW)
}

/// Resolve month `m`'s frame at the current zoom. `anim` (month paging) overrides z when present.
public func frameFor(_ m: Int, _ g: SceneInput, anim: PageAnim? = nil) -> Frame {
    if let anim { return monthSwipeFrame(m, anim, g.focus, g.vp) }
    if g.z <= 1 { return yearToMonthFrame(m, easeInOut(clamp(g.z, 0, 1)), g.focus, g.vp, g.scrollY) }
    let wf = weekFrame(m, g)
    if g.z <= 2 {
        let mf = yearToMonthFrame(m, 1, g.focus, g.vp, g.scrollY)
        return blend(mf, wf, easeInOut(clamp(g.z - 1, 0, 1)))
    }
    return blend(wf, dayFrame(m, g), easeInOut(clamp(g.z - 2, 0, 1)))
}
