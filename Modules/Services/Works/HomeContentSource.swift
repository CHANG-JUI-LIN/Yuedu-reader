import Foundation

// Unified library 5d-5: 選擇內容來源 (design §13.3, Rex's 「選擇內容來源」; Phase 5 plan,
// decision 23). What a section can show, grouped by who serves it:
// - App 資料: 繼續閱讀, 最新 and 相關, which gather across sources (decision 23), and
//   訂閱的最新文章, the RSS subscriptions' articles (5g, decision 26);
// - 書庫: each OPDS or Calibre connection's feeds, Gutenberg's lists and feeds, 青空文庫's
//   新着 and indexes. A WebDAV connection serves 最新 only, so it is not listed;
// - 來源配置: each book source's discover categories;
// - 模組: each installed module's lists (Phase 6f).
// 外部服務 waits for Phase 3 (decision 23). 最近加入書架, 書架分組 and 閱讀統計 have no binding.

/// Who serves a binding, as 選擇內容來源 groups it and marks the current one 「目前」.
enum HomeContentOwner: Hashable, Sendable {
    case appData
    case connection(id: String)
    case gutenberg
    case aozora
    case bookSource(url: String)
    /// An installed module (Phase 6f).
    case module(id: String)
    /// The app's own modules: AI 推薦 (AI 推薦 plan 8c).
    case official
}

extension HomeSectionBinding {
    /// Nil for 我的書庫 and a later build's binding, which the form does not offer.
    var contentOwner: HomeContentOwner? {
        switch self {
        case .continueReading, .latest, .related, .nextInSeries, .subscriptionArticles, .forYou: .appData
        case .opdsFeed(let connectionID, _): .connection(id: connectionID)
        case .gutenbergCollection, .gutenbergLists, .gutenbergFeed, .gutenbergShelf: .gutenberg
        case .aozoraNew, .aozoraIndex: .aozora
        case .sourceCategories(let references): references.first.map { .bookSource(url: $0.sourceURL) }
        case .module(let moduleID, _): .module(id: moduleID)
        case .aiRecommendations: .official
        case .myLibrary, .unknown: nil
        }
    }

    /// App 資料's choices, in the order they are listed.
    static let appData: [HomeSectionBinding] = [.continueReading, .nextInSeries, .forYou, .latest, .related, .subscriptionArticles]

    /// 官方模組's choices.
    static let official: [HomeSectionBinding] = [.aiRecommendations]

    /// 青空文庫's choices: 新着, then each index.
    static let aozora: [HomeSectionBinding] = [.aozoraNew] + ["authors", "titles", "categories"].map { .aozoraIndex(kind: $0) }

    /// Gutenberg's bundled lists, which send no request: 精選書單, all of them as cards, then each
    /// list as a section of its own.
    static var gutenbergCollections: [HomeSectionBinding] {
        [.gutenbergLists] + PublicLibraryCollection.all.map { .gutenbergCollection(id: $0.id) }
    }

    /// A section of lists, drawn as 專題集合's cards whatever its stored layout.
    var listsCollections: Bool { self == .gutenbergLists }
}

extension HomeSection {
    /// `self` showing `binding`: the parameters of the binding it showed go with it. The title
    /// the reader gave stays.
    func showing(_ binding: HomeSectionBinding, parameters: [String: String]) -> HomeSection {
        var section = self
        section.binding = binding
        section.parameters = parameters
        return section
    }
}
