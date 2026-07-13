// Local JSON persistence for the calendar items, so edits survive a restart without
// a backend. This is an interim store; the sync engine will later reconcile the same
// PersistedState shape with the server.

import Foundation
import CalendarGeometry

public struct PersistedState: Codable, Sendable {
    public var events: [TimedEvent]
    public var bands: [BandEvent]
    public var deadlines: [Deadline]
    public var trackNames: [String]?   // optional for backward compat with older saves
}

struct ItemStore {
    private let url: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("CalendarKit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("data.json")
    }

    func load() -> PersistedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    func save(_ state: PersistedState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
