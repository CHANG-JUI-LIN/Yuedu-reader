import Combine
import Foundation

// Unified library 5d-3d: 聚合設定 (Phase 5 plan, decision 21), mapped from the Emby user
// settings that shape its aggregation: 偏好閱讀語言 and 推薦範圍 (5d-3d), 書庫順序 (5d-3e);
// 顯示在最新 and 隱藏已讀 join it in 5d-3f and 5d-3g.

struct AggregationSettings: Codable, Equatable, Sendable {
    /// Nil until the reader chooses: then `ReadingLanguagePreferences.initial`, which follows
    /// the interface language.
    var readingLanguages: ReadingLanguagePreferences?
    /// 書庫順序 (`LibraryOrder`); nil until the reader orders them. Settings saved before
    /// 5d-3e have no such field and read as nil.
    var libraryOrder: [SourceInstanceKey]?

    init(readingLanguages: ReadingLanguagePreferences? = nil, libraryOrder: [SourceInstanceKey]? = nil) {
        self.readingLanguages = readingLanguages
        self.libraryOrder = libraryOrder
    }

    /// The languages in effect.
    func languages(interfaceLanguage: String?) -> ReadingLanguagePreferences {
        readingLanguages ?? .initial(interfaceLanguage: interfaceLanguage)
    }
}

/// The settings, kept on this device as one JSON value.
@MainActor
final class AggregationSettingsStore: ObservableObject {
    static let shared = AggregationSettingsStore()

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
