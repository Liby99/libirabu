// Builds the flat list of positioned items to render for a given zoom state.
// All geometry comes from Frames.swift; this file decides WHICH items exist and how
// they're styled at each zoom level. Ported from geometry/scene.ts.

import CoreGraphics
import Foundation

private let HL_SOFT: CGFloat = 0.05   // L1 coarse highlight
private let HL_STRONG: CGFloat = 0.11 // L2 fine highlight

struct Clock { var year: Int; var month: Int; var day: Int; var hour: Int; var minute: Int }
private func clockOf(_ date: Date) -> Clock {
    let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    return Clock(year: c.year ?? 0, month: (c.month ?? 1) - 1, day: c.day ?? 1, hour: c.hour ?? 0, minute: c.minute ?? 0)
}

private func onScreen(_ f: Frame, _ vp: Viewport) -> Bool {
    f.bandY <= vp.h + 20 && f.bandY + 4 * f.trackH >= -20
}

public func buildScene(_ g: SceneInput) -> Scene {
    let clock = clockOf(g.now)
    var items: [Item] = []
    if g.monthAnim == nil {
        items += buildHover(g)
        items += buildToday(g, clock)
    }
    items += buildQuarterHeaders(g, clock)
    items += buildMonthBands(g)
    items += buildDetail(g, clock, focus: g.focus)
    if let anim = g.monthAnim {
        items += buildToday(g, clock, mul: g.detailMul)
        let to = g.focus + anim.dir
        if to >= 0 && to <= 11 {
            items += buildDetail(g, clock, focus: to, detailMul: incomingDetailReveal(anim.p), keyTag: "~in")
            items += buildToday(g, clock, mul: incomingDetailReveal(anim.p), keyTag: "~in")
        }
    }
    return Scene(items: items)
}

// ── Today markers + live current-time line ───────────────────────────────────────
private func buildToday(_ g: SceneInput, _ clock: Clock, mul: CGFloat = 1, keyTag: String = "") -> [Item] {
    var items: [Item] = []
    let present = clock.year == g.year
    let tMonth = clock.month, tDom = clock.day
    let nowFrac = CGFloat(clock.hour) + CGFloat(clock.minute) / 60
    let timeStr = String(format: "%02d:%02d", clock.hour, clock.minute)

    let relDom: Int? = tMonth == g.focus ? tDom
        : (tMonth == g.focus - 1 ? tDom - daysInMonth(g.year, g.focus - 1)
        : (tMonth == g.focus + 1 ? daysInMonth(g.year, g.focus) + tDom : nil))

    func nowLabel(_ key: String, _ x: CGFloat, _ colW: CGFloat, _ lineY: CGFloat, _ active: Bool, gate: CGFloat = 1) -> Item {
        let W: CGFloat = 84, GAP: CGFloat = 10, H: CGFloat = 30
        let onLeft = g.z > 2 || x + colW / 2 >= (Layout.labelW + g.vp.w) / 2
        return Item(key: key, kind: .nowLabel, x: onLeft ? x - GAP - W : x + colW + GAP, y: lineY - H / 2, w: W, h: H,
                    opacity: active ? mul * gate : 0, text: timeStr,
                    align: onLeft ? .right : .left, instant: g.z > 2, z: g.z > 2 ? 16 : 9)
    }

    // Year: today's day column in its month band
    do {
        let f = frameFor(tMonth, g)
        let on = present && g.z < 0.5 && onScreen(f, g.vp)
        let tx = f.x0 + (CGFloat(tDom) - 1) * f.dayW
        items.append(Item(key: "td-y", kind: .today, x: tx, y: f.bandY, w: f.dayW, h: 4 * f.trackH, opacity: on ? mul : 0, z: 3))
        let tagW: CGFloat = 54
        items.append(Item(key: "td-tag", kind: .todayTag, x: tx + f.dayW / 2 - tagW / 2, y: f.bandY + 4 * f.trackH + 3, w: tagW, h: 11, opacity: on ? mul : 0, text: "TODAY", fontSize: 8, align: .center, z: 9))
    }
    // Month: today's column (band + timeline) + now line
    do {
        let active = present && g.z >= 0.5 && g.z < 1.5 && g.focus == tMonth
        let f = frameFor(g.focus, g)
        let colW = f.dayW
        let tlTop = f.bandY + 4 * f.trackH + 18
        let tlBottom = g.vp.h - 8
        let detail = g.z >= 0.82
        let x = f.x0 + (CGFloat(tDom) - 1) * colW
        items.append(Item(key: "td-m", kind: .today, x: x, y: f.bandY, w: colW, h: (detail ? tlBottom : f.bandY + 4 * f.trackH) - f.bandY, opacity: active ? mul : 0, z: 3))
        let m = hourMetrics(tlTop, tlBottom, g.z, g.tlScroll, g.weekHourH)
        let lineY = tlTop + nowFrac * m.hourH - m.scroll
        let lineOn = active && detail && m.hourH > 0 && lineY >= tlTop && lineY <= tlBottom
        items.append(Item(key: "now-m", kind: .now, x: x, y: lineY, w: colW, h: 2, opacity: lineOn ? mul : 0, z: 6))
        items.append(nowLabel("nl-m", x, colW, lineY, lineOn))
    }
    // Week: today's column when in the visible 7-day window
    do {
        let startDom = weekStartDOM(g.year, g.focus, Int(g.week.rounded(.down)))
        let inWeek = relDom != nil && relDom! >= startDom && relDom! < startDom + 7
        let active = present && g.z >= 1.5 && inWeek
        let f = frameFor(g.focus, g)
        let colW = f.dayW
        let tlTop = f.bandY + 4 * f.trackH + 18
        let tlBottom = g.vp.h - 8
        let x = f.x0 + (CGFloat(relDom ?? 1) - 1) * colW
        let tintMul = 1 - clamp((g.z - 2) / 0.6, 0, 1)
        items.append(Item(key: "td-w", kind: .today, x: x, y: f.bandY, w: colW, h: tlBottom - f.bandY, opacity: active ? mul * tintMul : 0, z: 3))
        let m = hourMetrics(tlTop, tlBottom, g.z, g.tlScroll, g.weekHourH)
        let lineY = tlTop + nowFrac * m.hourH - m.scroll
        let lineOn = active && m.hourH > 0 && lineY >= tlTop && lineY <= tlBottom
        let dgate = dailyFade(relDom ?? -999, g)
        items.append(Item(key: "now-w", kind: .now, x: x, y: lineY, w: colW, h: 2, opacity: (lineOn ? mul : 0) * dgate, instant: g.z > 2, z: g.z > 2 ? 16 : 6))
        items.append(nowLabel("nl-w", x, colW, lineY, lineOn, gate: dgate))
    }

    if !keyTag.isEmpty { items = items.map { var it = $0; it.key += keyTag; return it } }
    return items
}

// ── Hierarchical hover highlight ─────────────────────────────────────────────────
private func buildHover(_ g: SceneInput) -> [Item] {
    var items: [Item] = []
    let h = g.hover

    // Year: hovered month band (soft) + day column (strong) + name strip
    do {
        let m = h.month ?? g.focus
        let f = frameFor(m, g)
        let dim = daysInMonth(g.year, m)
        let bandH = 4 * f.trackH
        let monthOn = g.z < 0.5 && h.month != nil && onScreen(f, g.vp)
        items.append(Item(key: "hl-ym", kind: .hl, x: f.x0, y: f.bandY, w: CGFloat(dim) * f.dayW, h: bandH, opacity: monthOn ? HL_SOFT : 0, z: 3))
        // Extend the gutter hover left over the padding so the row highlight reaches
        // the window's left border (like a native list-row selection).
        items.append(Item(key: "hl-yg", kind: .hl, x: -Layout.padLeft, y: f.bandY, w: Layout.labelW + Layout.padLeft, h: bandH, opacity: monthOn ? HL_SOFT : 0, z: 6, gutter: true))
        let dcol = h.dom ?? 1
        let dayOn = monthOn && h.dom != nil && h.dom! >= 1 && h.dom! <= dim
        items.append(Item(key: "hl-yd", kind: .hl, x: f.x0 + (CGFloat(dcol) - 1) * f.dayW, y: f.bandY, w: f.dayW, h: bandH, opacity: dayOn ? HL_STRONG : 0, z: 3))
        // NOTE: the "Thu"/"Fri" weekday marker above the hovered day is rendered as a
        // Liquid Glass capsule in EventsOverlay (Canvas can't draw glass) — see
        // weekdayMarker(). Its visibility mirrors `dayOn` here.
    }
    // Month: hovered week span (soft) + day column (strong)
    do {
        let active = g.z >= 0.5 && g.z < 1.5
        let f = frameFor(g.focus, g)
        let dim = daysInMonth(g.year, g.focus)
        let colW = f.dayW
        let top = f.bandY
        let bottom = g.z >= 0.82 ? g.vp.h - 8 : f.bandY + 4 * f.trackH
        var wx = f.x0, ww: CGFloat = 0
        if let hw = h.week {
            let ws = weekStartDOM(g.year, g.focus, hw)
            let startCol = max(0, ws - 1)
            let endCol = min(dim, ws - 1 + 7)
            wx = f.x0 + CGFloat(startCol) * colW
            ww = max(0, CGFloat(endCol - startCol) * colW)
        }
        items.append(Item(key: "hl-mw", kind: .hl, x: wx, y: top, w: ww, h: bottom - top, opacity: active && ww > 0 ? HL_SOFT : 0, z: 3))
        let dcol = h.dom ?? 1
        let dayOn = active && h.dom != nil && h.dom! >= 1 && h.dom! <= dim
        items.append(Item(key: "hl-md", kind: .hl, x: f.x0 + (CGFloat(dcol) - 1) * colW, y: top, w: colW, h: bottom - top, opacity: dayOn ? HL_STRONG : 0, z: 3))
    }
    // Week: hovered day column (soft) + hour cell (strong) + cursor line/tag
    do {
        let active = g.z >= 1.5
        let f = frameFor(g.focus, g)
        let colW = f.dayW
        let tlTop = f.bandY + 4 * f.trackH + 18
        let tlBottom = g.vp.h - 8
        let m = hourMetrics(tlTop, tlBottom, g.z, g.tlScroll, g.weekHourH)
        let dcol = h.dom ?? 1
        let x = f.x0 + (CGFloat(dcol) - 1) * colW
        items.append(Item(key: "hl-wd", kind: .hl, x: x, y: f.bandY, w: colW, h: tlBottom - f.bandY, opacity: active && h.dom != nil ? HL_SOFT * (1 - clamp(g.z - 2, 0, 1)) : 0, z: 3))
        let rawHy = h.hour != nil ? tlTop + CGFloat(h.hour!) * m.hourH - m.scroll : tlTop
        let cellTop = max(tlTop, rawHy), cellBot = min(tlBottom, rawHy + m.hourH)
        let hourOn = active && h.dom != nil && h.hour != nil && m.hourH > 0 && cellBot > cellTop
        items.append(Item(key: "hl-wh", kind: .hl, x: x, y: cellTop, w: colW, h: max(0, cellBot - cellTop), opacity: hourOn ? HL_STRONG : 0, z: 3))

        let hf = h.hourFrac ?? 0
        let cy = tlTop + hf * m.hourH - m.scroll
        let curOn = active && h.dom != nil && h.hourFrac != nil && m.hourH > 0 && cy >= tlTop && cy <= tlBottom
        items.append(Item(key: "cur-line", kind: .cursor, x: x, y: cy, w: colW, h: 2, opacity: curOn ? 1 : 0, z: g.z > 2 ? 16 : 7))
        let total = Int((hf * 60).rounded())
        let tStr = String(format: "%02d:%02d", (total / 60) % 24, total % 60)
        let tagLeft = g.z > 2 || x + colW / 2 >= (Layout.labelW + g.vp.w) / 2
        let TW: CGFloat = 44, GAP: CGFloat = 10, TH: CGFloat = 20
        items.append(Item(key: "cur-tag", kind: .timeTag, x: tagLeft ? x - GAP - TW : x + colW + GAP, y: cy - TH / 2, w: TW, h: TH, opacity: curOn ? 1 : 0, text: tStr, align: tagLeft ? .right : .left, z: g.z > 2 ? 16 : 9))
    }
    return items
}

// ── Quarter day-number headers (year view only) ──────────────────────────────────
private func buildQuarterHeaders(_ g: SceneInput, _ clock: Clock) -> [Item] {
    let yearVis = clamp(1 - g.z / 0.4, 0, 1)
    if yearVis <= 0.02 { return [] }
    var items: [Item] = []
    let dayW = (g.vp.w - Layout.labelW) / 31
    for q in 0..<4 {
        let hy = frameFor(q * 3, g).bandY - Layout.qHeaderH
        if hy < -Layout.qHeaderH || hy > g.vp.h { continue }
        let todayQuarter = g.year == clock.year && q == clock.month / 3
        for d in 1...31 {
            let isToday = todayQuarter && d == clock.day
            items.append(Item(key: "qh-\(q)-\(d)", kind: .dayLabel, x: Layout.labelW + CGFloat(d - 1) * dayW, y: hy + 5, w: dayW, h: 14, opacity: yearVis * 0.7, text: String(d), fontSize: 10, align: .center, today: isToday, z: 4))
        }
        let topY = hy + Layout.qHeaderH - 1
        // Quarter top border — emphasized (full opacity + 1.5× width) vs the internal
        // month dividers (0.6 opacity, 1× width).
        items.append(Item(key: "qhsepg-\(q)", kind: .gridline, x: 0, y: topY, w: Layout.labelW - Layout.rightPad, h: 1, opacity: yearVis, z: 11, gutter: true, lineW: 1.5))
        items.append(Item(key: "qhsepd-\(q)", kind: .gridline, x: Layout.labelW, y: topY, w: 31 * dayW, h: 1, opacity: yearVis, z: 11, lineW: 1.5))
    }
    return items
}

// ── The 12 month bands: name, 4 lanes, end-of-month dim, divider ─────────────────
private func buildMonthBands(_ g: SceneInput) -> [Item] {
    var items: [Item] = []
    let dimFade = 1 - clamp(g.z - 1, 0, 1)
    let detailReveal = clamp((g.z - 0.82) / 0.18, 0, 1)
    for m in 0..<12 {
        let f = frameFor(m, g, anim: g.monthAnim)
        if f.opacity < 0.02 || !onScreen(f, g.vp) { continue }
        let dim = daysInMonth(g.year, m)
        let fullW = 31 * f.dayW

        items.append(Item(key: "ml-\(m)", kind: .monthLabel, x: 0, y: f.bandY, w: Layout.mnameW, h: f.trackH * 4, opacity: f.opacity, text: MONTH_NAMES[m], fontSize: 13, align: .center, z: 8, gutter: true))

        let isFocusBand = m == g.focus || (g.monthAnim != nil && m == g.focus + g.monthAnim!.dir)
        if detailReveal > 0.02 && isFocusBand {
            let top = f.opacity * detailReveal * 0.6
            items.append(Item(key: "ftopg-\(m)", kind: .gridline, x: 0, y: f.bandY - 1, w: Layout.labelW - Layout.rightPad, h: 1, opacity: top, z: 11, gutter: true))
            items.append(Item(key: "ftopd-\(m)", kind: .gridline, x: Layout.labelW, y: f.bandY - 1, w: g.vp.w - Layout.labelW, h: 1, opacity: top, z: 11))
        }

        for t in 0..<4 {
            items.append(Item(key: "row-\(m)-\(t)", kind: .row, x: f.x0, y: f.bandY + CGFloat(t) * f.trackH, w: fullW, h: f.trackH, opacity: f.opacity, color: TRACKS[t].color, cols: g.z > 2.5 ? 1 : 31, inner: t > 0, z: 1))
        }
        if dim < 31 && dimFade > 0.02 {
            items.append(Item(key: "dim-\(m)", kind: .dim, x: f.x0 + CGFloat(dim) * f.dayW, y: f.bandY, w: CGFloat(31 - dim) * f.dayW, h: 4 * f.trackH, opacity: f.opacity * dimFade, z: 3))
        }
        // The bottom month of each quarter (m%3==2) gets the emphasized outer border.
        let quarterBottom = m % 3 == 2
        items.append(Item(key: "msep-\(m)", kind: .gridline, x: f.x0, y: f.bandY + 4 * f.trackH - 1, w: fullW, h: 1, opacity: f.opacity * (quarterBottom ? 1.0 : 0.55), z: 1, lineW: quarterBottom ? 1.5 : 1))
    }
    return items
}

// ── Focused month's headers + timeline + week boundaries + spillover ─────────────
private func buildDetail(_ g: SceneInput, _ clock: Clock, focus: Int, detailMul: CGFloat = 1, keyTag: String = "") -> [Item] {
    let reveal = (g.z < 0.82 ? 0 : clamp((g.z - 0.82) / 0.18, 0, 1)) * detailMul
    if reveal <= 0.02 { return [] }
    var items: [Item] = []

    // build with `focus` (may be the incoming month during a page-turn)
    var gf = g; gf.focus = focus
    let f = frameFor(focus, gf)
    let dim = daysInMonth(g.year, focus)
    let colW = f.dayW
    let bandBottom = f.bandY + 4 * f.trackH
    let wide = colW > 60
    let dailyOut = 1 - clamp(g.z - 2, 0, 1)
    let weekZoom = clamp(g.z - 1, 0, 1)

    let tlTop = bandBottom + 18
    let tlBottom = g.vp.h - 8
    let hasTL = tlBottom > tlTop
    let hm = hasTL ? hourMetrics(tlTop, tlBottom, g.z, g.tlScroll, g.weekHourH) : HourMetrics(viewH: 0, hourH: 0, maxScroll: 0, zoomable: false, scroll: 0)
    let hourH = hm.hourH, scroll = hm.scroll

    let altOn = g.altDeltaHours != nil
    if hasTL {
        var hr = 0
        let step = wide ? 1 : 6
        while hr <= 24 {
            let y = tlTop + CGFloat(hr) * hourH - scroll
            if y < tlTop - 0.5 || y > tlBottom + 0.5 { hr += step; continue }
            let even = hr % 2 == 0
            items.append(Item(key: "hl-\(hr)", kind: .gridline, x: Layout.labelW, y: y, w: g.vp.w - Layout.labelW, h: 1, opacity: reveal * (even ? 0.22 : 0.12), lineStyle: even ? .dashed : .dotted, z: 0))
            if hr % (wide ? 2 : 6) == 0 {
                items.append(Item(key: "ht-\(hr)", kind: .dayLabel, x: Layout.labelW - 46, y: y - 7, w: 42, h: 14, opacity: reveal * 0.7, text: String(format: "%02d:00", hr), fontSize: 9, align: .center, z: 9, gutter: true))
                if altOn {
                    let t = (((Int(((CGFloat(hr) + g.altDeltaHours!) * 60).rounded()) % 1440) + 1440) % 1440)
                    let txt = String(format: "%02d:%02d", t / 60, t % 60)
                    items.append(Item(key: "hta-\(hr)", kind: .dayLabel, x: Layout.labelW - 92, y: y - 7, w: 42, h: 14, opacity: reveal * 0.7, text: txt, fontSize: 9, align: .center, z: 9, gutter: true))
                }
            }
            hr += step
        }
        if altOn {
            items.append(Item(key: "tzaxis", kind: .gridline, x: Layout.labelW - 50, y: tlTop, w: 1, h: tlBottom - tlTop, opacity: reveal * 0.35, z: 9, gutter: true))
            if let al = g.altLabel { items.append(Item(key: "tzhdr", kind: .dayLabel, x: Layout.labelW - 92, y: tlTop - 16, w: 42, h: 12, opacity: reveal * 0.85, text: al, fontSize: 9, align: .center, z: 9, gutter: true)) }
        }
    }

    func pushDay(_ dom: Int, _ opIn: CGFloat) {
        let op = opIn * dailyFade(dom, gf)
        if op <= 0.002 { return }
        guard let r = resolveDate(g.year, focus, dom) else { return }
        let x = f.x0 + (CGFloat(dom) - 1) * colW
        if x + colW < -40 || x > g.vp.w + 40 { return }
        let dow = dayOfWeek(g.year, r.month, r.day)
        if (dow == 0 || dow == 6) && op * dailyOut > 0.002 {
            let bottom = hasTL ? tlBottom : bandBottom
            items.append(Item(key: "wke-\(dom)", kind: .weekend, x: x, y: f.bandY, w: colW, h: bottom - f.bandY, opacity: op * dailyOut, z: 2))
        }
        let nwOp = op * clamp(g.z - 2, 0, 1)
        if hasTL && nwOp > 0.002 {
            for (h0, h1) in [(0, 6), (18, 24)] {
                let y0 = max(tlTop, tlTop + CGFloat(h0) * hourH - scroll)
                let y1 = min(tlBottom, tlTop + CGFloat(h1) * hourH - scroll)
                if y1 > y0 + 0.5 { items.append(Item(key: "nwh-\(dom)-\(h0)", kind: .weekend, x: x, y: y0, w: colW, h: y1 - y0, opacity: nwOp, z: 2)) }
            }
        }
        let dateText = r.month == focus ? String(r.day) : "\(MONTH_NAMES[r.month]) \(r.day)"
        let isToday = g.year == clock.year && r.month == clock.month && r.day == clock.day
        items.append(Item(key: "date-\(dom)", kind: .dayLabel, x: x, y: f.bandY - 20, w: colW, h: 16, opacity: op, text: dateText, fontSize: wide ? 13 : 10, align: .center, today: isToday, z: 4))
        items.append(Item(key: "wd-\(dom)", kind: .dayLabel, x: x, y: bandBottom + 2, w: colW, h: 14, opacity: op * 0.9, text: wide ? WD3[dow] : WD[dow], fontSize: wide ? 11 : 9, align: .center, today: isToday, z: 4))
        if !hasTL { return }
        let isWeekStart = ((((firstDOW(g.year, focus) + dom - 1) % 7) + 7) % 7) == 0
        if !isWeekStart {
            items.append(Item(key: "tdv-\(dom)", kind: .gridline, x: x, y: tlTop, w: 1, h: tlBottom - tlTop, opacity: op * 0.4 * dailyOut, lineStyle: .dotted, z: 0))
        }
    }

    for d in 1...dim { pushDay(d, reveal) }

    let bottom = hasTL ? tlBottom : bandBottom
    for w in 0...weeksInMonth(g.year, focus) {
        let x = f.x0 + (CGFloat(weekStartDOM(g.year, focus, w)) - 1) * colW
        if x < Layout.labelW - 2 || x > g.vp.w + 2 { continue }
        items.append(Item(key: "wkb-\(w)", kind: .gridline, x: x - 1, y: f.bandY, w: 1, h: bottom - f.bandY, opacity: reveal * 0.4 * dailyOut, lineStyle: .dashed, z: 1))
    }

    if weekZoom > 0.01 {
        let lead = weekStartDOM(g.year, focus, 0)
        let tail = weekStartDOM(g.year, focus, weeksInMonth(g.year, focus) - 1) + 6
        if lead <= 0 { for dom in lead...0 { pushDay(dom, weekZoom * 0.5) } }
        if tail >= dim + 1 { for dom in (dim + 1)...tail { pushDay(dom, weekZoom * 0.5) } }
        for bx in [1, dim + 1] {
            let x = f.x0 + CGFloat(bx - 1) * colW
            if x < Layout.labelW || x > g.vp.w + 2 { continue }
            items.append(Item(key: "mb-\(bx)-b", kind: .gridline, x: x - 0.5, y: f.bandY, w: 1, h: bandBottom - f.bandY, opacity: weekZoom * 0.7 * dailyOut, z: 5))
            if hasTL { items.append(Item(key: "mb-\(bx)-t", kind: .gridline, x: x - 0.5, y: tlTop, w: 1, h: tlBottom - tlTop, opacity: weekZoom * 0.7 * dailyOut, z: 5)) }
        }
    }

    if !keyTag.isEmpty { items = items.map { var it = $0; it.key += keyTag; return it } }
    return items
}
