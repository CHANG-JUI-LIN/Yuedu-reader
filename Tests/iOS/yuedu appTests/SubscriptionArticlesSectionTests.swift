import Foundation
import Testing
@testable import yuedu_app

/// Unified library 5g: 訂閱的最新文章 (Phase 5 plan, decision 26) reads the articles the RSS tab
/// stored, newest first, as articles: never a work, never in 最新, never under a library's 範圍.
@MainActor
@Suite("Subscription articles section", .serialized)
struct SubscriptionArticlesSectionTests {
    private let section = HomeSection(layout: .row, binding: .subscriptionArticles)

    private func makeStore() throws -> (RSSStore, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SubscriptionArticles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (RSSStore(storageDirectory: folder), { try? FileManager.default.removeItem(at: folder) })
    }

    private func articles(_ entries: [CollectionEntry]) -> [SubscriptionArticle] {
        entries.compactMap { if case .article(let article) = $0 { article } else { nil } }
    }

    @Test("the binding is written as its own type and read back")
    func roundTrip() throws {
        let data = try JSONEncoder().encode(section)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((json["binding"] as? [String: Any])?["type"] as? String == "subscriptionArticles")
        #expect(try JSONDecoder().decode(HomeSection.self, from: data) == section)
        #expect(HomeSectionBinding.appData.contains(.subscriptionArticles))
        #expect(HomeSectionBinding.subscriptionArticles.contentOwner == .appData)
        #expect(section.displayTitle(sourceName: "") == localized("訂閱的最新文章"))
    }

    @Test("the newest articles of every feed, in the RSS tab's order, with the feed's name and read state")
    func newestFirst() async throws {
        let (store, cleanUp) = try makeStore()
        defer { cleanUp() }
        var first = RSSSource(name: "甲", url: "https://a.example/feed", sortOrder: 0)
        first.enabled = false
        let second = RSSSource(name: "乙", url: "https://b.example/feed", sortOrder: 1)
        store.addSourcesReturningAdded([first, second])
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        store.mergeFetchedItems((0..<15).map {
            RSSItem(id: "a\($0)", title: "甲\($0)", link: "https://a.example/\($0)", pubDate: base.addingTimeInterval(Double($0) * 120),
                    imageURL: "http://a.example/\($0).jpg", sourceId: first.id)
        }, for: first.id)
        store.mergeFetchedItems((0..<15).map {
            RSSItem(id: "b\($0)", title: "乙\($0)", link: "https://b.example/\($0)", pubDate: base.addingTimeInterval(Double($0) * 120 + 60),
                    sourceId: second.id)
        }, for: second.id)
        store.markRead(articleId: "b14", isRead: true)

        let provider = SubscriptionArticlesProvider(store: store)
        #expect(provider.loadPolicy(for: section) == .local)
        let loaded = articles(try await provider.load(section))

        #expect(loaded.map(\.id) == Array(store.allArticles().prefix(HomeRow.limit).map(\.id)))
        #expect(loaded.count == HomeRow.limit)
        #expect(loaded.prefix(3).map(\.id) == ["b14", "a14", "b13"])
        #expect(loaded[0].feedName == "乙" && loaded[0].isRead)
        #expect(loaded[1].feedName == "甲" && !loaded[1].isRead)
        // http pictures are upgraded as the RSS tab's rows load them.
        #expect(loaded[1].imageURL == URL(string: "https://a.example/14.jpg"))
        #expect(loaded[0].imageURL == nil)
    }

    @Test("no feed, no article: the section takes no room")
    func emptyStore() async throws {
        let (store, cleanUp) = try makeStore()
        defer { cleanUp() }
        #expect(try await SubscriptionArticlesProvider(store: store).load(section).isEmpty)
    }

    @Test("it serves no other section, 最新 included, so its key is never written into 最新's settings")
    func onlyItsOwnSection() {
        let provider = SubscriptionArticlesProvider()
        for binding in [HomeSectionBinding.latest, .continueReading, .related, .nextInSeries, .aozoraNew] {
            #expect(provider.loadPolicy(for: HomeSection(layout: .row, binding: binding)) == nil)
        }
        #expect(provider.instance == SubscriptionArticlesProvider.instanceKey)
        #expect(provider.instance != .localLibrary)
    }

    private func row(_ entries: [CollectionEntry]) -> HomeModel.Row {
        let key = SubscriptionArticlesProvider.instanceKey
        return HomeModel.Row(id: HomeModel.rowID(section: section.id, source: key), section: section, source: key,
                             sourceName: "", policy: .local, state: .loaded(entries))
    }

    private func article(_ id: String) -> CollectionEntry {
        .article(SubscriptionArticle(id: id, title: id, feedName: "", date: .now, imageURL: nil, isRead: false))
    }

    @Test("the articles keep their order under 偏好閱讀語言, and a library's 範圍 leaves the section out")
    func orderAndScope() {
        let entries = ["3", "2", "1"].map(article)
        let languages = ReadingLanguagePreferences(languages: ["en"], scope: .only)
        let groups = HomeScopeFilter.groups([row(entries)], in: nil, languages: languages)
        #expect(groups.count == 1)
        guard case .loaded(let shown) = groups[0].state else { Issue.record("not loaded"); return }
        #expect(shown == entries)

        let gutenberg = SourceInstanceKey(type: .gutenberg, id: PublicLibraryID.gutenberg.rawValue)
        #expect(HomeScopeFilter.groups([row(entries)], in: gutenberg).isEmpty)
    }

    @Test("a row's articles are drawn as articles, never as book cards")
    func rowContent() {
        let content = HomeRowContent(entries: ["1", "2"].map(article), status: { _ in nil }, shelfBooks: [:])
        #expect(content.cards.isEmpty)
        #expect(content.articles.map(\.id) == ["1", "2"])
        #expect(!content.isEmpty)
    }

    @Test("the UI tests' feed is stored by its argument and taken away by any launch without it")
    func testSeedIsRemoved() throws {
        let (store, cleanUp) = try makeStore()
        defer { cleanUp() }
        let kept = RSSSource(name: "留下", url: "https://kept.example/feed", sortOrder: 0)
        store.addSourcesReturningAdded([kept])
        store.seedForTesting()
        #expect(store.sources.contains { $0.url == RSSStore.testSeedFeedURL && !$0.enabled })
        #expect(store.allArticles().filter { !$0.isRead }.count == 2)

        store.removeTestSeed()
        #expect(store.sources.map(\.url) == [kept.url])
        #expect(store.allArticles().isEmpty)
        #expect(store.totalUnreadCount() == 0)
    }
}

