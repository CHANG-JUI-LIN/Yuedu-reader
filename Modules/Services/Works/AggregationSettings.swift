import Combine
import Foundation

// Unified library 5d-3d: 聚合設定 (Phase 5 plan, decision 21), mapped from the Emby user
// settings that shape its aggregation: 偏好閱讀語言 and 推薦範圍 (5d-3d), 書庫順序 (5d-3e),
// 顯示在最新 (5d-3f); 隱藏已讀 joins it in 5d-3g.

struct AggregationSettings: Codable, Equatable, Sendable {
    /// Nil until the reader chooses: then `ReadingLanguagePreferences.initial`, which follows
    /// the interface language.
    var readingLanguages: ReadingLanguagePreferences?
    /// 書庫順序 (`LibraryOrder`); nil until the reader orders them. Settings saved before
    /// 5d-3e have no such field and read as nil.
    var libraryOrder: [SourceInstanceKey]?
    /// The libraries 顯示在最新 turns off: Emby's `LatestItemsExcludes`. Nil until set, by the
    /// reader or by the move of the 最新 section's own list (`adoptLegacyLatestExcluded`). A
    /// library removed and added again under the same id stays off.
    var hiddenFromLatest: [SourceInstanceKey]?

    init(readingLanguages: ReadingLanguagePreferences? = nil, libraryOrder: [SourceInstanceKey]? = nil,
         hiddenFromLatest: [SourceInstanceKey]? = nil) {
        self.readingLanguages = readingLanguages
        self.libraryOrder = libraryOrder
        self.hiddenFromLatest = hiddenFromLatest
    }

    /// The languages in effect.
    func languages(interfaceLanguage: String?) -> ReadingLanguagePreferences {
        readingLanguages ?? .initial(interfaceLanguage: interfaceLanguage)
    }
}

/// The settings, kept on this device as one JSON value.
@MainActor
final class AggregationSettingsStore: ObservableObject {
    /// The app's settings, with the 最新 section's 排除的來源 moved in on first use (5d-3f).
    static let shared: AggregationSettingsStore = {
        let store = AggregationSettingsStore()
        store.adoptLegacyLatestExcluded(HomePageStore.shared.legacyLatestExcluded)
        return store
    }()

    @Published private(set) var settings: AggregationSettings

    private let defaults: UserDefaults
    static let defaultsKey = "yd_aggregation_settings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey) {
            do {
                settings = try JSONDecoder().decode(AggregationSettings.self, from: data)
            } catch {
                // Unreadable settings fall back to the defaults; the stored value is kept
                // until the reader changes something, so a later build can still read it.
                AppLogger.cache("⟐ aggregation settings unreadable", context: ["error": "\(error)"])
                settings = AggregationSettings()
            }
        } else {
            settings = AggregationSettings()
        }
    }

    /// The languages in effect, for the interface language the app runs in.
    var readingLanguages: ReadingLanguagePreferences {
        settings.languages(interfaceLanguage: Bundle.main.preferredLocalizations.first)
    }

    func setReadingLanguages(_ preferences: ReadingLanguagePreferences) {
        edit { $0.readingLanguages = preferences }
    }

    /// 書庫順序: the libraries there are now, in the order the reader gave them.
    func setLibraryOrder(_ keys: [SourceInstanceKey]) {
        edit { $0.libraryOrder = keys }
    }

    /// 顯示在最新, for one library.
    func isShownInLatest(_ key: SourceInstanceKey) -> Bool {
        !(settings.hiddenFromLatest ?? []).contains(key)
    }

    func setShownInLatest(_ shown: Bool, for key: SourceInstanceKey) {
        edit { settings in
            var hidden = settings.hiddenFromLatest ?? []
            hidden.removeAll { $0 == key }
            if !shown { hidden.append(key) }
            settings.hiddenFromLatest = hidden
        }
    }

    /// Until 5d-3f, 最新 kept its own 排除的來源 (decision 21 makes 顯示在最新 the one place).
    /// The libraries a saved home still lists move here, once: only while 顯示在最新 was never
    /// set. A book source is not moved: it serves 最新 only through the category picked for it
    /// in the section, which is how it is left out. The home file drops the list the next time
    /// it is saved.
    func adoptLegacyLatestExcluded(_ keys: [SourceInstanceKey]) {
        let keys = keys.filter(LibraryOrder.isLibrary)
        guard settings.hiddenFromLatest == nil, !keys.isEmpty else { return }
        AppLogger.cache("⟐ 排除的來源 moved to 顯示在最新", context: ["count": "\(keys.count)"])
        edit { $0.hiddenFromLatest = keys }
    }

    private func edit(_ change: (inout AggregationSettings) -> Void) {
        var changed = settings
        change(&changed)
        guard changed != settings else { return }
        settings = changed
        do {
            defaults.set(try JSONEncoder().encode(changed), forKey: Self.defaultsKey)
        } catch {
            AppLogger.cache("⟐ aggregation settings not saved", context: ["error": "\(error)"])
        }
    }
}
