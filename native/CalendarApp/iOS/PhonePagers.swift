// Touch paging/scroll drivers for the iPhone calendar — the native-touch twins of the Mac's
// invisible NSScrollView-backed pagers (MonthPager/WeekPager/DayPager in CalendarUI). Same
// architecture: a real (but invisible) SwiftUI ScrollView supplies the physics, we observe the
// content offset and project it onto the engine's state; the engine pins the scroll position
// back through its onSet… closures during flips/zooms. Unlike the Mac there is no AppKit
// catcher forwarding events — these ScrollViews ARE the touch surface (mounted behind the
// non-hit-testing render layers), so iOS's own touch physics and rubber-banding drive the
// engine's overscroll-pull flips directly.
//
// Snap behaviors (MonthPagingBehavior / WeekScrollBehavior / DayScrollBehavior) come from
// CalendarRender, shared verbatim with the Mac so both platforms page with the same feel.

import CalendarEngine
import CalendarGeometry
import CalendarRender
import SwiftUI

/// Mounts the right driver for the current zoom level.
///
/// PHONE V1.2: year + month. Year = vertical scroll with per-quarter horizontal strips;
/// month = vertical month↕month pager nested with the focused month's horizontal day strip.
/// Navigation between the two levels is the two-finger pinch (PhoneCalendarView.pinch →
/// engine.onMagnify, clamped to maxZ = 1; the breadcrumb's Year crumb also zooms out).
/// The week/day drivers below are finished and waiting; extend the switch to re-enable them.
struct PhoneDriverLayer: View {
    let engine: CalendarEngine
    let vp: Viewport

    var body: some View {
        // chrome.level is @Observable and set to the TARGET at tween start, so the driver
        // swaps the moment a zoom begins.
        switch engine.chrome.level {
        case 0: PhoneYearDriver(engine: engine, vp: vp)
        case 1: PhoneMonthDriver(engine: engine, vp: vp)
        default: PhoneWeekDriver(engine: engine, vp: vp)
        // case 3: PhoneDayDriver(engine: engine, vp: vp)
        }
    }
}

/// Year view: vertical scroll over the 12-month column (overscroll at the top/bottom edge
/// arms the year flip), with each QUARTER hosting its own nested horizontal ScrollView —
/// on the phone the min-width day cells (Layout.yearMinDayW) overflow the screen, and the
/// quarter strips scroll independently (engine.setYearQuarterScroll → SceneInput.yearQX).
/// UIKit's nested-scroll arbitration axis-locks vertical vs horizontal drags natively.
private struct PhoneYearDriver: View {
    let engine: CalendarEngine
    let vp: Viewport
    @State private var pos = ScrollPosition()
    /// iOS auto-extends a ScrollView that touches the status-bar edge and compensates with a
    /// top CONTENT INSET (~59pt under a Dynamic Island). All engine mirroring + strip layout
    /// below works in INSET-ADJUSTED space (0 = scrolled to top), or the whole render would
    /// draw ~59pt below the touch strips (phantom top gap + off-by-a-quarter swipes).
    @State private var topInset: CGFloat = 0
    /// Restore target on (re)mount. Until the ScrollView reaches it (or the user grabs the
    /// view), geometry callbacks are NOT mirrored into the engine — a fresh ScrollView fires
    /// an initial offset-0 callback BEFORE the restore pin lands, which would overwrite the
    /// engine's remembered scroll (year view "jumping back to January" after a month trip).
    @State private var pendingRestore: CGFloat?

    var body: some View {
        let quarterH = Layout.qHeaderH + 3 * Layout.monthH
        let gridW = max(1, vp.w - Layout.labelW)
        let maxScroll = max(0, yearMaxScroll(vp))
        ScrollView(.vertical) {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: vp.h + maxScroll)
                ForEach(0 ..< 4, id: \.self) { q in
                    // Content y is in RAW content space, which displays topInset lower than
                    // the canvas's geometry space — subtract it so strip q sits exactly over
                    // the rendered quarter q at every scroll position.
                    quarterStrip(q, quarterH: quarterH, gridW: gridW)
                        .offset(x: Layout.padLeft + Layout.labelW,
                                y: Layout.yearTop + CGFloat(q) * (quarterH + Layout.qGap) - topInset)
                }
            }
        }
        .scrollPosition($pos)
        // A freshly-mounted ScrollView starts at the engine's remembered scroll (July stays
        // centered after a month round-trip). This is INITIAL-LAYOUT state — an imperative
        // scrollTo in onAppear races the attachment and can silently drop, leaving the view
        // at offset 0 (January) while the engine says July.
        .defaultScrollAnchor(UnitPoint(x: 0, y: maxScroll > 0 ? min(max(engine.scrollY / maxScroll, 0), 1) : 0))
        .scrollBounceBehavior(.always)
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentInsets.top }) { _, v in
            topInset = v
        }
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { _, y in
            if let target = pendingRestore {
                if abs(y - target) < 1 {
                    pendingRestore = nil // restore landed → mirror live
                } else {
                    return // ignore pre-restore callbacks (the initial 0)
                }
            }
            engine.setYearScroll(y)
        }
        // NOTE: no begin/endYearScrollGesture here — those arm the overscroll year FLIP,
        // which is disabled on the phone for now (edge pulls just rubber-band back).
        .onScrollPhaseChange { _, new in
            if new == .interacting || new == .tracking {
                pendingRestore = nil // the user grabbed it — whatever they do now is truth
            }
        }
        .onAppear {
            let p = $pos
            pendingRestore = engine.scrollY
            p.wrappedValue.scrollTo(y: engine.scrollY)
            engine.onSetYearScroll = { y in p.wrappedValue.scrollTo(y: y) }
        }
    }

    /// One quarter's horizontal driver: an invisible 31-day-wide strip (header + 3 month
    /// bands tall). Its content offset mirrors into the engine, which shifts that quarter's
    /// grid while the month names (gutter) stay put.
    private func quarterStrip(_ q: Int, quarterH: CGFloat, gridW: CGFloat) -> some View {
        QuarterStrip(engine: engine, q: q, contentW: 31 * yearDayW(vp), viewportW: gridW)
            .frame(width: gridW, height: quarterH)
    }
}

/// A quarter strip's ScrollView with its own position state, so re-entering year view
/// (or remounting after a month round-trip) restores the engine's stored offset instead
/// of snapping the strip back to day 1 while the render stays put.
private struct QuarterStrip: View {
    let engine: CalendarEngine
    let q: Int
    let contentW: CGFloat
    let viewportW: CGFloat
    @State private var pos = ScrollPosition()
    @State private var pendingRestore: CGFloat? // see PhoneYearDriver — same remount race

    var body: some View {
        let maxX = max(0, contentW - viewportW)
        ScrollView(.horizontal) {
            Color.clear.frame(width: contentW).frame(maxHeight: .infinity)
        }
        .scrollPosition($pos)
        // Initial-layout restore of the engine's stored offset (see PhoneYearDriver).
        .defaultScrollAnchor(UnitPoint(
            x: maxX > 0 ? min(max((engine.yearQX.indices.contains(q) ? engine.yearQX[q] : 0) / maxX, 0), 1) : 0,
            y: 0
        ))
        .scrollBounceBehavior(.always)
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x + $0.contentInsets.leading }) { _, x in
            if let target = pendingRestore {
                if abs(x - target) < 1 {
                    pendingRestore = nil
                } else {
                    return
                }
            }
            engine.setYearQuarterScroll(q, x)
        }
        .onScrollPhaseChange { _, new in
            if new == .interacting || new == .tracking {
                pendingRestore = nil
            }
        }
        .onAppear {
            let x = engine.yearQX.indices.contains(q) ? engine.yearQX[q] : 0
            pendingRestore = x
            pos.scrollTo(x: x)
        }
    }
}

/// Month view: an outer VERTICAL pager (12 pages, one per month — swipe up/down to turn,
/// the Mac's MonthPagingBehavior supplies the feel) nested with an inner HORIZONTAL strip
/// over the focused month's 31 min-width day columns. UIKit's nested-scroll arbitration
/// axis-locks the two: vertical pans page months, horizontal pans scroll days.
private struct PhoneMonthDriver: View {
    let engine: CalendarEngine
    let vp: Viewport
    @State private var pos = ScrollPosition()
    @State private var topInset: CGFloat = 0 // see PhoneYearDriver — same adjusted-space contract
    @State private var pendingRestore: CGFloat? // see PhoneYearDriver — same remount race

    var body: some View {
        let pageH = vp.h
        let gridW = max(1, vp.w - Layout.labelW)
        ScrollView(.vertical) {
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(0 ..< 12, id: \.self) { m in
                        Color.clear.frame(maxWidth: .infinity).frame(height: pageH).id(m)
                    }
                }
                .scrollTargetLayout()
                // The day strip rides the FOCUSED page (chrome.focus is @Observable, so a
                // completed page turn re-seats it). Content space is raw — subtract the
                // auto content inset like the year driver's quarter strips.
                MonthHStrip(engine: engine, vp: vp)
                    .frame(width: gridW, height: pageH)
                    .offset(x: Layout.padLeft + Layout.labelW,
                            y: CGFloat(engine.chrome.focus) * pageH - topInset)
            }
        }
        .scrollPosition($pos)
        // Initial-layout landing on the focused month's page (see PhoneYearDriver): content
        // is 12 pages, scrollable range 11 — fraction focus/11 puts page `focus` at the top.
        .defaultScrollAnchor(UnitPoint(x: 0, y: CGFloat(engine.focus) / 11))
        .scrollTargetBehavior(MonthPagingBehavior()) // one gesture = at most one month
        .scrollBounceBehavior(.always)
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentInsets.top }) { _, v in
            topInset = v
        }
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { _, y in
            if let target = pendingRestore {
                if abs(y - target) < 1 {
                    pendingRestore = nil
                } else {
                    return
                }
            }
            engine.setMonthProgress(y, pageH: pageH)
        }
        .onScrollPhaseChange { old, new in
            if new == .interacting || new == .tracking {
                pendingRestore = nil
                engine.beginMonthGesture()
            } else if old == .interacting || old == .tracking {
                engine.endMonthGesture()
            }
        }
        .onAppear {
            let p = $pos
            let target = CGFloat(engine.focus) * pageH
            pendingRestore = target
            p.wrappedValue.scrollTo(y: target)
            engine.onSetMonthPage = { m in p.wrappedValue.scrollTo(y: CGFloat(m) * pageH) }
        }
        // A boundary flip changed year+focus without leaving month view — land on the new focus.
        .onChange(of: engine.chrome.monthResync) { _, _ in
            pos.scrollTo(y: CGFloat(engine.focus) * pageH)
        }
    }
}

/// The focused month's horizontal day-column driver (nested inside PhoneMonthDriver's
/// vertical pager). Mirrors into engine.setMonthHScroll, which shifts the whole month
/// scene (band lanes, day headers, timeline columns, events) while the gutter stays.
private struct MonthHStrip: View {
    let engine: CalendarEngine
    let vp: Viewport
    @State private var pos = ScrollPosition()
    @State private var pendingRestore: CGFloat? // see PhoneYearDriver — same remount race

    var body: some View {
        let contentW = 31 * yearDayW(vp)
        let maxX = max(0, contentW - max(1, vp.w - Layout.labelW))
        ScrollView(.horizontal) {
            Color.clear
                .frame(width: contentW)
                .frame(maxHeight: .infinity)
        }
        .scrollPosition($pos)
        // Initial-layout restore of the seeded quarter-offset carry-over (see PhoneYearDriver).
        .defaultScrollAnchor(UnitPoint(x: maxX > 0 ? min(max(engine.monthQX / maxX, 0), 1) : 0, y: 0))
        .scrollBounceBehavior(.always)
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x + $0.contentInsets.leading }) { _, x in
            if let target = pendingRestore {
                if abs(x - target) < 1 {
                    pendingRestore = nil
                } else {
                    return
                }
            }
            engine.setMonthHScroll(x)
        }
        .onScrollPhaseChange { _, new in
            if new == .interacting || new == .tracking {
                pendingRestore = nil
            }
        }
        .onAppear {
            // The engine seeded monthQX from the tapped month's quarter offset (navigate) —
            // land the driver there so the first touch doesn't jump the columns.
            pendingRestore = engine.monthQX
            pos.scrollTo(x: engine.monthQX)
        }
    }
}

/// Week view: one two-axis ScrollView — x is the day window (day-aligned nudges, week-boundary
/// flings, month-edge pulls; Layout.weekDaysVisible cells wide — 3 on the phone), y is the hour
/// timeline. UIKit's own pan physics arbitrate the axes.
private struct PhoneWeekDriver: View {
    let engine: CalendarEngine
    let vp: Viewport
    @State private var pos = ScrollPosition()
    /// See PhoneYearDriver — the same remount race, and it BITES HARDER here: this driver
    /// mounts MID-ZOOM (the level flips at z 1.5, while the month↔week blend is on screen), so
    /// an unguarded initial offset-(0,0) callback stomped `week` to 0 — the render lurched to
    /// the month's LEFT-MOST window (leading spillover) and then fought the restore pin,
    /// flickering — and the stomped `week` poisoned the next zoom-out's centering carry too.
    @State private var pendingRestore: CGPoint?

    var body: some View {
        let gridW = max(1, vp.w - Layout.labelW)
        let dayW = gridW / Layout.weekDaysVisible
        let weeks = max(1, weeksInMonth(engine.chrome.year, engine.chrome.focus))
        let maxDay = max(0, CGFloat(weeks * 7) - Layout.weekDaysVisible)
        let maxX = max(0, CGFloat(weeks * 7) * dayW - gridW)
        let maxY = max(0, engine.timelineMaxScroll)
        ScrollView([.horizontal, .vertical]) {
            Color.clear
                .frame(width: CGFloat(weeks * 7) * dayW,
                       height: vp.h + maxY)
                .scrollTargetLayout()
        }
        .scrollPosition($pos)
        // Initial-layout restore of the seeded window position (see PhoneYearDriver: the
        // imperative scrollTo alone races the attachment and can silently drop).
        .defaultScrollAnchor(UnitPoint(
            x: maxX > 0 ? min(max(engine.week * 7 * dayW / maxX, 0), 1) : 0,
            y: maxY > 0 ? min(max(engine.tlScroll / maxY, 0), 1) : 0
        ))
        .scrollTargetBehavior(WeekScrollBehavior(dayW: dayW, maxDay: maxDay,
                                                 liveDay: { MainActor.assumeIsolated { engine.week * 7 } }))
        .scrollBounceBehavior(.always)
        .scrollIndicators(.hidden)
        .frame(width: gridW, height: vp.h)
        .offset(x: Layout.padLeft + Layout.labelW)
        .onScrollGeometryChange(for: CGPoint.self, of: { CGPoint(x: $0.contentOffset.x, y: $0.contentOffset.y) }) { _, o in
            if let t = pendingRestore {
                if abs(o.x - t.x) < 1, abs(o.y - t.y) < 1 {
                    pendingRestore = nil // restore landed → mirror live
                } else {
                    return // ignore pre-restore callbacks (the initial 0,0)
                }
            }
            engine.setWeekProgress(o.x, dayW: dayW)
            engine.setTlScroll(o.y)
        }
        .onScrollPhaseChange { old, new in
            if new == .interacting || new == .tracking {
                pendingRestore = nil // the user grabbed it — whatever they do now is truth
                engine.beginWeekGesture()
            } else if old == .interacting || old == .tracking {
                engine.endWeekGesture()
            }
        }
        .onAppear {
            let p = $pos
            let target = CGPoint(x: engine.week * 7 * dayW, y: engine.tlScroll)
            pendingRestore = target
            p.wrappedValue.scrollTo(x: target.x, y: target.y)
            engine.onSetWeekScroll = { x in p.wrappedValue.scrollTo(x: x) }
            engine.onSetTlScroll = { y in p.wrappedValue.scrollTo(y: y) }
        }
        // A month-edge flip re-anchored focus/week — re-sync the strip to the new resting week.
        .onChange(of: engine.chrome.weekResync) { _, _ in
            pos.scrollTo(x: engine.week * 7 * dayW)
        }
    }
}

/// Day view: x pages day↔day (one page = the day column), y scrolls the hour timeline.
private struct PhoneDayDriver: View {
    let engine: CalendarEngine
    let vp: Viewport
    @State private var pos = ScrollPosition()

    var body: some View {
        let gridW = max(1, vp.w - Layout.labelW)
        let dayW = max(1, engine.daily.frac * gridW)
        let days = max(1, daysInMonth(engine.chrome.year, engine.chrome.focus))
        ScrollView([.horizontal, .vertical]) {
            Color.clear
                .frame(width: CGFloat(days) * dayW,
                       height: vp.h + max(0, engine.timelineMaxScroll))
                .scrollTargetLayout()
        }
        .scrollPosition($pos)
        .scrollTargetBehavior(DayScrollBehavior(dayW: dayW, maxDay: CGFloat(days - 1)))
        .scrollBounceBehavior(.always)
        .scrollIndicators(.hidden)
        // The strip must be able to park every day at the window's left edge — pad the tail by
        // the viewport-vs-page difference so offsets reach (days−1)·dayW (the Mac driver's
        // viewport IS one page wide, ours is the whole grid).
        .contentMargins(.trailing, max(0, gridW - dayW), for: .scrollContent)
        .frame(width: gridW, height: vp.h)
        .offset(x: Layout.padLeft + Layout.labelW)
        .onScrollGeometryChange(for: CGPoint.self, of: { CGPoint(x: $0.contentOffset.x, y: $0.contentOffset.y) }) { _, o in
            engine.setDayProgress(o.x)
            engine.setTlScroll(o.y)
        }
        .onScrollPhaseChange { old, new in
            if new == .interacting || new == .tracking {
                engine.beginDayGesture()
            } else if old == .interacting || old == .tracking {
                engine.endDayGesture()
            }
        }
        .onAppear {
            let p = $pos
            p.wrappedValue.scrollTo(x: CGFloat(engine.daily.dom - 1) * dayW, y: engine.tlScroll)
            engine.onSetTlScroll = { y in p.wrappedValue.scrollTo(y: y) }
        }
        // Jump-to-today / zoom-in landing / split change — re-sync the strip.
        .onChange(of: engine.chrome.dailyResync) { _, _ in
            pos.scrollTo(x: CGFloat(engine.daily.dom - 1) * dayW)
        }
    }
}
