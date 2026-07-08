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
    var todayTint: Color { Color(hex: 0xff3b6b, opacity: 0.07) }                // --cc-today: now at 7%

    // Event stickers are the ONLY color: a translucent tint fill + an opaque
    // border/accent, exact values from globals.css (--event-*).
    func eventFill(_ key: String?) -> Color { ev(key).fill }
    func eventBorder(_ key: String?) -> Color { ev(key).border }

    private func ev(_ key: String?) -> (fill: Color, border: Color) {
        func c(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> Color {
            Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
        }
        // extra palette is literal (theme-consistent) in both modes
        switch key {
        case "orange": return (c(236, 152, 70, 0.2), c(236, 152, 70))
        case "cyan": return (c(104, 196, 206, 0.2), c(104, 196, 206))
        case "darkgreen": return (c(104, 146, 86, 0.22), c(104, 146, 86))
        case "indigo": return (c(124, 150, 226, 0.2), c(124, 150, 226))
        default: break
        }
        if dark {
            switch key {
            case "red": return (c(255, 128, 128, 0.18), c(255, 179, 179))
            case "yellow": return (c(255, 236, 179, 0.18), c(255, 224, 130))
            case "green": return (c(200, 255, 200, 0.18), c(178, 255, 178))
            case "blue": return (c(128, 170, 255, 0.18), c(179, 207, 255))
            case "purple": return (c(200, 128, 255, 0.18), c(218, 179, 255))
            default: return (c(255, 214, 224, 0.10), c(255, 214, 224, 0.4))
            }
        } else {
            switch key {
            case "red": return (c(253, 169, 124, 0.2), c(253, 169, 124))
            case "yellow": return (c(239, 208, 134, 0.2), c(239, 208, 134))
            case "green": return (c(187, 206, 130, 0.2), c(187, 206, 130))
            case "blue": return (c(136, 195, 181, 0.2), c(136, 195, 181))
            case "purple": return (c(219, 165, 171, 0.2), c(219, 165, 171))
            default: return (c(76, 45, 20, 0.102), c(76, 45, 20, 0.4))
            }
        }
    }
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
