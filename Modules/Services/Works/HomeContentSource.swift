import Foundation

// Unified library 5d-5: 選擇內容來源 (design §13.3, Rex's 「選擇內容來源」; Phase 5 plan,
// decision 23). What a section can show, grouped by who serves it:
// - App 資料: 繼續閱讀, 最新 and 相關, which gather across sources (decision 23);
// - 書庫: each OPDS or Calibre connection's feeds, Gutenberg's lists and feeds, 青空文庫's
//   新着 and indexes. A WebDAV connection serves 最新 only, so it is not listed;
// - 來源配置: each book source's discover categories.
// 外部服務 waits for Phase 3 (decision 23). 最近加入書架, 書架分組 and 閱讀統計 have no binding.

/// Who serves a binding, as 選擇內容來源 groups it and marks the current one 「目前」.
enum HomeContentOwner: Hashable, Sendable {
    case appData
    case connection(id: String)
    case gutenberg
    case aozora
    case bookSource(url: String)
}

extension HomeSectionBinding {
    /// Nil for 我的書庫 and a later build's binding, which the form does not offer.
    var contentOwner: HomeContentOwner? {
        switch self {
        case .continueReading, .latest, .related: .appData
        case .opdsFeed(let connectionID, _): .connection(id: connectionID)
        case .gutenbergCollection, .gutenbergFeed: .gutenberg
        case .aozoraNew, .aozoraIndex: .aozora
        case .sourceCategories(let references): references.first.map { .bookSource(url: $0.sourceURL) }
        case .myLibrary, .unknown: nil
        }
    }

    /// App 資料's choices, in the order they are listed.
    static let appData: [HomeSectionBinding] = [.continueReading, .latest, .related]

    /// 青空文庫's choices: 新着, then each index.
    static let aozora: [HomeSectionBinding] = [.aozoraNew] + ["authors", "titles", "categories"].map { .aozoraIndex(kind: $0) }

    /// Gutenberg's bundled lists, which send no request.
    static var gutenbergCollections: [HomeSectionBinding] {
        PublicLibraryCollection.all.map { .gutenbergCollection(id: $0.id) }
    }
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
