import CryptoKit
import Foundation

/// Persistent runtime state owned by an imported Legado book source.
///
/// Source variables are intentionally kept outside `BookSource`: imported rule
/// JSON remains immutable, while settings changed by `source.setVariable(...)`
/// survive search/detail/toc/content sessions and app relaunches.
/// All mutable `UserDefaults` access is serialized by `queue`; the remaining
/// stored properties are immutable after initialization. This makes the shared
/// instance safe to call from the detached search-presentation worker.
final class BookSourceRuntimeStateStore: @unchecked Sendable {
    static let shared = BookSourceRuntimeStateStore()

    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "com.yuedu.bookSourceRuntimeState")

    private init() {
        defaults = UserDefaults(suiteName: "com.yuedu.bookSourceRuntimeState") ?? .standard
    }

    func sourceVariableJSON(for sourceUrl: String) -> String? {
        queue.sync {
            defaults.string(forKey: key(sourceUrl: sourceUrl, suffix: "sourceVariableJSON"))
        }
    }

    func setSourceVariableJSON(_ json: String?, for sourceUrl: String) {
        queue.sync {
            let storageKey = key(sourceUrl: sourceUrl, suffix: "sourceVariableJSON")
            guard let json, !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                defaults.removeObject(forKey: storageKey)
                return
            }
            defaults.set(json, forKey: storageKey)
        }
    }

    /// Parsed `source.setVariable(...)` payload for this source.
    ///
    /// Empty when the source has no variables yet, or when the stored payload is
    /// not a JSON object — some sources persist a JSON *array* (their rules read
    /// it as `JSON.parse(source.getVariable())[0]`), and those carry no keyed
    /// settings for callers of this method to read.
    func sourceVariables(for sourceUrl: String) -> [String: Any] {
        guard let json = sourceVariableJSON(for: sourceUrl),
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return dict
    }

    func sourceValue(for sourceUrl: String, key entryKey: String) -> String? {
        queue.sync {
            let values = defaults.dictionary(
                forKey: key(sourceUrl: sourceUrl, suffix: "sourceKeyValues")
            ) as? [String: String]
            return values?[entryKey]
        }
    }

    func setSourceValue(_ value: String, for sourceUrl: String, key entryKey: String) {
        queue.sync {
            let storageKey = key(sourceUrl: sourceUrl, suffix: "sourceKeyValues")
            var values = defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
            values[entryKey] = value
            defaults.set(values, forKey: storageKey)
        }
    }

    /// One-shot cleanup of device ids this app wrote wrongly.
    ///
    /// `java.androidId()` used to return `identifierForVendor` — a 36-char uppercase
    /// UUID — where Android hands out 16 lowercase hex characters. Sources cache it in
    /// their own key/value store (知秋番茄: `source.put('androidId', …)`) and read that
    /// back before ever calling us again, so fixing `androidId()` alone would never
    /// reach a device that had already run the source once. Drops only entries whose
    /// key names a device id AND whose value is exactly that old shape — a source's own
    /// settings are never touched.
    ///
    /// Delete this (and `LegadoJSBridge.isLegacyVendorUUIDAndroidId`) once no install
    /// can still be carrying a pre-fix value.
    func purgeLegacyAndroidIds() {
        let flag = "bookSourceRuntime.didPurgeLegacyAndroidIds"
        queue.sync {
            guard !defaults.bool(forKey: flag) else { return }
            defer { defaults.set(true, forKey: flag) }
            for (storageKey, value) in defaults.dictionaryRepresentation()
            where storageKey.hasPrefix("bookSourceRuntime.")
                && storageKey.hasSuffix(".sourceKeyValues") {
                guard var entries = value as? [String: String] else { continue }
                let stale = entries.filter { entry in
                    entry.key.lowercased().contains("androidid")
                        && LegadoJSBridge.isLegacyVendorUUIDAndroidId(entry.value)
                }
                guard !stale.isEmpty else { continue }
                stale.keys.forEach { entries.removeValue(forKey: $0) }
                defaults.set(entries, forKey: storageKey)
                AppLogger.parse("⟐ purged legacy androidId", context: [
                    "keys": stale.keys.sorted().joined(separator: ",")
                ])
            }
        }
    }

    private func key(sourceUrl: String, suffix: String) -> String {
        let data = Data(sourceUrl.utf8)
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return "bookSourceRuntime.\(digest).\(suffix)"
    }
}
