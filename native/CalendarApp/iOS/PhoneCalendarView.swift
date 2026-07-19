// The iPhone read-only calendar surface — the same scene the Mac renders, minus editing.
//
// Layer stack (bottom → top):
//   PhoneDriverLayer  — invisible per-level ScrollView drivers (touch physics → engine state)
//   render layers     — Canvas passes + glass overlays, allowsHitTesting(false), exactly the
//                       Mac's CalendarView.calendarScene reduced to its read-only layers
//   chrome            — Breadcrumb + calendar switcher (top), sync status (bottom)
// Pinch (semantic zoom) and tap (select / drill-in) ride as simultaneous gestures over the
// drivers. Tapping an item opens PhoneEventSheet (read-only); tapping empty space drills a
// zoom level in, like the Mac's click.

import CalendarEngine
import CalendarGeometry
import CalendarRender
import SwiftUI

struct PhoneCalendarView: View {
    let engine: CalendarEngine
    @Environment(\.colorScheme) private var scheme
    @State private var sheetItem: SheetItem?
    @State private var showMenu = false
    @State private var showAI = false

    private struct SheetItem: Identifiable {
        let id: String
    }

    var body: some View {
        let theme = Theme(dark: scheme == .dark)
        ZStack(alignment: .bottom) {
            GeometryReader { geo in
                let vp = Viewport(w: geo.size.width - Layout.padLeft - Layout.padRight, h: geo.size.height)
                // Reading `awake` here re-evaluates the body the instant the engine wakes (any
                // navigation/animation), and drops to a single static frame when idle — same
                // idle-CPU pattern as the Mac's calendarSurface.
                let awake = engine.renderClock.awake
                ZStack {
                    PhoneDriverLayer(engine: engine, vp: vp)
                    TimelineView(.animation(paused: !awake)) { tl in
                        calendarScene(engine.sceneInput(at: tl.date, viewport: vp), vp: vp, theme: theme)
                    }
                    .allowsHitTesting(false) // presentational; touch goes to the drivers below
                }
                .simultaneousGesture(tap)
                .onAppear {
                    engine.setViewport(geo.size)
                    // PHONE V1 is year-view only (z stays 0) — land centered on today's month.
                    engine.goToCurrent("year")
                }
                .onChange(of: geo.size) { _, s in engine.setViewport(s) }
            }
            // Full-bleed canvas: extend under the status bar AND the home-indicator inset so
            // the grid runs edge to edge — content scrolls beneath the Dynamic Island and the
            // floating capsules instead of stopping at solid safe-area strips. The content's
            // own top insets (Layout.yearTop/topPad, set from the measured island height in
            // PhoneCalendarRoot) keep the resting labels clear of the island.
            .ignoresSafeArea(.container, edges: [.top, .bottom])
            // The toolbar capsules stay INSIDE the safe area (above the home indicator).
            bottomBar
        }
        .background(theme.bg.ignoresSafeArea())
        .sheet(item: $sheetItem, onDismiss: { engine.select(nil) }) { item in
            PhoneEventSheet(engine: engine, boxId: item.id, theme: theme)
        }
        .fullScreenCover(isPresented: $showMenu) {
            PhoneMenuView(engine: engine)
        }
        .sheet(isPresented: $showAI) {
            VStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title)
                    .foregroundStyle(.tint)
                Text("The assistant is coming to iPhone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .presentationDetents([.fraction(0.25)])
            .presentationDragIndicator(.visible)
        }
    }

    // ── Gestures ─────────────────────────────────────────────────────────────────────
    // PHONE V1 (year-only): no pinch — z is pinned to 0. The semantic-zoom MagnifyGesture
    // (per-event deltas into engine.onMagnify) returns when the deeper views are enabled.

    /// Tap on an item → select + read-only sheet. On empty space at YEAR level, drill into
    /// the tapped month (the breadcrumb's Year crumb zooms back out). Month level doesn't
    /// drill deeper yet — week/day come later.
    private var tap: some Gesture {
        SpatialTapGesture()
            .onEnded { v in
                let p = geomPoint(v.location)
                if let id = engine.itemId(at: p) {
                    engine.select(id)
                    sheetItem = SheetItem(id: id)
                } else if engine.isYearLevel {
                    engine.navigate(at: p)
                }
            }
    }

    /// View-space → geometry-space (the render layers draw offset by padLeft; see the Mac's
    /// CalendarInputLayer point mapping — no drawer shift on the phone).
    private func geomPoint(_ loc: CGPoint) -> CGPoint {
        CGPoint(x: loc.x - Layout.padLeft, y: loc.y)
    }

    // ── Chrome ───────────────────────────────────────────────────────────────────────

    /// Floating Liquid Glass toolbar (Music/Safari style, iOS 26): two capsules resting
    /// ABOVE the calendar canvas — Breadcrumb on the left; AI + Menu on the right. The
    /// canvas runs full-height beneath them. Menu opens the full-screen configuration view.
    private var bottomBar: some View {
        HStack {
            HStack(spacing: 0) {
                Breadcrumb(engine: engine)
            }
            .frame(height: 44)
            .glassEffect(.regular, in: .capsule)
            Spacer()
            HStack(spacing: 2) {
                Button { showAI = true } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                Button { showMenu = true } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
            .glassEffect(.regular, in: .capsule)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
        .offset(y: 8) // nudge into the home-indicator area a touch (visual, not layout)
    }

    // ── Scene ────────────────────────────────────────────────────────────────────────

    /// The Mac's calendarScene, reduced to the read-only layers (no marquee, no keyboard cursor
    /// rings, no drawer lift/blur, no dashboard driver).
    private func calendarScene(_ input: SceneInput, vp: Viewport, theme: Theme) -> some View {
        ZStack {
            // 1. scene below events — grid, washes, today, day labels
            Canvas { ctx, _ in
                var c = ctx
                c.translateBy(x: Layout.padLeft, y: 0)
                SceneRenderer.drawBelow(input: input, in: &c, theme: theme)
            }
            // 2. events (bands + timed) — perfMode on the phone: flat tinted fills instead of
            // Liquid Glass (a year of glass stickers is too costly on mobile GPU budgets).
            EventsOverlay(input: input, events: engine.viewEvents(), bands: engine.viewBands(),
                          bandBadges: engine.viewBandBadges(), eventBadges: engine.viewEventBadges(),
                          selected: engine.selectedId, hovered: nil,
                          drawerOpen: sheetItem != nil, editingId: nil,
                          perfMode: true,
                          editGen: engine.displayGen,
                          theme: theme)
                .offset(x: Layout.padLeft)
            // 3. deadlines: moment line + dots in the Canvas, labels as glass pills above it
            Canvas { ctx, _ in
                var c = ctx
                c.translateBy(x: Layout.padLeft, y: 0)
                SceneRenderer.drawMid(input: input, deadlines: engine.viewDeadlines(),
                                      selected: engine.selectedId, in: &c, theme: theme)
            }
            DeadlinesOverlay(input: input, deadlines: engine.viewDeadlines(),
                             sides: engine.deadlineSides(),
                             selected: engine.selectedId, hovered: nil,
                             drawerOpen: false, theme: theme)
                .offset(x: Layout.padLeft)
            // 4. chrome on top of the glass: gutter labels/borders, track names, now-line
            Canvas { ctx, _ in
                var c = ctx
                c.translateBy(x: Layout.padLeft, y: 0)
                SceneRenderer.drawAbove(input: input, tracks: engine.items.trackNames, in: &c, theme: theme)
            }
        }
        .opacity(input.flipFade) // whole-calendar fade during a year flip
    }
}
