import CryptoKit
import Foundation
import os

/// Persistent runtime state owned by an imported Legado book source.
///
/// Source variables are intentionally kept outside `BookSource`: imported rule
/// JSON remains immutable, while settings changed by `source.setVariable(...)`
/// survive search/detail/toc/content sessions and app relaunches.
///
/// This store is the sole writer of its `UserDefaults` suite, so the in-memory
/// mirrors below are authoritative for reads and `UserDefaults` is pure
/// persistence. That matters because content-kind inference reads source
/// variables from SwiftUI `body`: the previous read path rebuilt the SHA-256
/// storage key (32 `String(format: "%02x")` calls), hit `UserDefaults`, and
/// re-parsed the variable JSON on *every* call. With one call per origin per
/// search-result row per layout pass, that wedged the main thread inside
/// `queue.sync` and got the app killed by the scene-update watchdog.
final class BookSourceRuntimeStateStore {
    static let shared = BookSourceRuntimeStateStore()

    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "com.yuedu.bookSourceRuntimeState")

    // MARK: In-memory mirrors (guarded by `queue`)

    /// SHA-256 hex of a source URL — a pure function of the URL, so computed once.
    private var digestCache: [String: String] = [:]
    /// Mirror of the persisted variable JSON. A stored `nil` means "known absent".
    private var variableJSONCache: [String: String?] = [:]
    /// Parsed form of `variableJSONCache`, so readers never run `JSONSerialization`.
    private var variableDictCache: [String: [String: Any]] = [:]
    /// Mirror of the persisted `sourceKeyValues` map.
    private var keyValueCache: [String: [String: String]] = [:]

    /// Bumped on every write. Deliberately kept outside `queue` so consumers that
    /// memoize derived values (content-kind inference on search rows) can check
    /// staleness without contending with in-flight writes from source JS.
    private let generationLock = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    private init() {
        defaults = UserDefaults(suiteName: "com.yuedu.bookSourceRuntimeState") ?? .standard
    }

    /// Monotonic write counter. A memoized value derived from source variables is
    /// still valid as long as this has not changed since it was computed.
    var stateGeneration: UInt64 {
        generationLock.withLock { $0 }
    }

    // MARK: - Source variable JSON

    func sourceVariableJSON(for sourceUrl: String) -> String? {
        queue.sync { loadVariableJSONLocked(sourceUrl) }
    }

    func setSourceVariableJSON(_ json: String?, for sourceUrl: String) {
        queue.sync {
            // Bump last, while still holding the queue, so a reader that observes the
            // new generation is guaranteed to also see the new value.
            defer { bumpGeneration() }
            let storageKey = key(sourceUrl: sourceUrl, suffix: "sourceVariableJSON")
            guard let json, !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                defaults.removeObject(forKey: storageKey)
                variableJSONCache.updateValue(nil, forKey: sourceUrl)
                variableDictCache[sourceUrl] = [:]
                return
            }
            defaults.set(json, forKey: storageKey)
            variableJSONCache.updateValue(json, forKey: sourceUrl)
            variableDictCache.removeValue(forKey: sourceUrl)
        }
    }

    /// Parsed `source.setVariable(...)` payload for this source.
    ///
    /// Cached alongside the raw JSON so callers on the render path — content-kind
    /// inference runs for every origin of every visible search result — do a
    /// dictionary lookup instead of a `UserDefaults` read plus a JSON parse.
    /// Returns an empty dictionary when the source has no variables, or when the
    /// stored payload is unparseable (logged, not silently swallowed).
    func sourceVariables(for sourceUrl: String) -> [String: Any] {
        queue.sync {
            if let cached = variableDictCache[sourceUrl] { return cached }
            let parsed = parseVariablesLocked(sourceUrl)
            variableDictCache[sourceUrl] = parsed
            return parsed
        }
    }

    // MARK: - Source key/value entries

    func sourceValue(for sourceUrl: String, key entryKey: String) -> String? {
        queue.sync { loadKeyValuesLocked(sourceUrl)[entryKey] }
    }

    func setSourceValue(_ value: String, for sourceUrl: String, key entryKey: String) {
        queue.sync {
            var values = loadKeyValuesLocked(sourceUrl)
            values[entryKey] = value
            keyValueCache[sourceUrl] = values
            defaults.set(values, forKey: key(sourceUrl: sourceUrl, suffix: "sourceKeyValues"))
            bumpGeneration()
        }
    }

    // MARK: - Locked helpers (callers must already be on `queue`)

    private func loadVariableJSONLocked(_ sourceUrl: String) -> String? {
        if let cached = variableJSONCache[sourceUrl] { return cached }
        let value = defaults.string(forKey: key(sourceUrl: sourceUrl, suffix: "sourceVariableJSON"))
        variableJSONCache.updateValue(value, forKey: sourceUrl)
        return value
    }

    private func loadKeyValuesLocked(_ sourceUrl: String) -> [String: String] {
        if let cached = keyValueCache[sourceUrl] { return cached }
        let values = defaults.dictionary(
            forKey: key(sourceUrl: sourceUrl, suffix: "sourceKeyValues")
        ) as? [String: String] ?? [:]
        keyValueCache[sourceUrl] = values
        return values
    }

    private func parseVariablesLocked(_ sourceUrl: String) -> [String: Any] {
        guard let json = loadVariableJSONLocked(sourceUrl),
              !json.isEmpty,
              let data = json.data(using: .utf8)
        else { return [:] }
        do {
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                AppLogger.parse("⟐ source variables are not a JSON object", context: [
                    "sourceUrl": sourceUrl,
                    "payload": String(json.prefix(160)),
                ])
                return [:]
            }
            return dict
        } catch {
            AppLogger.parse("⟐ source variables JSON parse failed", error: error, context: [
                "sourceUrl": sourceUrl,
                "payload": String(json.prefix(160)),
            ])
            return [:]
        }
    }

    private func key(sourceUrl: String, suffix: String) -> String {
        "bookSourceRuntime.\(digest(for: sourceUrl)).\(suffix)"
    }

    /// SHA-256 hex of the source URL, memoized.
    ///
    /// The hex form must stay byte-identical to the original
    /// `map { String(format: "%02x", $0) }.joined()` encoding — it is the
    /// persisted `UserDefaults` key, so any change orphans every user's stored
    /// source variables.
    private func digest(for sourceUrl: String) -> String {
        if let cached = digestCache[sourceUrl] { return cached }
        let hex = Self.lowercaseHex(SHA256.hash(data: Data(sourceUrl.utf8)))
        digestCache[sourceUrl] = hex
        return hex
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    private static func lowercaseHex<Bytes: Sequence>(_ bytes: Bytes) -> String
    where Bytes.Element == UInt8 {
        var encoded: [UInt8] = []
        encoded.reserveCapacity(64)
        for byte in bytes {
            encoded.append(hexDigits[Int(byte >> 4)])
            encoded.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    private func bumpGeneration() {
        generationLock.withLock { $0 &+= 1 }
    }
}
