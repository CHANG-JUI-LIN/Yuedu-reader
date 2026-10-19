import Foundation

/// An `NSCache` that a `static let` can hold and several threads can share.
///
/// `NSCache` is documented thread-safe — it serialises every call with its own lock and evicts
/// under memory pressure — but the SDK marks its `Sendable` conformance unavailable, so a
/// `static let` of one is reported as global shared mutable state (Swift 6 `GlobalConcurrency`).
/// This is the one place that vouches for it. It only admits `String` keys (bridged to an
/// immutable `NSString` here, so a caller cannot mutate a key the cache holds) and `Sendable`
/// values, so nothing non-Sendable can cross threads through it.
///
/// `@unchecked` can go once the SDK declares `NSCache: Sendable`; then the statics can hold
/// `NSCache` directly again.
final class ConcurrentCache<Value: AnyObject & Sendable>: @unchecked Sendable {
    private let cache = NSCache<NSString, Value>()

    /// - Parameters:
    ///   - countLimit: `NSCache.countLimit`; `0` is no limit.
    ///   - totalCostLimit: `NSCache.totalCostLimit`; `0` is no limit.
    init(countLimit: Int = 0, totalCostLimit: Int = 0) {
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
    }

    func object(forKey key: String) -> Value? {
        cache.object(forKey: key as NSString)
    }

    func setObject(_ value: Value, forKey key: String) {
        cache.setObject(value, forKey: key as NSString)
    }

    func setObject(_ value: Value, forKey key: String, cost: Int) {
        cache.setObject(value, forKey: key as NSString, cost: cost)
    }

    func removeObject(forKey key: String) {
        cache.removeObject(forKey: key as NSString)
    }

    func removeAllObjects() {
        cache.removeAllObjects()
    }
}
