// Viewport-overflow indicators for the week/day hour timelines: a timed event scrolled fully past
// the timeline's top/bottom edge leaves a small sliver of its color pinned at that edge, Apple-
// Calendar-style. PURE math, evaluated per frame from (event rects, viewport): every clamp/stack/
// indent value is a continuous piecewise-linear function of each event's overshoot past the edge,
// so smooth scroll-driven transitions fall out of the arithmetic — no discrete animations anywhere.
//
// Model (per day column, per edge; S = Layout.edgeIndicatorH, T = Layout.edgeIndicatorMorph):
//  • v = the rect's remaining visible extent toward the edge (top: maxY − tlTop; bottom mirrored).
//    While v ≥ S the event renders normally (the viewport clip shrinks it). At v < S it CLAMPS:
//    an S-px sliver pinned at the edge — the event stops shrinking with S px left.
//  • p = clamp((S − v)/T, 0, 1) is the event's morph progress: how far past the clamp point it
//    has scrolled, normalized over T px of travel. Each indicator's rect lerps from its own
//    clamped sliver (own x/width) into its stack slot by p — so a newcomer's arrival IS the
//    interpolation toward the next stack layout, driven only by scroll.
//  • Rank = nearness-in-time to the visible window (top edge: larger maxY = nearer). Rank 0 is
//    the INNERMOST slot — largest indent, drawn on top — matching Apple Calendar's order.
//  • vis(r) = clamp(max − Σ p of nearer members, 0, 1): the stack holds at most
//    Layout.edgeIndicatorMax slivers, and as a newcomer crosses, the pushed-out outermost fades
//    by exactly the newcomer's progress. total = Σ p·vis is the CONTINUOUS member count:
//      width     = base − S·(clamp(total, 1, max) − 1)
//      indent(r) = S·min(Σ outward p·vis, max − 1)
//    reproduce the integer layouts (1 → full width; 2 → full−S stepped S; 3 → full−2S stepped
//    0/S/2S) exactly, and linearly interpolate every transition between them — including the
//    4th-event handoff, where the survivors' indents relax while the outermost fades out.

import CoreGraphics

/// One pinned sliver at a timeline edge.
public struct EdgeIndicator: Sendable, Equatable {
    public var index: Int // into the rects array handed to dayEdgeIndicators
    public var rect: CGRect // the sliver (viewport space): Layout.edgeIndicatorH tall, at the edge
    public var opacity: CGFloat // 1 shown … → 0 as the pushed-out outermost exits
    public var rank: Int // 0 = nearest-in-time / innermost — draw ABOVE higher ranks
    public var progress: CGFloat // 0 just clamped … 1 settled into its stack slot
}

/// One day column's overflow-indicator layout against the timeline viewport.
public struct DayEdgeIndicators: Sendable, Equatable {
    public var top: [EdgeIndicator] = [] // rank-ascending (innermost first)
    public var bottom: [EdgeIndicator] = []
    /// Per input index: true → this rect is an edge candidate this frame (render its
    /// EdgeIndicator, NOT the normal sticker). EMPTY ⇔ no indicators at all (all normal).
    public var isIndicator: [Bool] = []
    /// The stack's single click target — one full-event-width band at the edge per stack
    /// (clicking anywhere on it targets the nearest event, whichever sliver is under the cursor).
    public var topHit: CGRect?
    public var bottomHit: CGRect?
    /// Input index of the NEAREST off-viewport event per edge — what a stack click scrolls to.
    public var topNearest: Int?
    public var bottomNearest: Int?

    public init() {}
}

/// Compute one day column's edge indicators. `rects` are the day's timed-segment rects in
/// VIEWPORT space (timeline scroll already applied; may extend past tlTop/tlBottom); `colX`/
/// `colW` describe the day column — the full event width derives from them with the same ±2px
/// horizontal insets `eventRect` applies. Pure and allocation-light: the no-overflow frame
/// returns an empty layout without building any per-rect state.
public func dayEdgeIndicators(rects: [CGRect], tlTop: CGFloat, tlBottom: CGFloat,
                              colX: CGFloat, colW: CGFloat) -> DayEdgeIndicators {
    let S = Layout.edgeIndicatorH
    var out = DayEdgeIndicators()
    guard tlBottom - tlTop > 2 * S + 1, colW > 0, !rects.isEmpty else { return out }
    let baseX = colX + 2
    let baseW = max(3, colW - 4) // mirror eventRect's horizontal insets
    let top = edgeStack(rects, edgeY: tlTop, topEdge: true, baseX: baseX, baseW: baseW)
    let bottom = edgeStack(rects, edgeY: tlBottom, topEdge: false, baseX: baseX, baseW: baseW)
    guard !(top.isEmpty && bottom.isEmpty) else { return out }
    out.top = top
    out.bottom = bottom
    var flags = [Bool](repeating: false, count: rects.count)
    for e in top {
        flags[e.index] = true
    }
    for e in bottom {
        flags[e.index] = true
    }
    out.isIndicator = flags
    if let inner = top.first {
        out.topNearest = inner.index
        out.topHit = CGRect(x: baseX, y: tlTop, width: baseW, height: S)
    }
    if let inner = bottom.first {
        out.bottomNearest = inner.index
        out.bottomHit = CGRect(x: baseX, y: tlBottom - S, width: baseW, height: S)
    }
    return out
}

/// The continuous stack layout for ONE edge (see the file header for the model). Returns the
/// shown slivers rank-ascending (innermost first); fully pushed-out members are omitted.
private func edgeStack(_ rects: [CGRect], edgeY: CGFloat, topEdge: Bool,
                       baseX: CGFloat, baseW: CGFloat) -> [EdgeIndicator] {
    let S = Layout.edgeIndicatorH
    let T = Layout.edgeIndicatorMorph
    let maxN = CGFloat(Layout.edgeIndicatorMax)
    // Candidates: less than the clamp remnant still visible toward this edge.
    var cand: [(i: Int, v: CGFloat)] = []
    for (i, r) in rects.enumerated() {
        let v = topEdge ? r.maxY - edgeY : edgeY - r.minY
        if v < S {
            cand.append((i, v))
        }
    }
    if cand.isEmpty {
        return []
    }
    // Rank 0 = nearest-in-time to the visible window (largest remaining v); ties by input order.
    cand.sort { $0.v != $1.v ? $0.v > $1.v : $0.i < $1.i }
    let p = cand.map { clamp((S - $0.v) / T, 0, 1) }
    // Visibility: each member sees the morph mass INWARD of it; past maxN members it fades out
    // by exactly the newcomers' progress (the 4th-event handoff).
    var vis = [CGFloat](repeating: 0, count: cand.count)
    var inward: CGFloat = 0
    for r in cand.indices {
        vis[r] = clamp(maxN - inward, 0, 1)
        inward += p[r]
    }
    var total: CGFloat = 0
    for r in cand.indices {
        total += p[r] * vis[r]
    }
    let slotW = max(3, baseW - S * (clamp(total, 1, maxN) - 1))
    let slotY = topEdge ? edgeY : edgeY - S
    // Walk outermost → innermost accumulating the vis-weighted mass OUTWARD of each rank — that
    // mass (× S) is the rank's indent, so indents relax continuously as the outermost exits.
    var outward: CGFloat = 0
    var out: [EdgeIndicator] = []
    for r in stride(from: cand.count - 1, through: 0, by: -1) {
        if vis[r] > 0.001 {
            let slotX = baseX + S * min(outward, maxN - 1)
            let own = rects[cand[r].i]
            // p lerps the sliver from its own clamped rect (continuous with the just-clipped
            // sticker it replaces) into its stack slot.
            let rect = CGRect(x: lerp(own.minX, slotX, p[r]), y: slotY,
                              width: lerp(own.width, slotW, p[r]), height: S)
            out.append(EdgeIndicator(index: cand[r].i, rect: rect, opacity: vis[r],
                                     rank: r, progress: p[r]))
        }
        outward += p[r] * vis[r]
    }
    return Array(out.reversed())
}
