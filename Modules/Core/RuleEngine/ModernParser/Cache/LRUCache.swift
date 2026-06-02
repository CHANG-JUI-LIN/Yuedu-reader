import Foundation

/// Thread-safe LRU cache with configurable capacity.
/// Uses NSLock for synchronization so it can be used in sync contexts.
final class LRUCache<Key: Hashable, Value> {
    private let capacity: Int
    private var cache: [Key: Value] = [:]
    private var order: [Key] = [] // Most recently used at end
    private let lock = NSLock()

    /// - Parameter capacity: Maximum number of entries. 0 means unlimited (no eviction).
    init(capacity: Int) {
        precondition(capacity >= 0, "LRUCache capacity must be non-negative")
        self.capacity = capacity
    }

    /// Get value for key, moving it to most-recent position.
    func get(_ key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }

        guard let value = cache[key] else { return nil }
        moveToEnd(key)
        return value
    }

    /// Insert or update value, evicting LRU entry if at capacity.
    func put(_ key: Key, value: Value) {
        lock.lock()
        defer { lock.unlock() }

        if cache[key] != nil {
            cache[key] = value
            moveToEnd(key)
        } else {
            if capacity > 0 && cache.count >= capacity {
                evictLRU()
            }
            cache[key] = value
            order.append(key)
        }
    }

    /// Get existing value or create, cache, and return it.
    func getOrPut(_ key: Key, create: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }

        if let value = cache[key] {
            moveToEnd(key)
            return value
        }

        let value = create()
        if capacity > 0 && cache.count >= capacity {
            evictLRU()
        }
        cache[key] = value
        order.append(key)
        return value
    }

    /// Remove a specific key.
    func remove(_ key: Key) {
        lock.lock()
        defer { lock.unlock() }

        cache.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }

    /// Clear all entries.
    func clear() {
        lock.lock()
        defer { lock.unlock() }

        cache.removeAll()
        order.removeAll()
    }

    /// Current number of entries.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }

        return cache.count
    }

    // MARK: - Private helpers (caller must hold lock)

    private func moveToEnd(_ key: Key) {
        if let index = order.lastIndex(of: key) {
            order.remove(at: index)
        }
        order.append(key)
    }

    private func evictLRU() {
        guard !order.isEmpty else { return }
        let evicted = order.removeFirst()
        cache.removeValue(forKey: evicted)
    }
}
