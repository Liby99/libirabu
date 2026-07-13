// Calendar date helpers + label arrays. Weeks are Sunday-aligned. Ported from
// util/dates.ts + model/api/mock.ts.
//
// Ground-truth fidelity note: weekday alignment changes between years, computed
// here with Sakamoto's algorithm (the pure analogue of the TS
// `new Date(year, m, d).getDay()`). Unlike the web's mock.ts (Feb always 28),
// daysInMonth is year-aware so leap years show Feb 29.

import Foundation

public let MONTH_NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
public let MONTH_LONG = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
public let WD = ["S", "M", "T", "W", "T", "F", "S"]           // single-letter weekday
public let WD3 = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
public let WD_LONG = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

/// Track lanes (GridCal palette keys → theme event colors).
public struct Track: Sendable { public let id: Int; public let name: String; public let color: String }
public let TRACKS: [Track] = [
    Track(id: 0, name: "Teaching", color: "red"),
    Track(id: 1, name: "Research", color: "blue"),
    Track(id: 2, name: "Service", color: "yellow"),
    Track(id: 3, name: "Travel", color: "green"),
]

private let DIM = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
public func isLeapYear(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }
public func daysInMonth(_ year: Int, _ month: Int) -> Int {
    (month == 1 && isLeapYear(year)) ? 29 : DIM[month]
}

/// Day-of-week (0 = Sunday) for a Gregorian date. month is 0-based. Sakamoto's algorithm.
public func dayOfWeek(_ year: Int, _ month0: Int, _ day: Int) -> Int {
    let t = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
    var y = year
    let m = month0 + 1
    if m < 3 { y -= 1 }
    return (y + y / 4 - y / 100 + y / 400 + t[m - 1] + day) % 7
}

public func firstDOW(_ year: Int, _ m: Int) -> Int { dayOfWeek(year, m, 1) }  // 0=Sun

/// Day-of-month of a week's Sunday; may be ≤0 or >daysInMonth when it spills over.
public func weekStartDOM(_ year: Int, _ m: Int, _ week: Int) -> Int { 1 - firstDOW(year, m) + week * 7 }

public func weeksInMonth(_ year: Int, _ m: Int) -> Int {
    Int(ceil(Double(firstDOW(year, m) + daysInMonth(year, m)) / 7.0))
}

public func weekOfDate(_ year: Int, _ month: Int, _ day: Int) -> Int {
    (firstDOW(year, month) + day - 1) / 7
}

/// Resolve a (focus month, day-of-month-that-may-spill) into a real {month, day}.
public func resolveDate(_ year: Int, _ focus: Int, _ dom: Int) -> (month: Int, day: Int)? {
    if dom >= 1 && dom <= daysInMonth(year, focus) { return (focus, dom) }
    if dom < 1 {
        let m = focus - 1
        if m < 0 { return nil }
        return (m, daysInMonth(year, m) + dom)
    }
    let m = focus + 1
    if m > 11 { return nil }
    return (m, dom - daysInMonth(year, focus))
}
