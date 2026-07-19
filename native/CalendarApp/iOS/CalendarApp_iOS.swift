// The iPhone app shell — a READ-ONLY viewer over the same CloudKit data as the Mac app.
//
// The engine is constructed with cloudReadOnly: true, so CKSyncEngine fetches and applies
// remote changes but is hard-blocked from ever sending (see CloudSync/RegistrySync.readOnly).
// The UI (PhoneCalendarView) renders the Mac's scene via the shared CalendarRender target
// and never mutates. SyncHarnessView (the original sync test harness) is kept in the target
// for debugging but is no longer the root.

import CalendarEngine
import CalendarGeometry
import CalendarRender
import SwiftUI

@main
struct CalendarPhoneApp: App {
    init() {
        // Phone-fit layout, write-once before the first render (see Layout.labelW/padLeft):
        // gutter collapses to just the rotated month name (no track-name column — the
        // desktop's 250pt gutter would eat most of a portrait screen), flush to the left
        // edge, so the day grid gets the full remaining width (padRight is already 0).
        // 44pt (vs the desktop name zone's 28) so the month timeline's in-gutter hour
        // labels ("9AM") fit; mnameW matches it, which is what flags compact-gutter mode.
        Layout.labelW = 44
        Layout.mnameW = 44
        Layout.padLeft = 0
        // Legible year cells: well above the ~12pt a 31-day month gets on a portrait screen.
        // Each quarter overflows into its own horizontal scroll (see PhoneYearDriver).
        Layout.yearMinDayW = 45
        // Top insets (yearTop/topPad) are finalized in PhoneCalendarRoot once the device's
        // status-bar inset is measured — the canvas runs full-bleed under the Dynamic Island
        // and the content starts just below it. These are pre-measure fallbacks only.
        Layout.yearTop = 0
        Layout.topPad = 32
        // The floating glass toolbar's footprint measured from the physical bottom edge
        // (34 home-indicator + 4 inset + 44 capsule). The month/week timeline bottoms out
        // above this; tune here as the toolbar evolves.
        Layout.bottomBarH = 82
        // …and the last quarter must scroll clear of the floating glass toolbar. The canvas
        // is full-bleed (ignores the bottom safe area), so measured from the PHYSICAL bottom:
        // ~34 home-indicator inset + 4 toolbar inset + 44 capsule + breathing room.
        Layout.bottomPad = 104
        // Larger event titles: only a screenful of cells is visible at a time on the phone.
        BandStyle.titleSize = 15
    }

    /// One engine for the process. Constructing it kicks off CloudKit sync (see
    /// CalendarEngine.enableCloudSyncIfEntitled → CloudSync.startIfAccountAvailable).
    @State private var engine = CalendarEngine(cloudReadOnly: true)

    /// Extra breathing room between the bottom of the status bar / Dynamic Island and the
    /// first content (year: day-number header; month: date row). Tune to taste.
    private static let topBreathingRoom: CGFloat = 52

    /// Measures the device's top safe-area inset (Dynamic Island / status bar) BEFORE the
    /// calendar mounts, then finalizes the top layout knobs: the canvas itself runs
    /// full-bleed under the status bar (no solid strip up there — the grid shows through),
    /// and the content top insets (yearTop/topPad) clear the island by exactly its height.
    /// Mounting after measurement preserves the knobs' write-once-before-first-render rule.
    private struct PhoneCalendarRoot: View {
        let engine: CalendarEngine
        @State private var measured = false

        var body: some View {
            GeometryReader { geo in
                ZStack {
                    if measured {
                        PhoneCalendarView(engine: engine)
                    }
                }
                .onAppear {
                    let contentTop = geo.safeAreaInsets.top + CalendarPhoneApp.topBreathingRoom
                    Layout.yearTop = contentTop // year: day-number header
                    Layout.topPad = contentTop + 30 // month: 1–31 date row sits 20pt above the band
                    measured = true
                }
            }
            .ignoresSafeArea(.container, edges: .top) // reintroduces the inset on the proxy
        }
    }
    @Environment(\.scenePhase) private var scenePhase

    var body: some SwiftUI.Scene { // CalendarGeometry also has a `Scene` (the render item list)
        WindowGroup {
            PhoneCalendarRoot(engine: engine)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                engine.syncNow() // fetch-only under cloudReadOnly
            }
        }
    }
}
