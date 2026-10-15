// Multiple calendars ("documents"). Each calendar is a disjoint MagnifiCal with its own on-disk store
// (calendars/<id>/); exactly one is active at a time, and opening one shows only its content. The list
// of calendars persists to calendars.json; the active id + recently-opened list are per-device
// (UserDefaults). A pre-multi-calendar install (one data.json at the root) is migrated into a "Main"
// calendar on first run, so existing data + iCloud state carry over untouched.

import Foundation

/// One calendar's identity. `id` is stable and names its data directory; `name` is the user-facing label.
public struct CalendarMeta: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public var name: String
    public let createdAt: Date
    public var order: Int
    public init(id: String, name: String, createdAt: Date, order: Int) {
        self.id = id; self.name = name; self.createdAt = createdAt; self.order = order
    }
}

struct CalendarRegistry {
    /// The default "Main" calendar's FIXED id (see bootstrap). Main is the anchor calendar:
    /// it maps every device to the same iCloud zone and can never be removed.
    static let mainId = PrefKeys.mainCalendarId

    private let registryURL: URL
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        registryURL = calendarKitBaseDir().appendingPathComponent("calendars.json")
        self.defaults = defaults
        bootstrap()
    }

    /// ── calendars.json ────────────────────────────────────────────────────────────────────────────
    private func load() -> [CalendarMeta] {
        guard let data = try? Data(contentsOf: registryURL),
              let list = try? JSONDecoder().decode([CalendarMeta].self, from: data) else { return [] }
        return list.sorted { $0.order < $1.order }
    }

    private func save(_ list: [CalendarMeta]) {
        try? FileManager.default.createDirectory(at: calendarKitBaseDir(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: registryURL, options: .atomic)
        }
    }

    /// ── Bootstrap / one-time migration ──────────────────────────────────────────────────────────────
    /// Guarantee at least one calendar ("Main") and a valid active id. Idempotent.
    private func bootstrap() {
        var list = load()
        if list.isEmpty {
            // The default "Main" uses a FIXED id so every device's Main maps to the same iCloud zone and
            // reconciles (a per-device UUID would fork Main into disjoint zones). Calendars the user creates
            // later get UUID ids, minted once and propagated to other devices via the synced registry.
            let main = CalendarMeta(id: Self.mainId, name: "Main", createdAt: Date(), order: 0)
            migrateLegacyStore(into: main.id)
            migrateLegacyAppleKeys(into: main.id)
            save([main])
            defaults.set(main.id, forKey: PrefKeys.calActiveId)
            list = [main]
        }
        if list.first(where: { $0.id == rawActiveId }) == nil {
            defaults.set(list.first!.id, forKey: PrefKeys.calActiveId)
        }
        // Heal pre-existing duplicate names (lists written before uniqueness was enforced —
        // e.g. an adopted cloud "Main" beside the bootstrap "Main"): keep the first of each
        // name in display order, suffix the rest. Local-only, idempotent.
        var seen = Set<String>(), healed = list, changed = false
        for i in healed.indices {
            let fixed = uniqueNameAmong(healed[i].name, taken: seen)
            if fixed != healed[i].name {
                healed[i].name = fixed; changed = true
            }
            seen.insert(fixed.lowercased())
        }
        if changed {
            save(healed)
        }
    }

    /// A pre-multi-calendar install kept its data.json at the CalendarKit root. Move it into Main's dir.
    /// The old iCloud sync state (syncState.bin / records.plist) is NOT carried over — it referenced the
    /// legacy single "Calendar" zone, whereas Main now syncs to its own zone; Main re-pushes its (migrated,
    /// intact) local data to the new zone on first sync. Delete the stale files so they don't linger.
    private func migrateLegacyStore(into id: String) {
        let base = calendarKitBaseDir()
        let dst = calendarDir(id)
        let fm = FileManager.default
        try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
        let legacyData = base.appendingPathComponent("data.json")
        if fm.fileExists(atPath: legacyData.path) {
            try? fm.moveItem(at: legacyData, to: dst.appendingPathComponent("data.json"))
        }
        for stale in ["syncState.bin", "records.plist"] {
            try? fm.removeItem(at: base.appendingPathComponent(stale))
        }
    }

    /// Carry a pre-multi-calendar install's Apple subscription (global keys) into Main's per-calendar keys.
    private func migrateLegacyAppleKeys(into id: String) {
        if defaults.object(forKey: PrefKeys.legacyAppleEnabled) != nil {
            defaults.set(defaults.bool(forKey: PrefKeys.legacyAppleEnabled), forKey: PrefKeys.appleEnabled(id))
        }
        if let ids = defaults.stringArray(forKey: PrefKeys.legacyAppleCalendars) {
            defaults.set(ids, forKey: PrefKeys.appleCalendars(id))
        }
    }

    private func newId() -> String {
        "cal-" + UUID().uuidString.prefix(8).lowercased()
    }

    /// ── Queries ─────────────────────────────────────────────────────────────────────────────────────
    var all: [CalendarMeta] {
        load()
    }

    func meta(_ id: String) -> CalendarMeta? {
        load().first { $0.id == id }
    }

    private var rawActiveId: String? {
        defaults.string(forKey: PrefKeys.calActiveId)
    }

    /// The active calendar id (always valid after bootstrap).
    var activeId: String {
        rawActiveId ?? load().first?.id ?? ""
    }

    func setActive(_ id: String) {
        defaults.set(id, forKey: PrefKeys.calActiveId); touchRecent(id)
    }

    /// ── Name uniqueness ───────────────────────────────────────────────────────────────────────────
    /// Calendar NAMES are unique (ids are the real identity, but two calendars both called
    /// "Main" — e.g. the bootstrap default beside an adopted cloud primary — are
    /// indistinguishable in every picker). `proposed` comes back untouched when free, else
    /// suffixed with the lowest free counter ("Main 2", "Main 3", …).
    private func uniqueName(_ proposed: String, in list: [CalendarMeta], excluding id: String) -> String {
        uniqueNameAmong(proposed, taken: Set(list.filter { $0.id != id }.map { $0.name.lowercased() }))
    }

    private func uniqueNameAmong(_ proposed: String, taken: Set<String>) -> String {
        let base = proposed.trimmingCharacters(in: .whitespaces)
        if !taken.contains(base.lowercased()) {
            return base
        }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) {
            n += 1
        }
        return "\(base) \(n)"
    }

    /// ── Mutations ─────────────────────────────────────────────────────────────────────────────────
    func create(name: String) -> CalendarMeta {
        var list = load()
        let order = (list.map(\.order).max() ?? -1) + 1
        let m = CalendarMeta(id: newId(), name: uniqueName(name, in: list, excluding: ""),
                             createdAt: Date(), order: order)
        list.append(m); save(list)
        return m
    }

    func rename(_ id: String, to name: String) {
        var list = load()
        if let i = list.firstIndex(where: { $0.id == id }) {
            list[i].name = uniqueName(name, in: list, excluding: id); save(list)
        }
    }

    /// Insert-or-update a calendar entry from a remote (synced) source — last-writer-wins on name/order.
    /// Does NOT touch on-disk data (that syncs via the calendar's own zone when opened). A name that
    /// collides with a DIFFERENT local calendar's is suffixed locally (display-side only — inbound
    /// applies never enqueue an outbound write, so the cloud copy keeps its own name).
    func upsertRemote(_ meta: CalendarMeta) {
        var list = load()
        var m = meta
        m.name = uniqueName(meta.name, in: list, excluding: meta.id)
        if let i = list.firstIndex(where: { $0.id == m.id }) {
            list[i] = m
        } else {
            list.append(m)
        }
        save(list)
    }

    /// Remove a calendar from the registry AND delete its on-disk data. Caller must have switched away
    /// first (never remove the active calendar's dir out from under a live engine).
    func remove(_ id: String) {
        save(load().filter { $0.id != id })
        try? FileManager.default.removeItem(at: calendarDir(id))
        setRecents(recentIds.filter { $0 != id })
    }

    /// ── Recently opened (per device) ────────────────────────────────────────────────────────────────
    private var recentIds: [String] {
        defaults.stringArray(forKey: PrefKeys.calRecents) ?? []
    }

    private func setRecents(_ ids: [String]) {
        defaults.set(ids, forKey: PrefKeys.calRecents)
    }

    func touchRecent(_ id: String) {
        setRecents(Array(([id] + recentIds.filter { $0 != id }).prefix(12)))
    }

    /// Recently-opened calendars OTHER than `active`, most-recent-first, existing only.
    func recents(excluding active: String, limit: Int = 10) -> [CalendarMeta] {
        let byId = Dictionary(load().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return recentIds.filter { $0 != active }.compactMap { byId[$0] }.prefix(limit).map { $0 }
    }
}
