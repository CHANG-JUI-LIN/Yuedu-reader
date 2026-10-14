import Foundation

// Unified library 5g: 訂閱的最新文章, a section of App 資料 (Phase 5 plan, decision 26; design
// §13.8: RSS joins Explore's sections, but serves articles, never `Book`s). The RSS tab stays
// where it is, with its badge; this only shows what it has already fetched.

/// One article as a home row shows it, frozen when the row loads, so tapping it opens the
/// article the row drew (CLAUDE.md, "Freeze data at search navigation boundaries"). Bounded
/// like `WorkSummary`: a feed's title can be anything.
struct SubscriptionArticle: Hashable, Sendable {
    /// `RSSArticleRecord.id`, which `RSSArticleReaderView` opens.
    let id: String
    let title: String
    /// The feed's name, as the RSS tab names it.
    let feedName: String
    /// `pubDate`, else when it was fetched: the date the RSS tab sorts by.
    let date: Date
    let imageURL: URL?
    let isRead: Bool

    init(id: String, title: String, feedName: String, date: Date, imageURL: URL?, isRead: Bool) {
        self.id = id
        self.title = String(title.prefix(WorkSummary.titleLimit))
        self.feedName = String(feedName.prefix(WorkSummary.authorLengthLimit))
        self.date = date
        self.imageURL = imageURL
        self.isRead = isRead
    }

    init(_ record: RSSArticleRecord, feedName: String) {
        let image = record.imageURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(id: record.id,
                  title: record.title.trimmingCharacters(in: .whitespacesAndNewlines),
                  feedName: feedName,
                  date: record.pubDate ?? record.fetchedAt,
                  // http is upgraded as the RSS tab's rows load images (ATS).
                  imageURL: image.flatMap { $0.isEmpty ? nil : $0.httpsUpgradedURL },
                  isRead: record.isRead)
    }
}

/// Serves 訂閱的最新文章 from the articles the RSS tab has stored; it sends no request. Feeds
/// are fetched through `RSSFeedRefreshService`: by the RSS tab, its background refresh, and
/// 探索's pull to refresh when the home shows this section (decision 29).
///
/// Its key is App 資料's own place on this device (`.library`), not a `ProviderType` of its own:
/// `SourceInstanceKey` is written into files older builds read (書庫順序, 顯示在最新, the work
/// index), whose decoding fails on a type they do not know. It serves no 最新, so it is in
/// none of them, and 範圍 (a library or a book source) leaves it out as it leaves out 繼續閱讀's
/// other places.
@MainActor
final class SubscriptionArticlesProvider: HomeSectionProviding {
    static let instanceKey = SourceInstanceKey(type: .library, id: "subscriptions")

    private let store: RSSStore

    init(store: RSSStore = .shared) {
        self.store = store
    }

    var instance: SourceInstanceKey { Self.instanceKey }
    var displayName: String { localized("RSS 訂閱") }
    var availability: ProviderAvailability { .available }
    /// It reads the articles RSS has already fetched.
    var hosts: [String] { [] }

    func loadPolicy(for section: HomeSection) -> SectionLoadPolicy? {
        guard case .subscriptionArticles = section.binding else { return nil }
        return .local
    }

    /// The newest articles, in the RSS tab's order (`RSSStore.allArticles`, which its 今天,
    /// 所有未讀 and 已加星號 filter). Read or not: the card says which.
    func load(_ section: HomeSection) async throws -> [CollectionEntry] {
        guard case .subscriptionArticles = section.binding else { return [] }
        let names = Dictionary(store.sources.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return store.allArticles().prefix(HomeRow.limit).map { record in
            .article(SubscriptionArticle(record, feedName: names[record.sourceId] ?? ""))
        }
    }
}
