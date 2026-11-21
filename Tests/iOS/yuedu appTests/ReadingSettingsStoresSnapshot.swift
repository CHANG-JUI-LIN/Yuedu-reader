import Foundation
@testable import yuedu_app

/// 排版生效範圍 and its two stores as they were, put back afterwards. Restoring the live
/// settings is not enough on its own: a test that imports, or edits a setting that
/// follows the theme, leaves values in these, and the next theme switch wears them.
/// The rows iCloud syncs ride along: the same edits note them, the ones that put the
/// live settings back included.
struct ReadingSettingsStoresSnapshot {
    private let stored: [(key: String, data: Data?)]

    init() {
        stored = (GlobalSettings.readingSettingsStoreKeys + [GlobalSettings.readingSettingSyncRecordsKey])
            .map { ($0, UserDefaults.standard.data(forKey: $0)) }
    }

    /// Empties them, so the next read captures the shared setup from what is on screen.
    ///
    /// Every row is taken off 自動 first. `xctest.sh` runs on an erased simulator, which
    /// is a new install — every typesetting row on 自動 — with an English test host, so
    /// the next theme switch would otherwise set the rows from the English 排版基準
    /// instead of the numbers a test wrote. Tests of 自動 put rows back on it themselves.
    @MainActor
    static func clear() {
        GlobalSettings.shared.readerAutomaticItems = []
        GlobalSettings.shared.readerReadingStyleID = nil
        for key in GlobalSettings.readingSettingsStoreKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func restore() {
        for entry in stored {
            if let data = entry.data {
                UserDefaults.standard.set(data, forKey: entry.key)
            } else {
                UserDefaults.standard.removeObject(forKey: entry.key)
            }
        }
    }
}
