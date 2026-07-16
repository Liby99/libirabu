// Local, secure storage for API keys. Secrets don't belong in UserDefaults/JSON, so they go
// into the macOS Keychain as generic-password items. `kSecAttrAccessibleWhenUnlocked` keeps
// them on THIS device only (not the synchronizable iCloud keychain) — matching the intent that
// API keys stay local and unsynced, unlike the appearance preference.
//
// Works out of the box in the signed app (it uses the app's default keychain access group). The
// unsigned CalendarMac dev binary may prompt for login-keychain access the first time.

import Foundation
import Security

enum Keychain {
    /// Namespaces our items so they don't collide with anything else in the login keychain.
    private static let service = "dev.libirabu.calendar.apikeys"

    /// Store (or, for a nil/empty value, remove) the secret for `account`. Returns success.
    @discardableResult
    static func set(_ value: String?, account: String) -> Bool {
        guard let value, !value.isEmpty else { return delete(account: account) }
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let status = SecItemUpdate(match as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            return SecItemAdd(match.merging(update) { _, new in new } as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    /// The stored secret for `account`, or nil if none.
    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
