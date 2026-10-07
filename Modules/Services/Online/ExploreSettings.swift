import Foundation

/// 探索設定 — what the 探索 page and its sources' pages show. Plain `UserDefaults` keys:
/// the views read them with `@AppStorage`, and discover loading reads them here, off the
/// main actor where it has to.
enum ExploreSettings {
    // MARK: 探索頁

    static let modeKey = "explore.mode"
    static let showsGridKey = "explore.showsGrid"
    static let gridColumnCountKey = "explore.gridColumnCount"

    // MARK: 書源頁

    static let sourcePageLayoutKey = "explore.sourcePageLayout"
    static let landingKey = "explore.landing"

    // MARK: 榜單

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
    /// 封面並發數 (`BookCoverLoader.downloadLimitKey`); 0, as before, sets no limit.
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

    static var preloadCount: Int {
        UserDefaults.standard.object(forKey: preloadCountKey) as? Int ?? defaultPreloadCount
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

/// The page 探索 opens straight onto (首屏配置), stored as a string.
enum ExploreLanding: Equatable {
    case off
    /// One of the reader's custom explore pages.
    case customPage(id: UUID)
    case source(url: String)

    private static let customPagePrefix = "page:"
    private static let sourcePrefix = "source:"

    init(rawValue: String) {
        if rawValue.hasPrefix(Self.customPagePrefix),
           let id = UUID(uuidString: String(rawValue.dropFirst(Self.customPagePrefix.count))) {
            self = .customPage(id: id)
        } else if rawValue.hasPrefix(Self.sourcePrefix) {
            let url = String(rawValue.dropFirst(Self.sourcePrefix.count))
            self = url.isEmpty ? .off : .source(url: url)
        } else {
            self = .off
        }
    }

    var rawValue: String {
        switch self {
        case .off: ""
        case .customPage(let id): Self.customPagePrefix + id.uuidString
        case .source(let url): Self.sourcePrefix + url
        }
    }
}
