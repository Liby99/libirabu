// Curated timezone catalog for the View ▸ Timezone pickers. Mirrors the web app's MAIN_TZS list. "auto"
// tracks the device zone. The main tz drives deadline origin-time labels (see DeadlineTZ.originLabel).

import Foundation

public enum CalendarTimezones {
    public static let autoId = "auto"

    public struct Zone: Identifiable, Sendable, Hashable {
        public let id: String // IANA identifier, or "auto"
        public let label: String
    }

    public static let all: [Zone] = [
        .init(id: "auto", label: "Automatic (Device)"),
        .init(id: "America/Los_Angeles", label: "Los Angeles · Pacific"),
        .init(id: "America/Denver", label: "Denver · Mountain"),
        .init(id: "America/Chicago", label: "Chicago · Central"),
        .init(id: "America/New_York", label: "New York · Eastern"),
        .init(id: "America/Sao_Paulo", label: "São Paulo"),
        .init(id: "Europe/London", label: "London"),
        .init(id: "Europe/Paris", label: "Paris · Berlin"),
        .init(id: "Europe/Athens", label: "Athens · Helsinki"),
        .init(id: "Asia/Dubai", label: "Dubai"),
        .init(id: "Asia/Kolkata", label: "India · IST"),
        .init(id: "Asia/Shanghai", label: "China · CST"),
        .init(id: "Asia/Tokyo", label: "Tokyo · JST"),
        .init(id: "Australia/Sydney", label: "Sydney"),
        .init(id: "Pacific/Auckland", label: "Auckland"),
        .init(id: "UTC", label: "UTC"),
    ]

    public static func label(for id: String) -> String {
        all.first { $0.id == id }?.label ?? id
    }
}
