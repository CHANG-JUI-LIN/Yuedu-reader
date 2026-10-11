import Foundation

/// The 探索 page's stored choices: plain `UserDefaults` keys, read with `@AppStorage`.
/// How a section looks is the section's own (unified library 5d); nothing here is global.
enum ExploreSettings {
    /// The old roots' 公有書庫／來源配置 choice, kept because the home reads it once for its
    /// default sections.
    static let modeKey = "explore.mode"
    /// The home's 範圍: 全部, or one source shown in place (`ExploreScope`).
    static let scopeKey = "explore.scope"
    /// Whether 範圍 offers the browser (unified library 5d-1, settled decision 12). On by default;
    /// 編輯首頁 (5d-2) is where the reader turns it off.
    static let showsBrowserKey = "explore.showsBrowser"
    /// The deleted 首屏頁面 choice: `source:<url>` or `page:<uuid>`. Read only by
    /// `migrateLegacyLanding`.
    static let legacyLandingKey = "explore.landing"

    /// Words that put a category in a numbered chart rather than a shelf of covers. A title
    /// matches a keyword whatever its letter case, so `top` also covers `TOP` and `Top`.
    static let rankedKeywords = [
        "榜", "排行", "畅销", "暢銷", "热销", "熱銷", "热门", "熱門", "完本", "完结", "完結", "top",
    ]
    /// Books in each chart column.
    static let chartBookCount = 4

    /// A saved 首屏頁面 source becomes the home's 範圍, once (Phase 5 plan, settled decision 13):
    /// only when the reader has not picked a 範圍 and the source still exists. A custom page
    /// stays saved for the configurations of 5d-4; anything else is dropped.
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
