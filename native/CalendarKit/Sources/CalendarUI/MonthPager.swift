// Month↕month paging, driven by a real (but invisible) SwiftUI ScrollView.
//
// AppKit has no native vertical paging, but SwiftUI does: `.scrollTargetBehavior(.paging)`
// gives velocity-aware, snap-to-page scrolling with the native deceleration curve (the
// closest thing to iOS's isPagingEnabled). We host 12 empty page cells (one per month),
// let SwiftUI do all the physics, and observe the absolute content offset via
// `.onScrollGeometryChange` — projecting it onto the engine's (focus, monthAnim) state that
// the Canvas already renders. Nothing here is drawn; it's purely an input/physics proxy.
//
// The AppKit input catcher sits on top (for clicks/hover/pinch), so it FORWARDS month-view
// scroll events into this ScrollView's backing NSScrollView — handed over through `bridge`.

import SwiftUI
import AppKit
import CalendarEngine

/// Month paging that's lighter than the built-in `.paging`: one gesture turns at most one
/// month, and it commits on a small drag OR a gentle flick (both tunable) — so it doesn't feel
/// like you have to heave a full screen to advance. SwiftUI still supplies the native
/// deceleration to whichever page we pick.
struct MonthPagingBehavior: ScrollTargetBehavior {
    var commitFraction: CGFloat = 0.18   // drag ≥ this fraction of a page → turn
    var flickVelocity: CGFloat = 180     // …or fling faster than this (pts/sec) → turn

    func updateTarget(_ target: inout ScrollTarget, context: ScrollTargetBehaviorContext) {
        let page = context.containerSize.height
        guard page > 0 else { return }
        let start = context.originalTarget.rect.origin.y      // page we began the gesture on
        let startPage = (start / page).rounded()
        let dragged = target.rect.origin.y - start            // SwiftUI's projected landing
        let v = context.velocity.dy
        var dest = startPage
        if dragged > page * commitFraction || v > flickVelocity { dest = startPage + 1 }
        else if dragged < -page * commitFraction || v < -flickVelocity { dest = startPage - 1 }
        target.rect.origin.y = dest * page                    // land exactly on a month
    }
}

/// Shared handle between the SwiftUI paging driver and the AppKit `CatcherView`. Positioning is
/// IMPERATIVE (scroll the backing NSScrollView), NOT via `.scrollPosition` — a two-way position
/// binding re-renders the pager while scrolling and re-applies itself, which jumps the offset.
@MainActor final class MonthPagerBridge {
    weak var scrollView: NSScrollView? { didSet { if let p = pending { pending = nil; scrollTo(p) } } }
    private var pending: CGFloat?
    func scrollTo(_ y: CGFloat) {
        guard let sv = scrollView else { pending = y; return }
        sv.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
        sv.reflectScrolledClipView(sv.contentView)
    }
}

struct MonthPager: View {
    let engine: CalendarEngine
    let bridge: MonthPagerBridge

    var body: some View {
        GeometryReader { geo in
            let pageH = geo.size.height
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(0..<12, id: \.self) { m in
                        Color.clear.frame(height: pageH).id(m)
                    }
                }
                .scrollTargetLayout()
                .background(ScrollViewGrabber(bridge: bridge))   // capture the backing NSScrollView
            }
            .scrollTargetBehavior(MonthPagingBehavior())   // lighter than .paging, still native decel
            .scrollBounceBehavior(.always)                 // elastic overscroll at Jan/Dec → boundary flip
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, y in
                engine.setMonthProgress(y, pageH: pageH)
            }
            .onAppear { bridge.scrollTo(CGFloat(engine.focus) * pageH) }
            // Entering month view (from year/week): snap the pager to the focused month.
            .onChange(of: engine.chrome.level) { _, lvl in
                if lvl == 1 { bridge.scrollTo(CGFloat(engine.focus) * pageH) }
            }
            // A boundary flip changed year+focus (Jan↔Dec across years) without leaving month
            // view — jump the pager to the new focus (setMonthProgress is guarded during the flip).
            .onChange(of: engine.chrome.monthResync) { _, _ in bridge.scrollTo(CGFloat(engine.focus) * pageH) }
        }
        // No allowsHitTesting(false): the AppKit catcher sits on top and shields this from all
        // direct events, and we want SwiftUI's paging machinery fully intact for forwarded events.
    }
}

/// Zero-size probe that hands its enclosing NSScrollView (the one SwiftUI's ScrollView is
/// backed by) up to the bridge, so the AppKit catcher can forward scroll events into it.
private struct ScrollViewGrabber: NSViewRepresentable {
    let bridge: MonthPagerBridge
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { if let sv = v.enclosingScrollView, bridge.scrollView !== sv { bridge.scrollView = sv } }
    }
}
