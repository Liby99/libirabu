// ICS feed subscriptions — "Connect Google Calendar" path 2: the user pastes a calendar's
// SECRET iCal address (Google: Settings ▸ [calendar] ▸ Integrate calendar ▸ "Secret address in
// iCal format") and we periodically fetch + merge it as READ-ONLY imported items, exactly like
// the Apple Calendar import (same imported bucket, provenance badges, hide/color overlays).
// No OAuth: the secret URL itself is the credential, so it lives in the KEYCHAIN.

import CalendarGeometry
import CryptoKit
import Foundation

public extension Notification.Name {
    /// Posted by Settings when the feed list changes → re-import.
    static let icsFeedsChanged = Notification.Name("cc.icsFeeds.changed")
}

/// Stable 10-hex key for a feed URL — the id-prefix its items live under. (The URL list itself
/// is stored UI-side in the Keychain — see ICSFeeds in CalendarUI — and passed in.)
public enum ICSFeedKey {
    public static func feedKey(_ url: String) -> String {
        let digest = SHA256.hash(data: Data(url.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        return digest.prefix(5).map { String(format: "%02x", $0) }.joined()
    }
}

extension CalendarEngine {
    /// Fetch every subscribed feed and merge it into the read-only imported bucket. Each feed
    /// replaces ONLY its own contribution (id prefix "gcal-<feedKey>-"); Apple-imported items and
    /// other feeds are untouched. Failures leave the previous contribution in place.
    public func importICSFeeds(urls: [String]) {
        guard !Self.isDemoMode else { return } // recording sessions never touch personal data
        // Prune contributions of feeds that were removed.
        let liveKeys = Set(urls.map { "gcal-\(ICSFeedKey.feedKey($0))-" })
        let stale = imported.events.contains { id in
            id.id.hasPrefix("gcal-") && !liveKeys.contains(where: { id.id.hasPrefix($0) })
        } || imported.bands.contains { b in
            b.id.hasPrefix("gcal-") && !liveKeys.contains(where: { b.id.hasPrefix($0) })
        }
        if stale {
            imported.events
                .removeAll { e in e.id.hasPrefix("gcal-") && !liveKeys.contains(where: { e.id.hasPrefix($0) }) }
            imported.bands
                .removeAll { b in b.id.hasPrefix("gcal-") && !liveKeys.contains(where: { b.id.hasPrefix($0) }) }
            caches.editGen &+= 1; caches.deadlineGen &+= 1; wake()
        }
        guard !urls.isEmpty else { return }
        let window = (year - 1) ... (year + 2)
        Task { [weak self] in
            for url in urls {
                guard let u = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
                      u.scheme?.hasPrefix("http") == true else { continue }
                guard let (data, resp) = try? await URLSession.shared.data(from: u),
                      (200 ... 299).contains((resp as? HTTPURLResponse)?.statusCode ?? 0),
                      let text = String(data: data, encoding: .utf8) else { continue }
                let key = ICSFeedKey.feedKey(url)
                let parsed = ICSImport.feedItems(from: text, feedKey: key, years: window)
                await MainActor.run { [weak self] in
                    self?.mergeFeed(key: key, events: parsed.events, bands: parsed.bands, rich: parsed.rich)
                }
            }
        }
    }

    private func mergeFeed(key: String, events: [TimedEvent], bands: [BandEvent], rich: [String: RichFields]) {
        let prefix = "gcal-\(key)-"
        imported.events.removeAll { $0.id.hasPrefix(prefix) }
        imported.bands.removeAll { $0.id.hasPrefix(prefix) }
        imported.events += events
        imported.bands += bands
        // Series notes/tags: attach only when the user hasn't already an overlay for the series —
        // their color/hide/note edits survive refetches.
        for (k, v) in rich where items.richById[k] == nil {
            items.richById[k] = v
        }
        caches.editGen &+= 1; caches.deadlineGen &+= 1
        wake()
        onExternalDataChange?() // a refresh may have removed an open item
    }
}
