import Foundation

/// Distance-based LRU cache for chapter layouts.
/// Evicts the key farthest from `currentChapter` when capacity is exceeded.
/// Designed for sequential reading where nearby chapters are most likely to be revisited.
final class LayoutCache<Value> {
    private var storage: [Int: Value] = [:]
    private var currentChapter: Int = 0
    let capacity: Int

    var count: Int { storage.count }

    init(capacity: Int = 8) {
        self.capacity = capacity
    }

    func get(_ key: Int) -> Value? {
        storage[key]
    }

    func set(_ key: Int, _ value: Value) {
        storage[key] = value
        if storage.count > capacity {
            evictOne()
        }
    }

    func setCurrentChapter(_ chapter: Int) {
        currentChapter = chapter
    }

    func remove(_ key: Int) {
        storage[key] = nil
    }

    func removeAll() {
        storage.removeAll()
    }

    var keys: Dictionary<Int, Value>.Keys { storage.keys }

    var asDictionary: [Int: Value] { storage }

    subscript(key: Int) -> Value? {
        get { storage[key] }
        set {
            if let newValue {
                set(key, newValue)
            } else {
                remove(key)
            }
        }
    }

    private func evictOne() {
        guard let farthest = storage.keys.max(by: { distance($0) < distance($1) }) else { return }
        storage[farthest] = nil
    }

    private func distance(_ key: Int) -> Int {
        abs(key - currentChapter)
    }
}
