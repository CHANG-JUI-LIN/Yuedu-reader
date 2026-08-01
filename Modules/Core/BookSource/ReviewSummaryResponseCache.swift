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

    private final class InFlight {
        let group = DispatchGroup()

        init() {
            group.enter()
        }
    }

    enum RequestState: Equatable {
        case cached(String)
        case inFlight
        case owner
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: InFlight] = [:]
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

    /// Claims a request slot so a prefetch and the source's synchronous JS request share one
    /// response instead of opening two identical connections.
    func beginRequest(sourceKey: String, requestURL: String) -> RequestState {
        let key = makeKey(sourceKey: sourceKey, requestURL: requestURL)
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        if let entry = entries[key] {
            if entry.expiresAt > now {
                return .cached(entry.body)
            }
            entries.removeValue(forKey: key)
        }
        if inFlight[key] != nil {
            return .inFlight
        }
        inFlight[key] = InFlight()
        return .owner
    }

    /// Waits only when another caller already owns this exact request. The JS bridge uses this
    /// on its dedicated serial queue, never on the main actor.
    func waitForRequest(
        sourceKey: String,
        requestURL: String,
        timeout: TimeInterval = 30
    ) -> String? {
        let key = makeKey(sourceKey: sourceKey, requestURL: requestURL)
        lock.lock()
        let group = inFlight[key]?.group
        lock.unlock()
        guard let group else { return value(sourceKey: sourceKey, requestURL: requestURL) }
        guard group.wait(timeout: .now() + timeout) == .success else { return nil }
        return value(sourceKey: sourceKey, requestURL: requestURL)
    }

    /// Completes an owned request and wakes any source JS call waiting on it. Invalid responses
    /// still complete the slot so a failed request cannot poison the cache forever.
    func finishRequest(
        _ body: String?,
        sourceKey: String,
        requestURL: String
    ) {
        let key = makeKey(sourceKey: sourceKey, requestURL: requestURL)
        lock.lock()
        let flight = inFlight.removeValue(forKey: key)
        if let body, !body.isEmpty {
            if entries.count >= maximumEntryCount, entries[key] == nil {
                let oldestKey = entries.min { $0.value.expiresAt < $1.value.expiresAt }?.key
                if let oldestKey { entries.removeValue(forKey: oldestKey) }
            }
            entries[key] = Entry(
                body: body,
                expiresAt: ProcessInfo.processInfo.systemUptime + lifetime
            )
        }
        lock.unlock()
        flight?.group.leave()
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
