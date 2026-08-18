// The pure viewport-overflow indicator math (EdgeIndicators.swift): clamp-at-the-edge, the
// 1/2/3-deep stack widths + indents + staircase heights (S/2S/3S, edge-pinned), the scroll-
// driven interpolation between stack layouts, the 4th-event handoff, and the bottom-edge
// mirror. All expected values are DERIVED from Layout.edgeIndicatorH / edgeIndicatorMorph so
// hand-tuning the constants keeps these green.

@testable import CalendarGeometry
import CoreGraphics
import XCTest

final class EdgeIndicatorTests: XCTestCase {
    let tlTop: CGFloat = 100, tlBottom: CGFloat = 800
    let colX: CGFloat = 0, colW: CGFloat = 104
    var baseX: CGFloat {
        colX + 2
    } // eventRect's horizontal insets
    var baseW: CGFloat {
        colW - 4
    }

    let S = Layout.edgeIndicatorH
    let T = Layout.edgeIndicatorMorph

    /// A 60px-tall full-width event rect whose BOTTOM sits at `maxY` (viewport space).
    func ending(_ maxY: CGFloat, x: CGFloat? = nil, w: CGFloat? = nil) -> CGRect {
        CGRect(x: x ?? baseX, y: maxY - 60, width: w ?? baseW, height: 60)
    }

    /// …and one whose TOP sits at `minY` (for the bottom edge).
    func starting(_ minY: CGFloat) -> CGRect {
        CGRect(x: baseX, y: minY, width: baseW, height: 60)
    }

    func layout(_ rects: [CGRect]) -> DayEdgeIndicators {
        dayEdgeIndicators(rects: rects, tlTop: tlTop, tlBottom: tlBottom, colX: colX, colW: colW)
    }

    func assertRect(_ r: CGRect, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.minX, x, accuracy: 0.001, "x", file: file, line: line)
        XCTAssertEqual(r.minY, y, accuracy: 0.001, "y", file: file, line: line)
        XCTAssertEqual(r.width, w, accuracy: 0.001, "w", file: file, line: line)
        XCTAssertEqual(r.height, h, accuracy: 0.001, "h", file: file, line: line)
    }

    // ── Candidacy + clamp ──────────────────────────────────────────────────────────

    func testFullyAndPartiallyVisibleEventsAreUntouched() {
        // Inside the viewport, and partially clipped but with ≥ S px still visible → no indicators.
        let out = layout([ending(400), ending(tlTop + S), ending(tlTop + 40)])
        XCTAssertTrue(out.top.isEmpty)
        XCTAssertTrue(out.bottom.isEmpty)
        XCTAssertTrue(out.isIndicator.isEmpty) // empty ⇔ nothing overflows
        XCTAssertNil(out.topHit)
        XCTAssertNil(out.topNearest)
    }

    func testClampPinsSliverAtRemnant() {
        // Less than S px would remain visible → the rect clamps: an S-px sliver pinned at the top,
        // full own width (a lone indicator keeps the full event width).
        let v = S / 2
        let out = layout([ending(tlTop + v), ending(500)])
        XCTAssertEqual(out.top.count, 1)
        let e = out.top[0]
        XCTAssertEqual(e.index, 0)
        XCTAssertEqual(e.rank, 0)
        XCTAssertEqual(e.opacity, 1, accuracy: 0.001)
        XCTAssertEqual(e.progress, (S - v) / T, accuracy: 0.001)
        assertRect(e.rect, baseX, tlTop, baseW, S) // stopped shrinking: pinned S-px sliver
        XCTAssertEqual(out.isIndicator, [true, false])
        XCTAssertEqual(out.topNearest, 0)
        XCTAssertEqual(out.topHit, CGRect(x: baseX, y: tlTop, width: baseW, height: S))
    }

    // ── Settled stack layouts: 1 / 2 / 3 indicators ───────────────────────────────

    func testSettledStackWidthsAndIndents() {
        let deep: CGFloat = tlTop - 5 * T // far past the morph distance → progress 1
        // One: full width, no indent.
        let one = layout([ending(deep)])
        assertRect(one.top[0].rect, baseX, tlTop, baseW, S)
        // Two: each (full − S) wide; the NEARER-in-time event (larger maxY) is innermost —
        // indented S, S tall, on top; the older one sits at the base edge, one step (2S) deep.
        let two = layout([ending(deep - 20), ending(deep)]) // index 1 is nearer
        XCTAssertEqual(two.top.map(\.index), [1, 0]) // rank-ascending: innermost first
        assertRect(two.top[0].rect, baseX + S, tlTop, baseW - S, S)
        assertRect(two.top[1].rect, baseX, tlTop, baseW - S, 2 * S)
        XCTAssertEqual(two.topNearest, 1)
        // Three: each (full − 2S) wide, indents 2S / S / 0 and staircase heights S / 2S / 3S
        // from innermost out — every card's TOP pinned at the edge.
        let three = layout([ending(deep - 40), ending(deep), ending(deep - 20)])
        XCTAssertEqual(three.top.map(\.index), [1, 2, 0])
        assertRect(three.top[0].rect, baseX + 2 * S, tlTop, baseW - 2 * S, S)
        assertRect(three.top[1].rect, baseX + S, tlTop, baseW - 2 * S, 2 * S)
        assertRect(three.top[2].rect, baseX, tlTop, baseW - 2 * S, 3 * S)
        for e in three.top {
            XCTAssertEqual(e.opacity, 1, accuracy: 0.001)
        }
        // The click band spans the whole staircase (its tallest card).
        XCTAssertEqual(three.topHit, CGRect(x: baseX, y: tlTop, width: baseW, height: 3 * S))
    }

    // ── Scroll-driven interpolation ───────────────────────────────────────────────

    func testSecondEventMorphMidpoint() {
        // One settled + a newcomer halfway through its morph (v = S − T/2 → p = 0.5): the settled
        // sliver's width interpolates full → (full − S) as a linear function of the newcomer's
        // progress; the newcomer lerps its own full-width sliver into the indented inner slot.
        let out = layout([ending(tlTop - 5 * T), ending(tlTop + S - T / 2)])
        XCTAssertEqual(out.top.map(\.index), [1, 0]) // newcomer (nearest) innermost
        let settled = out.top[1], newcomer = out.top[0]
        // Settled card: halfway to the 2-stack width AND halfway down its step (S → 2S).
        assertRect(settled.rect, baseX, tlTop, baseW - S / 2, 1.5 * S)
        XCTAssertEqual(newcomer.progress, 0.5, accuracy: 0.001)
        // Newcomer slot: x = baseX + S, w = baseW − S/2, h = S; own sliver: x = baseX, w = baseW.
        assertRect(newcomer.rect, baseX + S / 2, tlTop, baseW - S / 4, S)
    }

    func testTwoToThreeMorphMidpoint() {
        // Two settled + a third at p = 0.5: survivors' widths head to (full − 2S) — halfway is
        // (full − 1.5S) — while their indents hold (S and 0); the newcomer lerps into the 2S slot.
        let deep = tlTop - 5 * T
        let out = layout([ending(deep - 20), ending(deep), ending(tlTop + S - T / 2)])
        XCTAssertEqual(out.top.map(\.index), [2, 1, 0])
        let newcomer = out.top[0], mid = out.top[1], outer = out.top[2]
        // Survivors' heights step down the staircase with the newcomer: S→2S and 2S→3S, halfway.
        assertRect(mid.rect, baseX + S, tlTop, baseW - 1.5 * S, 1.5 * S)
        assertRect(outer.rect, baseX, tlTop, baseW - 1.5 * S, 2.5 * S)
        // Newcomer: slot (x = baseX + 2S, w = baseW − 1.5S, h = S) lerped 50% from its own sliver.
        assertRect(newcomer.rect, baseX + S, tlTop, baseW - 0.75 * S, S)
        XCTAssertEqual(out.topNearest, 2)
    }

    func testFourthEventHandoff() {
        // Three settled + a newcomer at p = 0.5: the OUTERMOST of the three fades out by exactly
        // the newcomer's progress while the two survivors' indents relax (2S→S and S→0, halfway
        // here), and the newcomer morphs into the innermost slot. Widths hold at (full − 2S).
        let deep = tlTop - 5 * T
        let a = ending(deep) // innermost of the old stack
        let b = ending(deep - 20)
        let c = ending(deep - 40) // outermost — the one pushed out
        let n = ending(tlTop + S - T / 2) // newcomer, p = 0.5
        let out = layout([a, b, c, n])
        XCTAssertEqual(out.top.map(\.index), [3, 0, 1, 2])
        let nw = out.top[0], sa = out.top[1], sb = out.top[2], sc = out.top[3]
        XCTAssertEqual(sc.opacity, 0.5, accuracy: 0.001) // exiting, half faded
        // The exiting outermost holds its place: base edge, frozen at the deepest step (3S).
        assertRect(sc.rect, baseX, tlTop, baseW - 2 * S, 3 * S)
        // Survivors: indents relax a step while heights grow one — both halfway here.
        assertRect(sa.rect, baseX + 1.5 * S, tlTop, baseW - 2 * S, 1.5 * S) // 2S→S in, S→2S tall
        assertRect(sb.rect, baseX + 0.5 * S, tlTop, baseW - 2 * S, 2.5 * S) // S→0 in, 2S→3S tall
        // Newcomer: innermost slot (x = baseX + 2S, capped; h = S), lerped 50% from its own sliver.
        assertRect(nw.rect, baseX + S, tlTop, baseW - S, S)
        XCTAssertEqual(nw.opacity, 1, accuracy: 0.001)

        // Fully settled: the 4th is gone, the newcomer owns the innermost slot of a clean 3-stack.
        let settled = layout([a, b, c, ending(deep + 10)])
        XCTAssertEqual(settled.top.count, 3)
        XCTAssertEqual(settled.top.map(\.index), [3, 0, 1])
        assertRect(settled.top[0].rect, baseX + 2 * S, tlTop, baseW - 2 * S, S)
        assertRect(settled.top[1].rect, baseX + S, tlTop, baseW - 2 * S, 2 * S)
        assertRect(settled.top[2].rect, baseX, tlTop, baseW - 2 * S, 3 * S)
    }

    // ── Bottom edge mirror ────────────────────────────────────────────────────────

    func testBottomEdgeMirrors() {
        let deep = tlBottom + 5 * T
        // One below the fold: an S-px sliver pinned at the BOTTOM edge.
        let one = layout([starting(deep)])
        XCTAssertTrue(one.top.isEmpty)
        assertRect(one.bottom[0].rect, baseX, tlBottom - S, baseW, S)
        XCTAssertEqual(one.bottomHit, CGRect(x: baseX, y: tlBottom - S, width: baseW, height: S))
        // Two: the nearer-in-time event (SMALLER minY — the earlier one) is innermost/indented;
        // the staircase mirrors — deeper cards grow UPWARD from the bottom edge (bottoms pinned).
        let two = layout([starting(deep + 20), starting(deep)])
        XCTAssertEqual(two.bottom.map(\.index), [1, 0])
        assertRect(two.bottom[0].rect, baseX + S, tlBottom - S, baseW - S, S)
        assertRect(two.bottom[1].rect, baseX, tlBottom - 2 * S, baseW - S, 2 * S)
        XCTAssertEqual(two.bottomNearest, 1)
        XCTAssertEqual(two.bottomHit, CGRect(x: baseX, y: tlBottom - 2 * S, width: baseW, height: 2 * S))
    }

    // ── Own-width continuity (packed sub-column events) ───────────────────────────

    func testNarrowEventWidensIntoItsSlot() {
        // A half-width packed event: at the clamp point its sliver keeps its OWN x/width
        // (continuous with the clipped sticker it replaces); settled, it fills the full slot.
        let ownX = baseX + baseW / 2, ownW = baseW / 2
        let atClamp = layout([ending(tlTop + S - 0.0001, x: ownX, w: ownW)])
        XCTAssertEqual(atClamp.top[0].rect.minX, ownX, accuracy: 0.01)
        XCTAssertEqual(atClamp.top[0].rect.width, ownW, accuracy: 0.01)
        let settled = layout([ending(tlTop - 5 * T, x: ownX, w: ownW)])
        assertRect(settled.top[0].rect, baseX, tlTop, baseW, S)
    }
}
