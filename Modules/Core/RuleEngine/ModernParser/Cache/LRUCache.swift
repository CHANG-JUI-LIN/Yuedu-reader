import Foundation

/// Thread-safe LRU cache with configurable capacity.
/// The entries live in a `Locked`, so it can be used in sync contexts.
///
final class LRUCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private struct Storage {
        var cache: [Key: Value] = [:]
        var order: [Key] = [] // Most recently used at end

        mutating func moveToEnd(_ key: Key) {
            if let index = order.lastIndex(of: key) {
                order.remove(at: index)
            }
            order.append(key)
        }

        mutating func insert(_ key: Key, _ value: Value, capacity: Int) {
            if cache[key] != nil {
                cache[key] = value
                moveToEnd(key)
                return
            }
            if capacity > 0 && cache.count >= capacity, !order.isEmpty {
                let evicted = order.removeFirst()
                cache.removeValue(forKey: evicted)
            }
            cache[key] = value
            order.append(key)
        }
    }

    private let capacity: Int
    private let storage = Locked(Storage())

    /// - Parameter capacity: Maximum number of entries. 0 means unlimited (no eviction).
    init(capacity: Int) {
        precondition(capacity >= 0, "LRUCache capacity must be non-negative")
        self.capacity = capacity
    }

    /// Get value for key, moving it to most-recent position.
    func get(_ key: Key) -> Value? {
        storage.withLock { storage in
            guard let value = storage.cache[key] else { return nil }
            storage.moveToEnd(key)
            return value
        }
    }

    /// Insert or update value, evicting LRU entry if at capacity.
    func put(_ key: Key, value: Value) {
        storage.withLock { $0.insert(key, value, capacity: capacity) }
    }

    /// Get existing value or create, cache, and return it. `create` runs under the lock, so
    /// it runs once per missing key; it must not use this cache.
    func getOrPut(_ key: Key, create: () -> Value) -> Value {
        storage.withLock { storage in
            if let value = storage.cache[key] {
                storage.moveToEnd(key)
                return value
            }
            let value = create()
            storage.insert(key, value, capacity: capacity)
            return value
        }
    }

    /// Remove a specific key.
    func remove(_ key: Key) {
        storage.withLock { storage in
            storage.cache.removeValue(forKey: key)
            storage.order.removeAll { $0 == key }
        }
    }

    /// Clear all entries.
    func clear() {
        storage.withLock { $0 = Storage() }
    }

    /// Current number of entries.
    var count: Int {
        storage.withLock { $0.cache.count }
    }
}
