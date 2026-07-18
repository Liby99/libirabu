// Grouped engine constants, Layout/Theme-style — tuning values in one place instead of
// scattered instance `let`s on the engine.

import Foundation
import CoreGraphics

/// Animation timing + gesture-feel constants: every duration, overscroll threshold, and
/// sensitivity the navigation choreography uses. Durations are seconds.
enum Motion {
    /// Render loop: sleep this long after the last activity (covers SwiftUI fades).
    static let idleSleep: TimeInterval = 0.4

    // ── Zoom / pinch ──
    static let zoomDur: TimeInterval = 0.52          // default z-level tween
    static let pinchSens: CGFloat = 1.6              // trackpad magnification → z units

    // ── jumpToDay choreography (fly out → travel → fly in) ──
    static let flyOutDur: TimeInterval = 0.58        // zoom out to year before travelling
    static let flyInFarDur: TimeInterval = 1.05      // year → day after a cross-year scroll
    static let flyInMidDur: TimeInterval = 0.9       // year → day, same year
    static let flyInNearDur: TimeInterval = 0.7      // week/day-level hop, then zoom to day
    static let yearGlideDur: TimeInterval = 0.5      // year-view scroll glide before the fly-in
    static let weekGlideDur: TimeInterval = 0.32     // week hop glide (same-month target)
    /// Day-view day↔day glide: base + per-day-of-distance, capped.
    static let dayGlideBase: TimeInterval = 0.2
    static let dayGlidePerDay: TimeInterval = 0.035
    static let dayGlideMax: TimeInterval = 0.7

    // ── Snaps / keyboard glides ──
    static let weekSnapDur: TimeInterval = 0.2       // settle a fractional week position
    static let keyScrollPace: TimeInterval = 0.3     // year-view keyboard scroll: seconds per month band
    static let keyScrollMin: TimeInterval = 0.12     // floor for very short keyboard glides

    // ── Boundary flips (overscroll past an edge) ──
    static let yearFlipDur: TimeInterval = 1.0       // year-flip: scroll out + fade, swap, scroll in
    static let yearFadeSwapDur: TimeInterval = 0.5   // selectYear cross-fade (out → swap → in), no scroll motion
    static let monthFlipDur: TimeInterval = 0.8
    static let weekFlipDur: TimeInterval = 0.5
    static let weekFlipOver: CGFloat = 34            // on-screen overscroll (px) that arms a week flip
    static let weekOverMul: CGFloat = 1.9            // amplify the rubber-band travel past a month edge
    static let dayFlipDur: TimeInterval = 0.42
    static let dayFlipOver: CGFloat = 40             // on-screen overscroll (px) that arms a day flip
    static let dayOverMul: CGFloat = 1.4             // maps rubber-band px → day-page progress (preview)

    // ── Drawer ──
    static let drawerShiftDur: TimeInterval = 0.28   // canvas slide when the detail drawer opens/closes
}

/// View-behavior thresholds that aren't layout (Layout) or timing (Motion).
enum ViewConst {
    /// Deadlines/timed events are hittable once the day-detail timeline is revealed (month-detail
    /// and deeper), not just week/day — so a deadline can be interacted with in the monthly view too.
    static let detailZ: CGFloat = 0.82
    /// How close (px, either side of the timeline's left border) the cursor must be to reveal
    /// the scale bar.
    static let tlEdgeRevealDist: CGFloat = 80
}

/// UserDefaults keys for the view/import preferences shared between the engine, the Settings
/// window, and the app's menus. The STRING VALUES are persisted user state — never change them.
public enum PrefKeys {
    /// The "View ▸ Show Hidden Imported Events" toggle.
    public static let showHiddenImported = "cc.view.showHiddenImported"
    /// View ▸ Current Timezone — the main tz for deadline origin-time labels. "auto" = device zone.
    public static let mainTz = "cc.view.mainTz"
    /// View ▸ Alternative Timezone — the second hour column on the timeline. "none" = off.
    public static let altTz = "cc.view.altTz"
    /// The timeline scale-bar's per-hour height (week/day views). Persisted across launches.
    public static let weekHourH = "cc.view.weekHourH"
    /// Apple Calendar import: enabled-state + selected calendar ids (see +AppleImport).
    public static let appleEnabled = "cc.appleCal.enabled"
    public static let appleCalendars = "cc.appleCal.ids"
}
