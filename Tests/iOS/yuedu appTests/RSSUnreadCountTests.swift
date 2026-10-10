import Foundation
import Testing
@testable import yuedu_app

/// The RSS tab's badge is computed in the root view's body — on every root render, which
/// a TTS session triggered once per spoken sentence. Counting unread articles must not copy
/// and sort every feed's articles to do it.
@Suite("RSS unread counts", .serialized)
struct RSSUnreadCountTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RSSUnread-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 50 feeds × 200 articles, every other one read, one in ten starred.
    private func populatedStore() throws -> RSSStore {
        let store = RSSStore(storageDirectory: try temporaryDirectory())
        for feed in 0..<50 {
            let source = RSSSource(id: "feed-\(feed)", name: "Feed \(feed)", url: "https://feed.example/\(feed)")
            store.addSource(source)
            let items = (0..<200).map { index in
                RSSItem(
                    id: "https://example.com/\(feed)/\(index)", title: "Item \(index)",
                    link: "https://example.com/\(feed)/\(index)",
                    pubDate: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index * 3_600)),
                    description: "Summary", author: nil, sourceId: source.id
                )
            }
            store.mergeFetchedItems(items, for: source.id)
            for (index, item) in items.enumerated() where index.isMultiple(of: 2) {
                store.markRead(articleId: item.id, isRead: true)
            }
            for (index, item) in items.enumerated() where index.isMultiple(of: 10) {
                store.toggleFavorite(articleId: item.id)
            }
        }
        return store
    }

    @Test("unread counts match counting the listed articles")
    func countsMatchListedArticles() throws {
        let store = try populatedStore()
        let listedTotal = store.sources.reduce(0) { $0 + store.articles(for: $1.id).filter { !$0.isRead }.count }
        #expect(store.totalUnreadCount() == listedTotal)
        #expect(store.totalUnreadCount() == 50 * 100)
        for source in store.sources.prefix(5) {
            #expect(store.unreadCount(for: source.id) == store.articles(for: source.id).filter { !$0.isRead }.count)
        }
        for feed in RSSSmartFeedKind.allCases {
            #expect(store.unreadCount(for: feed) == store.articles(for: feed).filter { !$0.isRead }.count)
        }
    }

    @Test(
        "the total unread count over 10 000 articles",
        .enabled(if: ProcessInfo.processInfo.environment["SHELF_RENDER_SCALE_TESTS"] == "1"
            || ProcessInfo.processInfo.environment["TEST_RUNNER_SHELF_RENDER_SCALE_TESTS"] == "1")
    )
    func totalUnreadCountCost() throws {
        let store = try populatedStore()
        let startedAt = ProcessInfo.processInfo.systemUptime
        var total = 0
        for _ in 0..<20 { total &+= store.totalUnreadCount() }
        let ms = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000 / 20
        print("SCALE rssUnread articles=10000 perCallMs=\(String(format: "%.2f", ms)) total=\(total / 20)")
    }
}
