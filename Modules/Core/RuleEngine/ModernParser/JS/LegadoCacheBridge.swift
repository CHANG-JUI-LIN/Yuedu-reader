import Foundation
import JavaScriptCore

// MARK: - JSExport Protocol

/// JS-callable interface for Legado's `cache.*` object.
/// Mirrors Legado's `CacheManager`: persistent key-value store + memory cache.
@objc protocol LegadoCacheBridgeExport: JSExport {
    // The getters are `String?` in Legado's `CacheManager`: a missing key is `null` to the
    // script (`LegadoJavaNull`). Swift callers use the `String?` twins below.
    @objc(get:) func jsGet(_ key: String) -> JSValue
    /// `put(key, value[, saveTime])`; Swift callers use `put(_:_:saveTime:)`.
    @objc(put:::) func jsPut(_ key: String, _ value: String, _ saveTime: JSValue)
    func delete(_ key: String)
    @objc(getFromMemory:) func jsGetFromMemory(_ key: String) -> JSValue
    func putMemory(_ key: String, _ value: String)
    func deleteMemory(_ key: String)
    /// Legado `CacheManager.getFile` / `putFile`: a second key-value store (`ACache`'s files)
    /// beside `get`/`put`'s database. 酷我小说 keeps its book index there.
    @objc(getFile:) func jsGetFile(_ key: String) -> JSValue
    /// `putFile(key, value[, saveTime])`; Swift callers use `putFile(_:_:saveTime:)`.
    @objc(putFile:::) func jsPutFile(_ key: String, _ value: String, _ saveTime: JSValue)
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

    /// Legado `CacheManager.get`: the memory cache, else the stored value while its deadline
    /// has not passed, which the memory cache then keeps. Legado's memory cache keeps no
    /// deadline, and neither does this one.
    func get(_ key: String) -> String? {
        if let value = memoryCache.get(key) { return value }
        guard let value = unexpiredValue(forKey: "\(keyPrefix)_\(key)") else { return nil }
        memoryCache.put(key, value: value)
        return value
    }

    @objc(get:) func jsGet(_ key: String) -> JSValue { LegadoJavaNull.value(get(key)) }

    /// Legado `CacheManager.put(key, value, saveTime)`: kept for `saveTime` seconds, for good
    /// when it is 0. 哔哩哔哩 (YCK1331) keeps what it fetched for 300 s this way, 晋江文学 for 11600 s.
    func put(_ key: String, _ value: String, saveTime: Int = 0) {
        memoryCache.put(key, value: value)
        store(value, forKey: "\(keyPrefix)_\(key)", saveTime: saveTime)
    }

    @objc(put:::) func jsPut(_ key: String, _ value: String, _ saveTime: JSValue) {
        put(key, value, saveTime: Self.seconds(saveTime))
    }

    func delete(_ key: String) {
        memoryCache.remove(key)
        for stored in ["\(keyPrefix)_\(key)", "\(keyPrefix)_file_\(key)"] {
            persistentStore.removeObject(forKey: stored)
            persistentStore.removeObject(forKey: Self.deadlineKey(stored))
        }
    }

    func getFromMemory(_ key: String) -> String? {
        return memoryCache.get(key)
    }

    @objc(getFromMemory:) func jsGetFromMemory(_ key: String) -> JSValue {
        LegadoJavaNull.value(getFromMemory(key))
    }

    func putMemory(_ key: String, _ value: String) {
        memoryCache.put(key, value: value)
    }

    func deleteMemory(_ key: String) {
        memoryCache.remove(key)
    }

    // Keys of their own, as Legado's file cache is a store of its own: a `put` never answers
    // a `getFile`. Legado's `delete` clears both, so `delete` here clears the file key too.
    func getFile(_ key: String) -> String? {
        unexpiredValue(forKey: "\(keyPrefix)_file_\(key)")
    }

    @objc(getFile:) func jsGetFile(_ key: String) -> JSValue { LegadoJavaNull.value(getFile(key)) }

    /// Legado `CacheManager.putFile(key, value, saveTime)` — `ACache.put`, which drops the value
    /// once `saveTime` seconds have passed (0: never).
    func putFile(_ key: String, _ value: String, saveTime: Int = 0) {
        store(value, forKey: "\(keyPrefix)_file_\(key)", saveTime: saveTime)
    }

    @objc(putFile:::) func jsPutFile(_ key: String, _ value: String, _ saveTime: JSValue) {
        putFile(key, value, saveTime: Self.seconds(saveTime))
    }

    // MARK: Deadlines

    private func store(_ value: String, forKey stored: String, saveTime: Int) {
        persistentStore.set(value, forKey: stored)
        if saveTime == 0 {
            persistentStore.removeObject(forKey: Self.deadlineKey(stored))
        } else {
            persistentStore.set(
                Date().timeIntervalSince1970 + Double(saveTime), forKey: Self.deadlineKey(stored)
            )
        }
    }

    private func unexpiredValue(forKey stored: String) -> String? {
        if let deadline = persistentStore.object(forKey: Self.deadlineKey(stored)) as? Double,
           deadline <= Date().timeIntervalSince1970 {
            return nil
        }
        return persistentStore.string(forKey: stored)
    }

    private static func deadlineKey(_ stored: String) -> String { "\(stored)__deadline" }

    /// A script's `saveTime` argument: Legado's `Int` parameter, 0 when it is left out.
    private static func seconds(_ value: JSValue) -> Int {
        guard !value.isUndefined, !value.isNull else { return 0 }
        return Int(value.toInt32())
    }
}
