import Foundation
import Security

// MARK: - KeychainHelper
// Minimal thread-safe wrapper around Keychain Services.
// Used by LoginManager to store sensitive login credentials instead of UserDefaults.

enum KeychainHelper {

    private static let service = "com.yuedu.loginCredentials"

    /// Persist a string value in the Keychain, creating or updating the item as needed.
    @discardableResult
    static func save(account: String, data: String) -> Bool {
        guard let dataBytes = data.data(using: .utf8) else { return false }

        let baseQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        // Try updating an existing item first
        let status = SecItemUpdate(baseQuery as CFDictionary,
                                   [kSecValueData as String: dataBytes] as CFDictionary)
        if status == errSecSuccess { return true }

        // Item not found — add new
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = dataBytes
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    /// Load a previously saved string value from the Keychain. Returns `nil` if not found.
    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    /// Remove an item from the Keychain. Returns `true` if deleted or not found.
    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
