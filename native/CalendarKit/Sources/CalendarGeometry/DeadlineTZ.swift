// Deadline origin-timezone display — a port of the web's tz helpers (lib/calendar/api.ts).
//
// A deadline's `hour` is stored in the user's MAIN timezone; a CfP is often *given* in another
// zone ("AOE 23:59"). We keep that origin zone on the deadline and derive the origin-tz time for
// display: "AOE 23:59" alongside the main-tz "18:59". Conversion is DST-aware via Foundation's
// TimeZone. Two pseudo-ids: "AOE" (Anywhere on Earth = UTC-12 → Etc/GMT+12) and "auto" (the main
// tz sentinel → the device's current zone).

import Foundation

public enum DeadlineTZ {
    /// Resolve a stored tz id to a concrete IANA zone. "auto" → device zone; "AOE" → Etc/GMT+12.
    public static func iana(_ tz: String) -> String {
        if tz == "auto" { return TimeZone.current.identifier }
        if tz == "AOE" { return "Etc/GMT+12" }
        return tz
    }
    /// Short abbreviation shown in the "(ABBR HH:MM)" part; "AOE" keeps its own label.
    public static func shortLabel(_ tz: String, at date: Date) -> String {
        if tz == "AOE" { return "AOE" }
        let z = TimeZone(identifier: iana(tz)) ?? .gmt
        return z.abbreviation(for: date) ?? tz
    }
    private static func offset(_ tz: String, at date: Date) -> Int {
        (TimeZone(identifier: iana(tz)) ?? .gmt).secondsFromGMT(for: date)
    }

    private static let utcCal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()
    /// The floating wall-clock (y, m0, d, fractional hour) as a UTC-encoded instant — matching the
    /// web's parseWallClock: the string is treated as if it were UTC so only y/m/d/h/m are meaningful.
    private static func utcInstant(_ y: Int, _ m0: Int, _ d: Int, _ hour: CGFloat) -> Date {
        let h = Int(hour), mi = Int((hour - CGFloat(h)) * 60 + 0.5)
        return utcCal.date(from: DateComponents(year: y, month: m0 + 1, day: d, hour: h, minute: mi)) ?? Date(timeIntervalSince1970: 0)
    }

    /// The deadline's time re-expressed in its origin timezone, as "ABBR HH:MM" (e.g. "AOE 23:59").
    /// nil when the deadline has no distinct origin tz. `mainTz` is where `hour` is expressed.
    public static func originLabel(_ d: Deadline, mainTz: String) -> String? {
        guard let otz = d.originTz, otz != mainTz else { return nil }
        let base = utcInstant(d.year, d.month, d.day, d.hour)   // main-tz wall clock, UTC-encoded
        // Same instant, re-expressed in the origin zone: shift by the offset delta (same trick the web uses).
        let shifted = base.addingTimeInterval(Double(offset(otz, at: base) - offset(mainTz, at: base)))
        let c = utcCal.dateComponents([.hour, .minute], from: shifted)
        return String(format: "%@ %02d:%02d", shortLabel(otz, at: base), c.hour ?? 0, c.minute ?? 0)
    }
}
