// Colors for the Canvas renderer. Token-driven, light + dark. Approximates the web
// calendar's theme; the shipping version will bridge the real design tokens.

import SwiftUI

struct Theme {
    let dark: Bool

    var bg: Color { dark ? Color(hex: 0x101a2b) : Color(hex: 0xfefcfb) }
    var gridLine: Color { dark ? Color(white: 1, opacity: 0.18) : Color(hex: 0x4c2d14).opacity(0.30) }
    var text: Color { dark ? Color(hex: 0xe9edf4) : Color(hex: 0x2a1c10) }
    var textMuted: Color { dark ? Color(white: 1, opacity: 0.55) : Color(hex: 0x4c2d14).opacity(0.6) }
    var dimFill: Color { dark ? Color(white: 0, opacity: 0.22) : Color(hex: 0x4c2d14).opacity(0.10) }
    var weekendWash: Color { dark ? Color(white: 1, opacity: 0.035) : Color(hex: 0x4c2d14).opacity(0.045) }
    var highlight: Color { dark ? Color(hex: 0xffd6e0) : Color(hex: 0x8a4b1f) }
    var cursor: Color { dark ? Color(hex: 0x6d99ff) : Color(hex: 0x3a6df0) }
    var nowLine: Color { Color(hex: 0xff3b6b) }
    var todayTint: Color { Color(hex: 0xff3b6b) }
    var eventText: Color { dark ? Color(hex: 0x0d1017) : .white }

    /// Event / track palette key → fill color.
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

    /// Faint lane wash for a track row.
    func rowTint(_ key: String?) -> Color { eventColor(key).opacity(dark ? 0.16 : 0.09) }
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
