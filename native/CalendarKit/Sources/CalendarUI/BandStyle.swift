// Visual style for band (all-day) events — the "CSS" for bands. Tweak these and rebuild.
//
// Color model: the band's glass is tinted with the SATURATED event color
// (theme.eventColor) at the per-state opacity below. The material is `.regular`
// (frosted) so the tint actually shows — `.clear` glass renders almost no tint,
// which is what made earlier bands look washed out. Drop `idleFrosted` to false to
// go back to a clearer (more transparent, less colorful) idle look.

import SwiftUI

enum BandStyle {
    static let cornerRadius: CGFloat = 9

    // Tint = saturated event color at this opacity, by state (0…1).
    static let tintIdle: Double = 0.25
    static let tintHovered: Double = 0.40
    static let tintSelected: Double = 0.45

    // Idle material: true = .regular (frosted, colorful), false = .clear (transparent, pale).
    static let idleFrosted = true

    // Left accent bar (rounded capsule), inset from left/top/bottom.
    static let accentInset: CGFloat = 6
    static let accentWidth: CGFloat = 1
    static let accentWidthSelected: CGFloat = 3

    // Borders.
    static let selectedBorderWidth: CGFloat = 1
    static let selectedDash: [CGFloat] = [4, 2]      // thin dotted when just selected
    static let drawerBorderWidth: CGFloat = 2        // solid + thicker when the drawer is open

    // Title.
    static let titleSize: CGFloat = 12
    static let barTextGap: CGFloat = 7   // fixed gap between the accent bar and the title
    static let titleTrailing: CGFloat = 6

    static let animation: Double = 0.18              // state-transition duration (s)
}
