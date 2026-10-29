import CryptoKit
import Foundation

extension Notification.Name {
    /// Posted only after a user action changes a source variable: an editor save,
    /// or a login-sheet script (登录 / loginUi buttons) calling `source.setVariable`.
    ///
    /// Rule JS also calls `source.setVariable(...)` while discover/content is
    /// running. Broadcasting those internal writes would cancel and restart the
    /// same discover evaluation indefinitely, so runtime bridges continue to use
    /// `setSourceVariableJSON` while user-driven paths use `setUserSourceVariableJSON`.
    static let bookSourceUserVariableDidChange = Notification.Name(
        "bookSourceUserVariableDidChange"
    )
}

/// Persistent runtime state owned by an imported Legado book source.
///
/// Source variables are intentionally kept outside `BookSource`: imported rule
/// JSON remains immutable, while settings changed by `source.setVariable(...)`
/// survive search/detail/toc/content sessions and app relaunches.
///
/// Each source keeps its state in a `UserDefaults` suite of its own. Source scripts write
/// here at request rate — a search rule's `java.put` runs once per result row, and a
/// background metadata pass searches dozens of sources per book — and CFPrefs writes a
/// suite's whole plist again for each change. While every source shared one suite, a single
/// changed id cost the state of all of them: about 40 KB per search page with 86 sources
/// (3.0.0 (140): a 4.3 GB disk-write exception, Crashlytics afe8e4bd855dd39d55423aab8a7a721b;
/// measured in `UserDefaultsDiskWriteTests`).
///
/// All mutable `UserDefaults` access is serialized by `queue`; the remaining
/// stored properties are immutable after initialization. This makes the shared
/// instance safe to call from the detached search-presentation worker.
final class BookSourceRuntimeStateStore: @unchecked Sendable {
    static let shared = BookSourceRuntimeStateStore()

    private static let variableKey = "sourceVariableJSON"
    private static let keyValuesKey = "sourceKeyValues"

    /// The one suite every source shared until 2026-10-29, emptied into the per-source suites
    /// on first use; each source's suite is this name followed by its digest.
    private let sharedSuiteName: String
    private let queue = DispatchQueue(label: "com.yuedu.bookSourceRuntimeState")
    /// Suites already opened, by suite name. Touched only on `queue`.
    private var suites: [String: UserDefaults] = [:]

    /// `sharedSuiteName` is a test's own; the app uses the default.
    init(sharedSuiteName: String = "com.yuedu.bookSourceRuntimeState") {
        self.sharedSuiteName = sharedSuiteName
        queue.sync { moveSharedSuiteIntoSourceSuites() }
    }

    /// The suite holding one source's state.
    func suiteName(for sourceUrl: String) -> String {
        let digest = SHA256.hash(data: Data(sourceUrl.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(sharedSuiteName).\(digest)"
    }

    func sourceVariableJSON(for sourceUrl: String) -> String? {
        queue.sync {
            defaults(for: sourceUrl).string(forKey: Self.variableKey)
        }
    }

    func setSourceVariableJSON(_ json: String?, for sourceUrl: String) {
        queue.sync {
            let defaults = defaults(for: sourceUrl)
            guard let json, !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                defaults.removeObject(forKey: Self.variableKey)
                return
            }
            guard defaults.string(forKey: Self.variableKey) != json else { return }
            defaults.set(json, forKey: Self.variableKey)
        }
    }

    /// Persists a source variable entered by the user and tells live consumers
    /// to invalidate their source-scoped presentation state.
    func setUserSourceVariableJSON(_ json: String?, for sourceUrl: String) {
        let previous = sourceVariableJSON(for: sourceUrl)
        setSourceVariableJSON(json, for: sourceUrl)
        let current = sourceVariableJSON(for: sourceUrl)
        guard previous != current else { return }
        NotificationCenter.default.post(
            name: .bookSourceUserVariableDidChange,
            object: nil,
            userInfo: ["sourceURL": sourceUrl]
        )
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
            let values = defaults(for: sourceUrl).dictionary(forKey: Self.keyValuesKey) as? [String: String]
            return values?[entryKey]
        }
    }

    func setSourceValue(_ value: String, for sourceUrl: String, key entryKey: String) {
        queue.sync {
            let defaults = defaults(for: sourceUrl)
            var values = defaults.dictionary(forKey: Self.keyValuesKey) as? [String: String] ?? [:]
            guard values[entryKey] != value else { return }
            values[entryKey] = value
            defaults.set(values, forKey: Self.keyValuesKey)
        }
    }

    /// Opens (once) the suite holding `sourceUrl`'s state. Call on `queue`.
    private func defaults(for sourceUrl: String) -> UserDefaults {
        defaults(suiteName: suiteName(for: sourceUrl))
    }

    private func defaults(suiteName: String) -> UserDefaults {
        if let defaults = suites[suiteName] { return defaults }
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            // `UserDefaults(suiteName:)` is nil only for the app's own bundle id or
            // NSGlobalDomain, which a `com.yuedu.…` name never is.
            preconditionFailure("UserDefaults refused suite \(suiteName)")
        }
        suites[suiteName] = defaults
        return defaults
    }

    /// Moves what earlier builds kept in the one shared suite —
    /// `bookSourceRuntime.<sha256 of the source URL>.<field>` — into each source's own suite,
    /// then empties the shared suite. Runs on every first use; once moved there is nothing
    /// left to read. Delete with `purgeLegacyAndroidIds` once no install can still carry the
    /// shared suite.
    private func moveSharedSuiteIntoSourceSuites() {
        guard let shared = UserDefaults(suiteName: sharedSuiteName) else { return }
        let entries = shared.dictionaryRepresentation().filter { $0.key.hasPrefix("bookSourceRuntime.") }
        guard !entries.isEmpty else { return }
        let didPurge = shared.bool(forKey: "bookSourceRuntime.didPurgeLegacyAndroidIds")
        var moved = 0
        for (storageKey, value) in entries {
            let parts = storageKey.split(separator: ".")
            guard parts.count == 3, parts[0] == "bookSourceRuntime", parts[1].count == 64 else { continue }
            var value = value
            if !didPurge, parts[2] == Self.keyValuesKey, let entries = value as? [String: String] {
                value = purgeLegacyAndroidIds(entries)
            }
            defaults(suiteName: "\(sharedSuiteName).\(parts[1])").set(value, forKey: String(parts[2]))
            moved += 1
        }
        UserDefaults.standard.removePersistentDomain(forName: sharedSuiteName)
        AppLogger.parse("⟐ source runtime state moved to per-source suites", context: ["entries": "\(moved)"])
    }

    /// Drops device ids this app wrote wrongly from a source's key/value store.
    ///
    /// `java.androidId()` used to return `identifierForVendor` — a 36-char uppercase
    /// UUID — where Android hands out 16 lowercase hex characters. Sources cache it in
    /// their own key/value store (知秋番茄: `source.put('androidId', …)`) and read that
    /// back before ever calling us again, so fixing `androidId()` alone would never
    /// reach a device that had already run the source once. Drops only entries whose
    /// key names a device id AND whose value is exactly that old shape — a source's own
    /// settings are never touched. Runs while the shared suite is moved, before any source
    /// JS can read it.
    ///
    /// Delete this (and `LegadoJSBridge.isLegacyVendorUUIDAndroidId`) once no install
    /// can still be carrying a pre-fix value.
    private func purgeLegacyAndroidIds(_ entries: [String: String]) -> [String: String] {
        let stale = entries.filter { entry in
            entry.key.lowercased().contains("androidid")
                && LegadoJSBridge.isLegacyVendorUUIDAndroidId(entry.value)
        }
        guard !stale.isEmpty else { return entries }
        AppLogger.parse("⟐ purged legacy androidId", context: [
            "keys": stale.keys.sorted().joined(separator: ",")
        ])
        return entries.filter { stale[$0.key] == nil }
    }
}
