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
    static let tintIdle: Double = 0.20
    static let tintHovered: Double = 0.25
    static let tintSelected: Double = 0.40

    /// Idle material: true = .regular (frosted, colorful), false = .clear (transparent, pale).
    static let idleFrosted = true

    // Left accent bar (rounded capsule), inset from left/top/bottom.
    static let accentInset: CGFloat = 6
    static let accentWidth: CGFloat = 1
    static let accentWidthSelected: CGFloat = 3

    // Borders — one per activation level (see EventActivation).
    static let accompaniedBorderWidth: CGFloat = 1 // dashed, for a focused event's siblings
    static let accompaniedDash: [CGFloat] = [2, 1]
    static let focusBorderWidth: CGFloat = 1.5 // normal solid, for the single-clicked box
    static let selectedBorderWidth: CGFloat = 3 // thick solid, for the double-clicked (drawer) box

    // Title.
    static let titleSize: CGFloat = 12
    static let barTextGap: CGFloat = 5 // fixed gap between the accent bar and the title/markers
    static let titleTrailing: CGFloat = 6

    static let animation: Double = 0.18 // state-transition duration (s)
}

/// The five visual activation levels for an event box. Assigned per-box in EventsOverlay:
///   plain        — no activation (flat fill under Performance Mode)
///   hover        — pointer over this exact box → glass tint bump, no border
///   focusMain    — single-clicked box → normal solid border
///   accompanied  — a sibling of the focused series (recurrence/promoted/original) → dashed border
///   selected     — double-clicked box (drawer open) → thick solid border
enum EventActivation: Equatable {
    case plain, hover, focusMain, accompanied, selected

    var isActive: Bool {
        self != .plain
    }

    /// Whether this box un-truncates its title (and gets the spill scrim). Only the single box the
    /// user is focused on — the exact clicked/drawer box, or a lone hovered box — expands; the
    /// siblings of a selected series stay clipped and scrim-free so only the main title spills.
    var expandsTitle: Bool {
        switch self { case .hover, .focusMain, .selected: return true; default: return false }
    }

    var tint: Double {
        switch self {
        case .plain: BandStyle.tintIdle
        case .hover: BandStyle.tintHovered
        case .focusMain, .accompanied, .selected: BandStyle.tintSelected
        }
    }

    /// Thicker accent bar for any "committed" (clicked) level; thin for idle/hover.
    var accentWide: Bool {
        switch self { case .focusMain, .accompanied, .selected: return true; default: return false }
    }

    /// Draw priority: the clicked box on top, then its siblings, then a hovered box.
    var z: Double {
        switch self {
        case .selected, .focusMain: 1001
        case .accompanied: 1000
        case .hover: 950
        case .plain: 0
        }
    }
}
