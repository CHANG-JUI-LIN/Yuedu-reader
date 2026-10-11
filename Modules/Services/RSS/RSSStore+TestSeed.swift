import Foundation

#if DEBUG
extension RSSStore {
    /// The feed UI tests read 訂閱的最新文章 from (`-seed-rss-articles`, unified library 5g).
    static let testSeedFeedURL = "http://127.0.0.1:9/yuedu-home-subscription-test.xml"

    /// A feed of two articles, both unread, the first the newest of all. Off, so no refresh
    /// ever fetches its address; the RSS tab and the home read its stored articles alike.
    /// Run again, it marks them unread again, so each test starts from the same place; a launch
    /// without the argument removes it (`removeTestSeed`).
    func seedForTesting(now: Date = Date()) {
        if !sources.contains(where: { $0.url == Self.testSeedFeedURL }) {
            var source = RSSSource(name: "首頁訂閱測試", url: Self.testSeedFeedURL, sortOrder: 0)
            source.enabled = false
            addSourcesReturningAdded([source])
        }
        guard let source = sources.first(where: { $0.url == Self.testSeedFeedURL }) else { return }
        let body = String(repeating: "<p>首頁訂閱測試的文章內文，用來確認文章頁打開了。</p>", count: 20)
        // Dated at launch, so they lead every feed the simulator fetched before.
        let items = [
            RSSItem(id: "yuedu-home-subscription-test-1", title: "首頁訂閱測試文章一", link: "https://example.com/1",
                    pubDate: now, contentHTML: body, sourceId: source.id),
            RSSItem(id: "yuedu-home-subscription-test-2", title: "首頁訂閱測試文章二", link: "https://example.com/2",
                    pubDate: now.addingTimeInterval(-60), contentHTML: body, sourceId: source.id),
        ]
        mergeFetchedItems(items, for: source.id)
        for item in items { markRead(articleId: item.id, isRead: false) }
    }

    /// Takes the test feed away in a launch that did not ask for it, so a simulator a UI test
    /// ran on shows no test feed or unread badge afterwards (as `WorkDetailUITests` deletes
    /// its book). A no-op when it is not there.
    func removeTestSeed() {
        let ids = sources.filter { $0.url == Self.testSeedFeedURL }.map(\.id)
        guard !ids.isEmpty else { return }
        removeSources(ids: ids)
    }
}
#endif
