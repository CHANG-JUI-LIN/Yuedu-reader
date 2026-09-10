import Foundation
import Security

// MARK: - KeychainHelper
// Minimal thread-safe wrapper around Keychain Services.
// Used by LoginManager to store sensitive login credentials instead of UserDefaults.

enum KeychainHelper {

    private static let service = "com.yuedu.loginCredentials"

    /// Persist a string value in the Keychain, creating or updating the item as needed.
    @discardableResult
    static func save(account: String, data: String, accessibility: CFString? = nil) -> Bool {
        guard let dataBytes = data.data(using: .utf8) else { return false }

        let baseQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        var attributes: [String: Any] = [kSecValueData as String: dataBytes]
        if let accessibility {
            attributes[kSecAttrAccessible as String] = accessibility
        }
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else {
            logFailure(operation: "update", status: status)
            return false
        }

        // Item not found — add new
        var addQuery = baseQuery
        addQuery.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess { logFailure(operation: "add", status: addStatus) }
        return addStatus == errSecSuccess
    }

    /// Load a previously saved string value from the Keychain. Returns `nil` if not found.
    static func load(account: String, accessibility: CFString? = nil) -> String? {
        let baseQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var query = baseQuery
        query.merge([
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]) { _, new in new }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound { logFailure(operation: "read", status: status) }
            return nil
        }
        guard let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }

        // Existing installations already have WhenUnlocked items. Migrate their protection
        // while the item is readable, before the listener locks the device. Update only the
        // attribute: writing the value we just read could overwrite a concurrent login edit.
        if let accessibility,
           item[kSecAttrAccessible as String] as? String != accessibility as String {
            let migrationStatus = SecItemUpdate(
                baseQuery as CFDictionary,
                [kSecAttrAccessible as String: accessibility] as CFDictionary
            )
            if migrationStatus != errSecSuccess {
                logFailure(operation: "accessibility migration", status: migrationStatus)
            }
        }
        return str
    }

    private static func logFailure(operation: String, status: OSStatus) {
        // Neither the account (which may contain a source URL) nor credential values belong
        // in diagnostics. Preserve the status so locked data isn't mistaken for no login.
        AppLogger.error("Keychain operation failed", context: [
            "operation": operation,
            "status": status,
        ])
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
