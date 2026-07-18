// Minimal RFC-5545 (.ics) importer. The web app parses .ics server-side with the `node-ical` library
// (src/lib/import/ical.ts) then normalizes (src/lib/import/normalize.ts); this is a focused native port
// of the field mapping + kind decisions for the common cases:
//   • all-day (VALUE=DATE), single or multi-day        → band (DTEND is exclusive → inclusive last day)
//   • timed on one day                                  → timed event
//   • timed spanning multiple days                      → promoted to a band over the day span
//   • never a deadline (imports don't create deadlines, matching normalize.ts)
// Vendor extras (LOCATION / ORGANIZER / ATTENDEE / DESCRIPTION / URL) go into a managed-note block
// (ManagedNote), exactly like the Apple Calendar import. Timed instants are resolved to the device's
// local wall-clock (the app's floating-time convention; the web uses the user's main tz = "auto").

import Foundation
import CalendarGeometry

public enum ICSImport {
    /// Parse `.ics` text into native seed items. `provenance` is a short source label (usually the file
    /// name) shown in the managed-note block. Returns items keyed for `CalendarEngine.importItems`.
    public static func items(from text: String, provenance: String)
        -> (events: [TimedEvent], bands: [BandEvent], rich: [String: RichFields]) {
        var events: [TimedEvent] = [], bands: [BandEvent] = []
        var rich: [String: RichFields] = [:]
        for ve in vevents(in: text) {
            guard let s = ve.start else { continue }   // skip timeless rows (matches node-ical guard)
            let title = ve.summary.isEmpty ? "(untitled)" : ve.summary
            let color = "default"
            let block = ManagedNote.render(
                provenance: "iCal · \(provenance)",
                meetingUrl: ve.url, location: ve.location, organizer: ve.organizer,
                attendees: ve.attendees.map { ($0.name, $0.status ?? "") }, description: ve.description)
            let notes = block.isEmpty ? nil : block

            if s.allDay {
                // Inclusive last day: DTEND is exclusive in iCal, so subtract a day; none → single day.
                let endExclusive = ve.end
                let last = endExclusive.map { addDays($0, -1) } ?? s
                let lastClamped = (ymd(last) < ymd(s)) ? s : last
                for seg in bandSegments(from: s, to: lastClamped) {
                    let id = "ics-\(UUID().uuidString)"
                    bands.append(BandEvent(id: id, year: seg.year, month: seg.month, track: 0,
                                           startDay: seg.startDay, endDay: seg.endDay, title: title, color: color))
                    rich[id] = importedRich(notes)
                }
            } else if let e = ve.end, ymd(e) != ymd(s) {
                // Multi-day timed → promoted to an all-day band over the span (normalize.ts).
                for seg in bandSegments(from: s, to: e) {
                    let id = "ics-\(UUID().uuidString)"
                    bands.append(BandEvent(id: id, year: seg.year, month: seg.month, track: 0,
                                           startDay: seg.startDay, endDay: seg.endDay, title: title, color: color))
                    rich[id] = importedRich(notes)
                }
            } else {
                // Single-day timed event.
                let e = ve.end ?? s
                let id = "ics-\(UUID().uuidString)"
                events.append(TimedEvent(id: id, year: s.year, month: s.month, day: s.day,
                                         startHour: hourOf(s), endHour: max(hourOf(s), hourOf(e)),
                                         title: title, color: color, anchorTz: DeadlineTZ.concrete("auto")))   // parsed into device-local wall-clock
                rich[id] = importedRich(notes)
            }
        }
        return (events, bands, rich)
    }

    private static func importedRich(_ notes: String?) -> RichFields {
        RichFields(notes: notes, tags: ["imported"], source: "ical")
    }

    // ── Wall-clock model ──────────────────────────────────────────────────────────────
    /// A resolved date/time in the device's local wall clock. `allDay` drops the time.
    private struct WC { var year, month, day, hour, minute: Int; var allDay: Bool }
    private static func ymd(_ w: WC) -> Int { w.year * 10000 + w.month * 100 + w.day }
    private static func hourOf(_ w: WC) -> CGFloat { CGFloat(w.hour) + CGFloat(w.minute) / 60 }
    private static func addDays(_ w: WC, _ n: Int) -> WC {
        var c = DateComponents(); c.year = w.year; c.month = w.month; c.day = w.day
        let cal = utcCalendar
        guard let base = cal.date(from: c), let moved = cal.date(byAdding: .day, value: n, to: base) else { return w }
        let d = cal.dateComponents([.year, .month, .day], from: moved)
        return WC(year: d.year ?? w.year, month: d.month ?? w.month, day: d.day ?? w.day, hour: w.hour, minute: w.minute, allDay: w.allDay)
    }

    // ── VEVENT extraction ─────────────────────────────────────────────────────────────
    private struct VEvent {
        var summary = "", location: String? = nil, organizer: String? = nil, url: String? = nil, description: String? = nil
        var start: WC? = nil, end: WC? = nil
        var attendees: [(name: String, status: String?)] = []
    }

    private static func vevents(in text: String) -> [VEvent] {
        let lines = unfold(text)
        var out: [VEvent] = [], cur: VEvent? = nil
        for line in lines {
            let upper = line.uppercased()
            if upper == "BEGIN:VEVENT" { cur = VEvent(); continue }
            if upper == "END:VEVENT" { if let c = cur { out.append(c) }; cur = nil; continue }
            guard var event = cur, let (name, params, value) = property(line) else { continue }
            switch name {
            case "SUMMARY":     event.summary = unescapeText(value)
            case "LOCATION":    event.location = unescapeText(value).isEmpty ? nil : unescapeText(value)
            case "DESCRIPTION": event.description = unescapeText(value).isEmpty ? nil : unescapeText(value)
            case "URL":         event.url = value.isEmpty ? nil : value
            case "ORGANIZER":   event.organizer = displayName(params: params, value: value)
            case "ATTENDEE":    if let a = displayName(params: params, value: value) { event.attendees.append((a, params["PARTSTAT"])) }
            case "DTSTART":     event.start = parseDT(value: value, params: params)
            case "DTEND":       event.end = parseDT(value: value, params: params)
            default: break
            }
            cur = event
        }
        return out
    }

    /// Join RFC-5545 folded continuation lines (a leading space/tab continues the previous line).
    private static func unfold(_ text: String) -> [String] {
        let raw = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        var out: [String] = []
        for piece in raw {
            let s = String(piece)
            if let first = s.first, (first == " " || first == "\t"), !out.isEmpty {
                out[out.count - 1] += String(s.dropFirst())
            } else { out.append(s) }
        }
        return out
    }

    /// Split "NAME;PARAM=VAL;...:value" → (NAME uppercased, params, value). First ':' ends the name+params.
    private static func property(_ line: String) -> (name: String, params: [String: String], value: String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let left = String(line[line.startIndex..<colon])
        let value = String(line[line.index(after: colon)...])
        let parts = left.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard let name = parts.first?.uppercased() else { return nil }
        var params: [String: String] = [:]
        for p in parts.dropFirst() {
            if let eq = p.firstIndex(of: "=") {
                params[String(p[p.startIndex..<eq]).uppercased()] = String(p[p.index(after: eq)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return (name, params, value)
    }

    /// ORGANIZER/ATTENDEE: prefer the CN= parameter, else the mailto: address local part.
    private static func displayName(params: [String: String], value: String) -> String? {
        if let cn = params["CN"], !cn.isEmpty { return cn }
        let v = value.hasPrefix("mailto:") || value.hasPrefix("MAILTO:") ? String(value.dropFirst(7)) : value
        return v.isEmpty ? nil : v
    }

    /// Parse a DTSTART/DTEND value into a device-local wall clock. Handles VALUE=DATE (all-day),
    /// UTC ("…Z"), TZID=<zone>, and floating date-times.
    private static func parseDT(value: String, params: [String: String]) -> WC? {
        let v = value.trimmingCharacters(in: .whitespaces)
        // All-day: VALUE=DATE, or a bare 8-digit date.
        if params["VALUE"] == "DATE" || (v.count == 8 && !v.contains("T")) {
            guard v.count >= 8, let y = Int(v.prefix(4)), let mo = Int(v.dropFirst(4).prefix(2)), let d = Int(v.dropFirst(6).prefix(2)) else { return nil }
            return WC(year: y, month: mo, day: d, hour: 0, minute: 0, allDay: true)
        }
        // Date-time: YYYYMMDD 'T' HHMMSS ['Z'].
        let core = v.hasSuffix("Z") ? String(v.dropLast()) : v
        let halves = core.split(separator: "T", maxSplits: 1).map(String.init)
        guard halves.count == 2, halves[0].count >= 8, halves[1].count >= 4,
              let y = Int(halves[0].prefix(4)), let mo = Int(halves[0].dropFirst(4).prefix(2)), let d = Int(halves[0].dropFirst(6).prefix(2)),
              let h = Int(halves[1].prefix(2)), let mi = Int(halves[1].dropFirst(2).prefix(2)) else { return nil }
        // Floating (no Z, no TZID) → the numbers ARE the wall clock. Otherwise resolve the instant in its
        // source zone and re-read it in the device zone.
        let isUTC = v.hasSuffix("Z")
        let tzid = params["TZID"]
        if !isUTC && tzid == nil {
            return WC(year: y, month: mo, day: d, hour: h, minute: mi, allDay: false)
        }
        var src = DateComponents(); src.year = y; src.month = mo; src.day = d; src.hour = h; src.minute = mi
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = isUTC ? utcTimeZone : (tzid.flatMap { TimeZone(identifier: $0) } ?? utcTimeZone)
        guard let instant = cal.date(from: src) else {
            return WC(year: y, month: mo, day: d, hour: h, minute: mi, allDay: false)
        }
        let lc = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: instant)
        return WC(year: lc.year ?? y, month: lc.month ?? mo, day: lc.day ?? d, hour: lc.hour ?? h, minute: lc.minute ?? mi, allDay: false)
    }

    private static func unescapeText(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\N", with: "\n")
        out = out.replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\;", with: ";")
        out = out.replacingOccurrences(of: "\\\\", with: "\\")
        return out
    }

    // ── Band segmentation ───────────────────────────────────────────────────────────
    /// Split an inclusive [start, end] day span into one band segment per calendar month (native bands
    /// live in a single month), clamped to each month's day range — mirrors CalendarEngine.createBandSpan.
    private struct Seg { var year, month, startDay, endDay: Int }
    private static func bandSegments(from start: WC, to end: WC) -> [Seg] {
        var (sy, sm, sd) = (start.year, start.month, start.day)
        var (ey, em, ed) = (end.year, end.month, end.day)
        if (ey, em, ed) < (sy, sm, sd) { swap(&sy, &ey); swap(&sm, &em); swap(&sd, &ed) }
        var out: [Seg] = []
        var (y, m) = (sy, sm)
        var guardN = 0
        while (y, m) <= (ey, em), guardN < 480 {
            guardN += 1
            let dim = daysInMonth(y, m - 1)   // daysInMonth uses 0-based month
            let first = (y == sy && m == sm) ? sd : 1
            let lastD = (y == ey && m == em) ? ed : dim
            out.append(Seg(year: y, month: m - 1, startDay: max(1, min(dim, first)), endDay: max(1, min(dim, lastD))))
            m += 1; if m > 12 { m = 1; y += 1 }
        }
        return out
    }
}
