// Colors for the calendar. Structural colors (background, text, lines/borders) come
// straight from the macOS system palette so the app matches the OS light/dark theme
// automatically — a near-black/dark-gray content background with white-to-light-gray
// lines in dark mode, and the mirror in light mode. Only two things are colored: the
// event stickers (their own palette) and the red now/today accent.

import SwiftUI
import AppKit

struct Theme {
    let dark: Bool   // only affects the event palette; structural colors are system-native

    private var label: Color { Color(nsColor: .labelColor) }   // white in dark, near-black in light

    var bg: Color { Color(nsColor: .textBackgroundColor) }     // content background (near-black / white)

    var accentDark: Color { label }                            // strong lines / text
    var accentGrey: Color { label.opacity(0.28) }              // faint gray
    var sep: Color { label.opacity(0.28) }                     // solid separators (dimmed)

    var text: Color { label }                                  // labels
    var textMuted: Color { Color(nsColor: .secondaryLabelColor) } // day labels

    var gridLine: Color { label.opacity(0.35) }                // solid gridlines
    var cellGrid: Color { label.opacity(0.16) }                // dotted day-cell verticals + lane separators

    var dimFill: Color { label.opacity(0.09) }
    var weekendWash: Color { label.opacity(0.045) }
    var highlight: Color { label }                             // hover wash (item opacity is tiny)
    var cursor: Color { label.opacity(0.6) }
    var nowLine: Color { Color(hex: 0xff3b6b) }                // red accent (kept)
    var todayTint: Color { Color(hex: 0xff3b6b, opacity: 0.07) }

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
