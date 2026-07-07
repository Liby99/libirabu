// swift-tools-version: 6.0
import PackageDescription

// CalendarKit — native Swift port of the web calendar.
//
// Layering (dependencies point one way, toward purity):
//   CalendarGeometry  ← pure math, no dependencies (Foundation + CoreGraphics)
//   CalendarEngine    ← @Observable view-state + tween clock   (→ Geometry)
//   CalendarUI        ← Canvas renderer + SwiftUI views         (→ Geometry, Engine)
//   CalendarMac       ← macOS app bootstrap (executable)        (→ UI)
//
// Milestone target is macOS 14 so it builds/runs on the widest toolchain; the
// shipping plan bumps this to macOS 26 for Liquid Glass etc. Language mode is held
// at v5 for the milestone to avoid strict-concurrency churn — tighten to .v6 later.
let package = Package(
    name: "CalendarKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CalendarGeometry", targets: ["CalendarGeometry"]),
        .library(name: "CalendarEngine", targets: ["CalendarEngine"]),
        .library(name: "CalendarUI", targets: ["CalendarUI"]),
        .executable(name: "CalendarMac", targets: ["CalendarMac"]),
    ],
    targets: [
        .target(name: "CalendarGeometry"),
        .target(name: "CalendarEngine", dependencies: ["CalendarGeometry"]),
        .target(name: "CalendarUI", dependencies: ["CalendarGeometry", "CalendarEngine"]),
        .executableTarget(name: "CalendarMac", dependencies: ["CalendarUI"]),
        .testTarget(name: "CalendarGeometryTests", dependencies: ["CalendarGeometry"]),
    ],
    swiftLanguageModes: [.v5]
)
