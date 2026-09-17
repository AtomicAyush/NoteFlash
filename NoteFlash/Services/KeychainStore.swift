import Foundation
import Security

nonisolated enum KeychainKey: String, Sendable {
    case anthropicAPIKey = "anthropic-api-key"
    case googleTokens = "google-oauth-tokens"
}

/// Small wrapper around generic-password Keychain items.
/// Items stay readable after first unlock so background doc syncs can use them.
nonisolated enum KeychainStore {
    private static let service = "com.ayushkansal.NoteFlash"

    static func data(for key: KeychainKey) -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func string(for key: KeychainKey) -> String? {
        data(for: key).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func set(_ data: Data?, for key: KeychainKey) {
        let query = baseQuery(for: key)
        guard let data else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    static func set(_ string: String?, for key: KeychainKey) {
        set(string.map { Data($0.utf8) }, for: key)
    }

    private static func baseQuery(for key: KeychainKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }
}
