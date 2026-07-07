// Colors for the Canvas renderer, mirroring the web calendar's CSS variables.
//
// Design rule (01-base.css): "Color comes only from event stickers; everything
// else is structure drawn with dotted/dashed/solid lines." So the grid is
// monochrome — a single warm accent at graded alpha — and only events are colored.

import SwiftUI

struct Theme {
    let dark: Bool

    // Base accent (theme-aware: dark-brown in light mode, light in dark mode) → the
    // single hue everything structural is drawn from, at varying alpha.
    private var accent: UInt32 { dark ? 0xd4b4b4 : 0x4c2d14 }

    var bg: Color { dark ? Color(hex: 0x101a2b) : Color(hex: 0xfefcfb) }

    var accentDark: Color { Color(hex: accent, opacity: dark ? 0.92 : 0.9) }   // --accent-dark / cc-line
    var accentGrey: Color { Color(hex: accent, opacity: 0.30) }                 // --accent-grey / cc-grid
    var sep: Color { Color(hex: accent, opacity: 0.5) }                         // --cc-sep (solid separators)

    var text: Color { Color(hex: accent, opacity: dark ? 0.92 : 0.9) }          // labels: accent-dark
    var textMuted: Color { Color(hex: accent, opacity: 0.45) }                  // day labels: accent-grey

    var gridLine: Color { accentDark }        // solid gridlines (cc-line)
    var cellGrid: Color { accentGrey }        // dotted day-cell verticals + lane separators

    var dimFill: Color { Color(hex: accent, opacity: dark ? 0.16 : 0.10) }
    var weekendWash: Color { Color(hex: accent, opacity: 0.045) }
    var highlight: Color { Color(hex: accent, opacity: 1) }                     // cc-hl base (item opacity is tiny)
    var cursor: Color { dark ? Color(hex: 0xcdd6ff) : Color(hex: 0xd8cfc8) }
    var nowLine: Color { Color(hex: 0xff3b6b) }
    var todayTint: Color { Color(hex: 0xff3b6b, opacity: 0.5) }                 // item opacity scales it further
    var eventText: Color { dark ? Color(hex: 0x0d1017) : .white }

    /// Event sticker color — the only place color appears.
    func eventColor(_ key: String?) -> Color {
        switch key {
        case "blue": return Color(hex: 0x3a6df0)
        case "indigo": return Color(hex: 0x4f46e5)
        case "cyan": return Color(hex: 0x0891b2)
        case "green": return Color(hex: 0x1f9d55)
        case "darkgreen": return Color(hex: 0x15803d)
        case "yellow": return Color(hex: 0xca8a04)
        case "orange": return Color(hex: 0xea7317)
        case "red": return Color(hex: 0xd1443f)
        case "purple": return Color(hex: 0x7c5cff)
        default: return dark ? Color(white: 0.6) : Color(hex: 0x8a7a6a)
        }
    }
    func eventFill(_ key: String?) -> Color { eventColor(key).opacity(dark ? 0.9 : 0.92) }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: opacity)
    }
}
