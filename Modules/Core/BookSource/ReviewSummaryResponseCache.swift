import Foundation

/// Short-lived cache for a source's chapter review summary response.
///
/// The Qidian source asks for the same chapter summary again when a reader reopens
/// a chapter or when the page engine rebuilds the first page. Keeping a successful
/// response for a short reading-session window avoids repeating that network wait,
/// while the expiry keeps counts reasonably fresh. The cache is deliberately scoped
/// by source identity as different sources may use the same endpoint with different
/// authentication and response semantics.
final class ReviewSummaryResponseCache: @unchecked Sendable {

    static let shared = ReviewSummaryResponseCache()

    private struct Entry {
        let body: String
        let expiresAt: TimeInterval
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let lifetime: TimeInterval
    private let maximumEntryCount: Int

    init(lifetime: TimeInterval = 30, maximumEntryCount: Int = 128) {
        self.lifetime = max(1, lifetime)
        self.maximumEntryCount = max(1, maximumEntryCount)
    }

    func value(sourceKey: String, requestURL: String) -> String? {
        let key = makeKey(sourceKey: sourceKey, requestURL: requestURL)
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        guard entry.expiresAt > now else {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry.body
    }

    func insert(_ body: String, sourceKey: String, requestURL: String) {
        let key = makeKey(sourceKey: sourceKey, requestURL: requestURL)
        lock.lock()
        defer { lock.unlock() }
        if entries.count >= maximumEntryCount, entries[key] == nil {
            let oldestKey = entries.min { $0.value.expiresAt < $1.value.expiresAt }?.key
            if let oldestKey { entries.removeValue(forKey: oldestKey) }
        }
        entries[key] = Entry(
            body: body,
            expiresAt: ProcessInfo.processInfo.systemUptime + lifetime
        )
    }

    func removeAll() {
        lock.lock()
        entries.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    private func makeKey(sourceKey: String, requestURL: String) -> String {
        "\(sourceKey.utf8.count)#\(sourceKey)|\(requestURL.utf8.count)#\(requestURL)"
    }
}
