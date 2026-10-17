import Foundation

/// The 探索 page's stored choices: plain `UserDefaults` keys, read with `@AppStorage`.
/// How a section looks is the section's own (unified library 5d); nothing here is global.
enum ExploreSettings {
    /// The old roots' 公有書庫／來源配置 choice, kept because the home reads it once for its
    /// default sections.
    static let modeKey = "explore.mode"
    /// The home's 範圍: 全部, or one source shown in place (`ExploreScope`).
    static let scopeKey = "explore.scope"
    /// Whether 探索's ••• offers the browser (unified library 5d-1, settled decision 12). On by default;
    /// 編輯首頁 (5d-2) is where the reader turns it off.
    static let showsBrowserKey = "explore.showsBrowser"
    /// The deleted 首屏頁面 choice: `source:<url>` or `page:<uuid>`. Read only by
    /// `migrateLegacyLanding` and, for a page, `HomePageStore`.
    static let legacyLandingKey = "explore.landing"
    /// The old 探索 root's 格狀 and 每列欄數, now 資源庫's (Phase 5 plan, decision 31): the same
    /// keys, so a reader's choice from before 5d-1b still holds.
    static let showsGridKey = "explore.showsGrid"
    static let gridColumnCountKey = "explore.gridColumnCount"

    // MARK: A source's discover page (Phase 5 plan, decision 31)

    // 5d-1b deleted these with 探索設定; decision 31 brings them back as the discover page's
    // display settings, global for now, under the same keys so a reader's old choices hold.

    static let sourcePageLayoutKey = "explore.sourcePageLayout"
    static let rankedKeywordsKey = "explore.rankedKeywords"
    static let chartBookCountKey = "explore.chartBookCount"
    static let shelfBookCountKey = "explore.shelfBookCount"
    static let preloadCountKey = "explore.preloadCount"

    /// Words that put a category in a numbered chart rather than a shelf of covers: the
    /// set 探索 matched before the list could be edited. A title matches a keyword
    /// whatever its letter case, so `top` also covers `TOP` and `Top`.
    static let defaultRankedKeywords = [
        "榜", "排行", "畅销", "暢銷", "热销", "熱銷", "热门", "熱門", "完本", "完结", "完結", "top",
    ]

    /// Books in each chart column: four, as before the setting.
    static let chartBookCountOptions = [3, 4, 5, 6, 8, 10]
    static let defaultChartBookCount = 4
    /// Books on each shelf; 0 shows the category's whole first page, as shelves always did.
    static let shelfBookCountOptions = [6, 8, 10, 12, 20, 0]
    static let defaultShelfBookCount = 0
    /// Categories queued after the one coming into view; 0, as before, queues none.
    static let preloadCountOptions = [0, 1, 2, 3, 5]
    static let defaultPreloadCount = 0
    /// 封面並發數 (`BookCoverLoader.downloadLimitKey`), in 網路設定; 0, as before, sets no limit.
    static let coverDownloadLimitOptions = [2, 4, 6, 8, 0]

    static var rankedKeywords: [String] {
        guard let stored = UserDefaults.standard.string(forKey: rankedKeywordsKey) else {
            return defaultRankedKeywords
        }
        return decodeKeywords(stored)
    }

    /// One keyword per line: a keyword is a word, never a line break.
    static func encodeKeywords(_ keywords: [String]) -> String {
        keywords.joined(separator: "\n")
    }

    static func decodeKeywords(_ raw: String) -> [String] {
        raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    static var chartBookCount: Int {
        UserDefaults.standard.object(forKey: chartBookCountKey) as? Int ?? defaultChartBookCount
    }

    static var preloadCount: Int {
        UserDefaults.standard.object(forKey: preloadCountKey) as? Int ?? defaultPreloadCount
    }

    /// A saved 首屏頁面 source becomes the home's 範圍, once (Phase 5 plan, settled decision 13):
    /// only when the reader has not picked a 範圍 and the source still exists. A custom page is
    /// left for `HomePageStore`, which selects its 首頁配置 when the pages move in (5d-4);
    /// anything else is dropped.
    static func migrateLegacyLanding(sourceURLs: Set<String>, defaults: UserDefaults = .standard) {
        guard let landing = defaults.string(forKey: legacyLandingKey) else { return }
        if landing.hasPrefix("page:") { return }
        defer { defaults.removeObject(forKey: legacyLandingKey) }
        let sourcePrefix = "source:"
        guard landing.hasPrefix(sourcePrefix), defaults.object(forKey: scopeKey) == nil else { return }
        let url = String(landing.dropFirst(sourcePrefix.count))
        guard sourceURLs.contains(url) else { return }
        defaults.set(ExploreScope.source(SourceInstanceKey(type: .bookSource, id: url)).rawValue, forKey: scopeKey)
    }
}

enum ExploreMode: String, CaseIterable, Sendable {
    case publicLibraries = "libraries"
    case bookSources = "sources"

    static func initialValue(hasImportedSources: Bool) -> Self {
        hasImportedSources ? .bookSources : .publicLibraries
    }

    static func storedValue(_ rawValue: String?, hasImportedSources: Bool) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? initialValue(hasImportedSources: hasImportedSources)
    }

    static func effective(stored: Self, hasImportedSources: Bool, librariesAvailable: Bool) -> Self {
        guard librariesAvailable else { return .bookSources }
        return hasImportedSources ? stored : .publicLibraries
    }

    static func initializeIfNeeded(hasImportedSources: Bool, defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: ExploreSettings.modeKey) == nil else { return }
        defaults.set(initialValue(hasImportedSources: hasImportedSources).rawValue, forKey: ExploreSettings.modeKey)
    }
}

/// The home's 範圍 (design §13.3): 全部 shows the sections; one source shows its own page in
/// place. Stored as a string; one this build cannot read is 全部.
enum ExploreScope: Hashable, Sendable {
    case all
    case source(SourceInstanceKey)

    init(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let type = ProviderType(rawValue: parts[0]), !parts[1].isEmpty else {
            self = .all
            return
        }
        self = .source(SourceInstanceKey(type: type, id: parts[1]))
    }

    var rawValue: String {
        switch self {
        case .all: ""
        case .source(let key): key.type.rawValue + ":" + key.id
        }
    }
}

/// How a source's page lays out its categories.
enum ExploreSourcePageLayout: String, CaseIterable, Identifiable {
    /// Legado's: the categories along the top, the chosen one's books listed below.
    case list
    /// Each category as a shelf of covers or a numbered chart — Apple Books' store.
    case magazine

    static let `default` = ExploreSourcePageLayout.magazine

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .list: "列表"
        case .magazine: "雜誌"
        }
    }

    var systemImage: String {
        switch self {
        case .list: "list.bullet"
        case .magazine: "square.grid.2x2"
        }
    }
}
