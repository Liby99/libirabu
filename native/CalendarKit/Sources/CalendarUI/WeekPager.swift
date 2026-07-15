// Week window horizontal scrolling, driven by a real (but invisible) SwiftUI ScrollView —
// the horizontal twin of MonthPager. A strip of 1-day cells; a small scroll snaps the 7-day
// window to the nearest DAY, a large (fast) scroll snaps to a WEEK boundary. SwiftUI supplies
// the native deceleration; we observe contentOffset.x and project it onto the engine's `week`.
//
// Month-scoped: the strip is just this month's weeks, so the window can't leave the month yet
// (crossing the edge = a flip, TODO). The AppKit catcher forwards horizontal week-view scroll
// into this ScrollView's backing NSScrollView via `bridge`, axis-locking against the vertical
// hour-timeline scroll.

import SwiftUI
import AppKit
import CalendarEngine
import CalendarGeometry

/// Snap policy: a gentle scroll nudges by a few days (day-aligned); only a deliberate hard fling
/// snaps to a week boundary — and always to the boundary in the DIRECTION of the fling, never the
/// "nearest" one (which could sit behind you and yank you backward).
///
/// Two knobs tune the feel:
///   • weekVelocity — the small/large threshold. High so week-snapping only happens on a real fling;
///     lower it if you want week jumps to trigger more easily.
///   • maxDayStep   — the farthest a *small* scroll may travel from where the gesture began (SwiftUI's
///     momentum otherwise projects a light flick many days out; this caps it).
struct WeekScrollBehavior: ScrollTargetBehavior {
    var dayW: CGFloat
    var maxDay: CGFloat                 // last valid left-edge day index (= maxWeek·7)
    var liveDay: () -> CGFloat          // the CURRENT content position in day-units (from the engine)
    var weekVelocity: CGFloat = 1100    // |velocity| above this → a week jump (deliberate only)
    var maxDayStep: CGFloat = 3         // a small scroll moves at most this many days per gesture

    func updateTarget(_ target: inout ScrollTarget, context: ScrollTargetBehaviorContext) {
        guard dayW > 0 else { return }
        // Anchor on where the content ACTUALLY IS right now — not `context.originalTarget`, which
        // reports the settled rest the gesture STARTED from (day 0 of a fling), so catching mid-flight
        // would cap `maxDayStep` from day 0 and always land ~mid-week regardless of the catch point.
        let cur = liveDay()
        let proposedDay = target.rect.origin.x / dayW                // SwiftUI's momentum projection
        let v = context.velocity.dx
        let landed: CGFloat
        // A catch near the end of a fling has decelerated (low velocity) → the day path settles near
        // where you grabbed it. Only a genuinely fast gesture jumps to a week boundary.
        if abs(v) > weekVelocity {
            let weekStart = (cur / 7).rounded(.down) * 7             // Sunday of the current week
            landed = v > 0 ? weekStart + 7
                           : ((cur - weekStart < 0.5) ? weekStart - 7 : weekStart)
        } else {
            let step = min(maxDayStep, max(-maxDayStep, proposedDay - cur))
            landed = (cur + step).rounded()                          // nearest day near the live position
        }
        target.rect.origin.x = min(max(0, landed), maxDay) * dayW
    }
}

/// Shared handle between the SwiftUI week driver and the AppKit `CatcherView`. Positioning is
/// IMPERATIVE (scroll the backing NSScrollView), NOT via `.scrollPosition` — a two-way scroll
/// position binding re-renders the pager on every day boundary crossed, re-applying itself
/// mid-scroll and jumping the offset. This way nothing in the pager re-renders while scrolling.
@MainActor final class WeekPagerBridge {
    weak var scrollView: NSScrollView? { didSet { if let p = pending { pending = nil; scrollTo(p) } } }
    private var pending: CGFloat?
    func scrollTo(_ x: CGFloat) {
        guard let sv = scrollView else { pending = x; return }   // not captured yet → apply on capture
        sv.contentView.scroll(to: NSPoint(x: max(0, x), y: 0))
        sv.reflectScrolledClipView(sv.contentView)
    }
}

struct WeekPager: View {
    let engine: CalendarEngine
    let bridge: WeekPagerBridge

    var body: some View {
        GeometryReader { geo in
            // The 7-day grid width (matches the engine's dayW = (vp.w − labelW)/7).
            let gridW = geo.size.width - Layout.padLeft - Layout.padRight - Layout.labelW
            let dayW = max(1, gridW / 7)
            // Reactive to the month via @Observable chrome, so the cell count follows weeksInMonth.
            let weeks = max(1, weeksInMonth(engine.chrome.year, engine.chrome.focus))
            let maxDay = CGFloat((weeks - 1) * 7)
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(0..<(weeks * 7), id: \.self) { d in
                        Color.clear.frame(width: dayW, height: 1).id(d)
                    }
                }
                .scrollTargetLayout()
                .background(WeekScrollGrabber(bridge: bridge))
            }
            .frame(width: gridW, height: 8)                 // viewport = one 7-day window
            // liveDay reads the engine's CURRENT week (updated every frame by onScrollGeometryChange)
            // — the true position even mid-animation. Read on the main actor (updateTarget runs there).
            .scrollTargetBehavior(WeekScrollBehavior(dayW: dayW, maxDay: maxDay,
                                                     liveDay: { MainActor.assumeIsolated { engine.week * 7 } }))
            .scrollBounceBehavior(.always)
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in
                engine.setWeekProgress(x, dayW: dayW)
            }
            .onAppear { bridge.scrollTo(engine.week * 7 * dayW) }
            // Entering week view (from month/day): position the strip on the current week.
            .onChange(of: engine.chrome.level) { _, lvl in
                if lvl == 2 { bridge.scrollTo(engine.week * 7 * dayW) }
            }
            // A month-edge flip re-anchored focus/week to the neighbor month → re-sync the strip
            // (the cell count also changed with weeksInMonth) to the new resting week.
            .onChange(of: engine.chrome.weekResync) { _, _ in
                bridge.scrollTo(engine.week * 7 * dayW)
            }
        }
    }
}

/// Zero-size probe that hands the SwiftUI ScrollView's backing NSScrollView to the bridge.
private struct WeekScrollGrabber: NSViewRepresentable {
    let bridge: WeekPagerBridge
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { if let sv = v.enclosingScrollView, bridge.scrollView !== sv { bridge.scrollView = sv } }
    }
}
