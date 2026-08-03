import Foundation
import Security

struct CachedSubscriptionEntitlement: Codable, Equatable {
    let isProActive: Bool
    let expiresAt: Date?

    func isActive(at date: Date = Date()) -> Bool {
        guard isProActive else { return false }
        return expiresAt.map { $0 > date } ?? true
    }
}

/// Last server-verified account entitlement, isolated by Firebase UID *and* by
/// StoreKit environment.
///
/// This keeps previously verified access available when Firebase is unreachable.
/// The environment suffix matters because keychain items outlive the app: without
/// it, a TestFlight install's Sandbox entitlement was still present when an App
/// Store build was installed over the top, and was read straight back as Pro.
enum SubscriptionEntitlementCache {
    private static var service: String {
        "com.zhangruilin.yuedureader.subscriptionEntitlement"
            + SubscriptionRuntimeEnvironment.storageSuffix
    }

    static func load(uid: String) -> CachedSubscriptionEntitlement? {
        guard SubscriptionRuntimeEnvironment.isResolved else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: uid,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(CachedSubscriptionEntitlement.self, from: data)
    }

    @discardableResult
    static func save(_ entitlement: CachedSubscriptionEntitlement, uid: String) -> Bool {
        guard SubscriptionRuntimeEnvironment.isResolved,
              let data = try? JSONEncoder().encode(entitlement) else { return false }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: uid,
        ]
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(uid: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: uid,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
