import Combine
import Foundation

// Unified library 5d-3d: 聚合設定 (Phase 5 plan, decision 21), mapped from the Emby user
// settings that shape its aggregation: 中繼資料語言偏好推薦 (2026-10-21; 偏好閱讀語言 and 推薦範圍 in
// 5d-3d), 書庫順序 (5d-3e, taken away 2026-10-25),
// 顯示在最新 (5d-3f, set in the 最新 section's form since decision 36, and in 數據來源's 最新來源
// since search 9d), 隱藏已讀 (5d-3g, one switch for the whole home since decision 36), and
// 搜尋來源 (search 9d).

struct AggregationSettings: Codable, Equatable, Sendable {
    /// 偏好閱讀語言 and 推薦範圍 until 2026-10-21, kept as stored: its first language is the
    /// choice until the reader picks one in 中繼資料語言偏好推薦.
    var readingLanguages: LegacyReadingLanguages?
    /// 中繼資料語言偏好推薦: `MetadataLanguage.followApp` or one of `MetadataLanguage.offered`.
    /// Nil until the reader picks.
    var metadataLanguage: String?
    /// 書庫順序 until 2026-10-25, when the maintainer took it away; read by nothing since, and
    /// kept as stored for a build before that, which still orders by it.
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

    init(readingLanguages: LegacyReadingLanguages? = nil, metadataLanguage: String? = nil,
         libraryOrder: [SourceInstanceKey]? = nil,
         hiddenFromLatest: [SourceInstanceKey]? = nil, hiddenFromSearch: [SourceInstanceKey]? = nil,
         hidesRead: Bool? = nil, hidesReadInLatest: Bool? = nil, hidesReadInRelated: Bool? = nil) {
        self.readingLanguages = readingLanguages
        self.metadataLanguage = metadataLanguage
        self.libraryOrder = libraryOrder
        self.hiddenFromLatest = hiddenFromLatest
        self.hiddenFromSearch = hiddenFromSearch
        self.hidesRead = hidesRead
        self.hidesReadInLatest = hidesReadInLatest
        self.hidesReadInRelated = hidesReadInRelated
    }

    /// 中繼資料語言偏好推薦's choice: the reader's, else 偏好閱讀語言's, else 跟隨 App 語言.
    func metadataLanguageChoice(interfaceLanguage: String?) -> String {
        metadataLanguage ?? MetadataLanguage.choice(migrating: readingLanguages, interfaceLanguage: interfaceLanguage)
            ?? MetadataLanguage.followApp
    }

    /// The language in effect.
    func languages(interfaceLanguage: String?) -> ReadingLanguagePreferences {
        let choice = metadataLanguageChoice(interfaceLanguage: interfaceLanguage)
        return ReadingLanguagePreferences(language: MetadataLanguage.tag(of: choice, interfaceLanguage: interfaceLanguage))
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
    /// Whether what is stored could not be read, so `settings` are the defaults in its place:
    /// the iCloud sync then sends nothing, or it would send those defaults as the reader's.
    private(set) var storedIsUnreadable = false

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
                storedIsUnreadable = true
            }
        } else {
            settings = AggregationSettings()
        }
    }

    /// The language in effect, for the interface language the app runs in.
    var readingLanguages: ReadingLanguagePreferences {
        settings.languages(interfaceLanguage: Self.interfaceLanguage)
    }

    /// 中繼資料語言偏好推薦's choice, as its menu shows it.
    var metadataLanguageChoice: String {
        settings.metadataLanguageChoice(interfaceLanguage: Self.interfaceLanguage)
    }

    func setMetadataLanguage(_ choice: String) {
        edit { $0.metadataLanguage = choice }
    }

    private static var interfaceLanguage: String? { Bundle.main.preferredLocalizations.first }

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
        let keys = keys.filter(LibraryKeys.isLibrary)
        guard settings.hiddenFromLatest == nil, !keys.isEmpty else { return }
        AppLogger.cache("⟐ 排除的來源 moved to 顯示在最新", context: ["count": "\(keys.count)"])
        edit { $0.hiddenFromLatest = keys }
    }

    // MARK: - iCloud sync

    /// What the reader set, a setting an item, for the iCloud sync: 中繼資料語言偏好推薦, 隱藏已讀,
    /// and each library or module turned off in 顯示在最新 and in 搜尋來源 — so a module unchecked
    /// here and another unchecked there are both unchecked after. The fields kept only for
    /// older builds stay on this device. Nil while what is stored cannot be read.
    var syncItems: [AggregationSettingSyncItem]? {
        guard !storedIsUnreadable else { return nil }
        var items: [AggregationSettingSyncItem] = []
        if let language = settings.metadataLanguage {
            items.append(AggregationSettingSyncItem(kind: .metadataLanguage, text: language))
        }
        if let hides = settings.hidesRead { items.append(AggregationSettingSyncItem(kind: .hidesRead, flag: hides)) }
        items += (settings.hiddenFromLatest ?? []).map { AggregationSettingSyncItem(kind: .hiddenFromLatest, key: $0) }
        items += (settings.hiddenFromSearch ?? []).map { AggregationSettingSyncItem(kind: .hiddenFromSearch, key: $0) }
        return items
    }

    /// The settings as a sync merged them. A list no device has set stays unset.
    func applyFromSync(_ items: [AggregationSettingSyncItem]) {
        func keys(_ kind: AggregationSettingSyncItem.Kind, unlessSet current: [SourceInstanceKey]?) -> [SourceInstanceKey]? {
            let keys = items.filter { $0.kind == kind }.compactMap(\.key)
            return keys.isEmpty && current == nil ? nil : keys
        }
        edit { settings in
            if let language = items.first(where: { $0.kind == .metadataLanguage })?.text { settings.metadataLanguage = language }
            if let hides = items.first(where: { $0.kind == .hidesRead })?.flag { settings.hidesRead = hides }
            settings.hiddenFromLatest = keys(.hiddenFromLatest, unlessSet: settings.hiddenFromLatest)
            settings.hiddenFromSearch = keys(.hiddenFromSearch, unlessSet: settings.hiddenFromSearch)
        }
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

/// One of 聚合設定's settings as the iCloud sync carries it (`AggregationSettingsStore.syncItems`).
struct AggregationSettingSyncItem: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case metadataLanguage, hidesRead, hiddenFromLatest, hiddenFromSearch
    }

    let kind: Kind
    /// 中繼資料語言偏好推薦's choice.
    var text: String?
    /// 隱藏已讀.
    var flag: Bool?
    /// The library or module turned off.
    var key: SourceInstanceKey?

    init(kind: Kind, text: String? = nil, flag: Bool? = nil, key: SourceInstanceKey? = nil) {
        self.kind = kind
        self.text = text
        self.flag = flag
        self.key = key
    }

    /// The setting, or the setting and the place it turns off.
    var id: String {
        key.map { "\(kind.rawValue)/\($0.type.rawValue)/\($0.id)" } ?? kind.rawValue
    }
}
