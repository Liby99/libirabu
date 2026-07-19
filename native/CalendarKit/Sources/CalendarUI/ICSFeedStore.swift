// The subscribed ICS feed URLs (Google Calendar "secret addresses" etc.), stored as a JSON
// array in ONE Keychain item — the secret URL *is* the credential (anyone holding it can read
// that calendar), so it never touches UserDefaults. The engine gets the list via a closure
// (CalendarEngine.icsFeedURLs) and never reads the Keychain itself.

import CalendarEngine
import Foundation

enum ICSFeeds {
    static let keychainAccount = "ics-feed-urls"

    static func list() -> [String] {
        guard let raw = Keychain.get(account: keychainAccount),
              let urls = try? JSONDecoder().decode([String].self, from: Data(raw.utf8)) else { return [] }
        return urls
    }

    static func save(_ urls: [String]) {
        let cleaned = urls.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if let data = try? JSONEncoder().encode(cleaned) {
            _ = Keychain.set(String(decoding: data, as: UTF8.self), account: keychainAccount)
        }
        NotificationCenter.default.post(name: .icsFeedsChanged, object: nil)
    }

    static func add(_ url: String) {
        var urls = list()
        let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !urls.contains(clean) else { return }
        urls.append(clean)
        save(urls)
    }

    static func remove(_ url: String) {
        save(list().filter { $0 != url })
    }

    /// A privacy-friendly display form of a secret URL: host + a stable short key.
    static func displayName(_ url: String) -> String {
        let host = URL(string: url)?.host ?? "feed"
        return "\(host) · \(ICSFeedKey.feedKey(url))"
    }
}
