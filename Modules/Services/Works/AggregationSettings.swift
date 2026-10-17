import Combine
import Foundation

// Unified library 5d-3d: 聚合設定 (Phase 5 plan, decision 21), mapped from the Emby user
// settings that shape its aggregation: 偏好閱讀語言 and 推薦範圍 (5d-3d), 書庫順序 (5d-3e),
// 顯示在最新 (5d-3f, set in the 最新 section's form since decision 36, and in 數據來源's 最新來源
// since search 9d), 隱藏已讀 (5d-3g, one switch for the whole home since decision 36), and
// 搜尋來源 (search 9d).

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
    /// The libraries and modules 搜尋來源 turns off (search 9d), as `hiddenFromLatest` does for
    /// 最新. Nil until set. Open Library is a module like the others since OL3.
    var hiddenFromSearch: [SourceInstanceKey]?
    /// 隱藏已讀 for the whole home but 繼續閱讀 (`HomeReadFilter`), as Emby's "Hide fully played
    /// content" (decision 36). Nil until the reader sets it: then the two switches before it.
    var hidesRead: Bool?
    /// 隱藏已讀 in 最新 and in 相關 until decision 36 (nil is on, as Emby starts
    /// `HidePlayedInLatest`). Read only while `hidesRead` is nil, and kept as stored: a build
    /// before decision 36 reads them.
    var hidesReadInLatest: Bool?
    var hidesReadInRelated: Bool?

    init(readingLanguages: ReadingLanguagePreferences? = nil, libraryOrder: [SourceInstanceKey]? = nil,
         hiddenFromLatest: [SourceInstanceKey]? = nil, hiddenFromSearch: [SourceInstanceKey]? = nil,
         hidesRead: Bool? = nil, hidesReadInLatest: Bool? = nil, hidesReadInRelated: Bool? = nil) {
        self.readingLanguages = readingLanguages
        self.libraryOrder = libraryOrder
        self.hiddenFromLatest = hiddenFromLatest
        self.hiddenFromSearch = hiddenFromSearch
        self.hidesRead = hidesRead
        self.hidesReadInLatest = hidesReadInLatest
        self.hidesReadInRelated = hidesReadInRelated
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
        store.adoptLegacyOpenLibrarySearch()
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

    /// 搜尋來源, for one library or module: searched unless the reader unchecked it.
    func isShownInSearch(_ key: SourceInstanceKey) -> Bool {
        !(settings.hiddenFromSearch ?? []).contains(key)
    }

    func setShownInSearch(_ shown: Bool, for key: SourceInstanceKey) {
        edit { settings in
            var hidden = settings.hiddenFromSearch ?? []
            hidden.removeAll { $0 == key }
            if !shown { hidden.append(key) }
            settings.hiddenFromSearch = hidden
        }
    }

    /// Until OL3, 搜尋時也查 Open Library was a switch of its own (`yd_search_open_library`, on
    /// unless set). Open Library is a module now: a reader who turned it off has the module
    /// unchecked in 搜尋來源, once; the old switch is removed.
    func adoptLegacyOpenLibrarySearch() {
        guard defaults.object(forKey: Self.legacyOpenLibrarySearchKey) != nil else { return }
        if !defaults.bool(forKey: Self.legacyOpenLibrarySearchKey) {
            setShownInSearch(false, for: ModuleProvider.instanceKey(moduleID: OfficialRuleModules.openLibraryID))
        }
        defaults.removeObject(forKey: Self.legacyOpenLibrarySearchKey)
    }

    nonisolated static let legacyOpenLibrarySearchKey = "yd_search_open_library"

    /// 隱藏已讀: on until the reader turns it off. Before it is set, off if either of the two
    /// switches it replaced was (maintainer, 2026-10-13).
    var hidesRead: Bool {
        settings.hidesRead ?? ((settings.hidesReadInLatest ?? true) && (settings.hidesReadInRelated ?? true))
    }

    func setHidesRead(_ hides: Bool) {
        edit { $0.hidesRead = hides }
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
