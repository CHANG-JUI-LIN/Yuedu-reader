import Foundation
import JavaScriptCore

// MARK: - JSExport Protocol

/// JS-callable interface for Legado's `cache.*` object.
/// Mirrors Legado's `CacheManager`: persistent key-value store + memory cache.
@objc protocol LegadoCacheBridgeExport: JSExport {
    func get(_ key: String) -> String?
    func put(_ key: String, _ value: String)
    func delete(_ key: String)
    func getFromMemory(_ key: String) -> String?
    func putMemory(_ key: String, _ value: String)
    func deleteMemory(_ key: String)
}

// MARK: - Bridge Implementation

@objc class LegadoCacheBridge: NSObject, LegadoCacheBridgeExport {

    private let memoryCache = LRUCache<String, String>(capacity: 128)
    private let persistentStore: UserDefaults
    private let keyPrefix: String

    init(sourceId: String) {
        self.keyPrefix = "cache_\(sourceId)"
        self.persistentStore = UserDefaults(suiteName: "com.yuedu.cache.\(sourceId)") ?? .standard
        super.init()
    }

    func get(_ key: String) -> String? {
        memoryCache.get(key) ?? persistentStore.string(forKey: "\(keyPrefix)_\(key)")
    }

    func put(_ key: String, _ value: String) {
        memoryCache.put(key, value: value)
        persistentStore.set(value, forKey: "\(keyPrefix)_\(key)")
    }

    func delete(_ key: String) {
        memoryCache.remove(key)
        persistentStore.removeObject(forKey: "\(keyPrefix)_\(key)")
    }

    func getFromMemory(_ key: String) -> String? {
        return memoryCache.get(key)
    }

    func putMemory(_ key: String, _ value: String) {
        memoryCache.put(key, value: value)
    }

    func deleteMemory(_ key: String) {
        memoryCache.remove(key)
    }
}
