import Foundation
import Security

/// The key that owns this person's 回饋中心 threads.
///
/// There is no sign-in: the key is 32 random bytes, base64url (43 characters), and knowing
/// it is what lets a client read the inbox (firestore.rules, storage.rules). It lives in
/// iCloud Keychain, so a reinstall or a new iPhone on the same Apple Account still sees its
/// earlier reports and their replies; it never touches the app's account system.
enum FeedbackInbox {
    private static let service = "com.yuedu.feedbackInbox"
    private static let account = "inboxKey"

    /// Read once per launch: the Keychain call is not free and the key never changes.
    nonisolated(unsafe) private static var cached: String?
    private static let lock = NSLock()

    static var key: String {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        if let stored = KeychainHelper.load(account: account, service: service, synchronizable: true),
           isValid(stored) {
            cached = stored
            return stored
        }
        let created = makeKey()
        // A key that cannot be stored still works for this launch; the failure is logged by
        // KeychainHelper, and the next launch makes a new inbox. Earlier threads would be
        // unreachable then, which is why the failure must be visible in diagnostics.
        if !KeychainHelper.save(
            account: account,
            data: created,
            service: service,
            accessibility: kSecAttrAccessibleAfterFirstUnlock,
            synchronizable: true
        ) {
            AppLogger.anomaly("Feedback inbox key could not be saved to the Keychain", category: .sync)
        }
        cached = created
        return created
    }

    static func isValid(_ key: String) -> Bool {
        key.count == 43 && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func makeKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
