import Foundation
import Testing
import os
@testable import yuedu_app

@Suite("RSS background refresh", .serialized)
@MainActor
struct RSSBackgroundRefreshTests {
    @Test("the installed app permits and registers the refresh task at launch")
    func taskRegistration() {
        #expect((Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("fetch") == true)
        #expect((Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String])?.contains(RSSBackgroundRefresh.identifier) == true)
        #expect(RSSBackgroundRefresh.shared.isRegistered)
    }

    @Test("refresh merges enabled feeds, notifies new articles, and preserves read state")
    func refreshAndMerge() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.store.addSource(RSSSource(id: "ok", name: "Fixture", url: "https://rss.invalid/ok"))
        var disabled = RSSSource(id: "disabled", name: "Disabled", url: "https://rss.invalid/disabled")
        disabled.enabled = false
        fixture.store.addSource(disabled)
        // Initial import deliberately stays quiet. Model an existing subscription
        // receiving a genuinely new article, then refreshing that same article again.
        let initialArticles = fixture.store.mergeFetchedItems([
            RSSItem(id: "older", title: "Older article", link: "https://rss.invalid/older", pubDate: nil, description: "Older body", author: nil, sourceId: "ok"),
        ], for: "ok")
        #expect(initialArticles.isEmpty)
        var notifications: [String] = []
        let first = await RSSFeedRefreshService.refreshAll(store: fixture.store, makeFetcher: fixture.makeFetcher, notify: { articles, _ in
            notifications += articles.map(\.id)
        })
        #expect(first)
        let article = try #require(fixture.store.articles(for: "ok").first)
        fixture.store.markRead(articleId: article.id, isRead: true)
        fixture.store.toggleFavorite(articleId: article.id)
        let second = await RSSFeedRefreshService.refreshAll(store: fixture.store, makeFetcher: fixture.makeFetcher, notify: { articles, _ in
            notifications += articles.map(\.id)
        })
        #expect(second)
        #expect(notifications == [article.id])
        #expect(fixture.store.articles(for: "ok").first?.isRead == true)
        #expect(fixture.store.articles(for: "ok").first?.isFavorite == true)
        #expect(RSSRefreshHTTPStub.paths.withLock { $0 } == ["/ok", "/ok"])
        #expect(fixture.store.feedMetadata(for: "ok")?.etag == "fixture-v1")
    }

    @Test("a failed feed does not prevent subsequent feeds from refreshing")
    func failureContinues() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.store.addSource(RSSSource(id: "bad", name: "Bad", url: "https://rss.invalid/fail"))
        fixture.store.addSource(RSSSource(id: "ok", name: "Good", url: "https://rss.invalid/ok"))
        let succeeded = await RSSFeedRefreshService.refreshAll(store: fixture.store, makeFetcher: fixture.makeFetcher, notify: { _, _ in })
        #expect(!succeeded)
        #expect(fixture.store.articles(for: "bad").isEmpty)
        #expect(fixture.store.articles(for: "ok").count == 1)
        #expect(RSSRefreshHTTPStub.paths.withLock { $0 } == ["/fail", "/ok"])
    }

    @Test("expiration cancellation stops the in-flight request and does not fetch the next feed")
    func cancellationStopsRefresh() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.store.addSource(RSSSource(id: "wait", name: "Wait", url: "https://rss.invalid/wait"))
        fixture.store.addSource(RSSSource(id: "next", name: "Next", url: "https://rss.invalid/ok"))
        let (events, continuation) = AsyncStream<String>.makeStream()
        RSSRefreshHTTPStub.events.withLock { $0 = continuation }
        let work = Task {
            await RSSFeedRefreshService.refreshAll(store: fixture.store, makeFetcher: fixture.makeFetcher, notify: { _, _ in
                Issue.record("A canceled refresh must not notify")
            })
        }
        for await path in events where path == "/wait" { break }
        work.cancel()
        #expect(await work.value == false)
        #expect(fixture.store.allArticles().isEmpty)
        #expect(RSSRefreshHTTPStub.paths.withLock { $0 } == ["/wait"])
        continuation.finish()
    }

    @Test("disabling a source during refresh prevents a stale response from being merged")
    func disabledDuringRefresh() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.store.addSource(RSSSource(id: "ok", name: "Good", url: "https://rss.invalid/ok"))
        let succeeded = await RSSFeedRefreshService.refreshAll(store: fixture.store, makeFetcher: {
            fixture.store.sources[0].enabled = false
            return fixture.makeFetcher()
        }, notify: { _, _ in Issue.record("A disabled source must not notify") })
        #expect(succeeded)
        #expect(fixture.store.allArticles().isEmpty)
    }

    /// Crashlytics d88da8b2 (2026-10-19): 189 feeds refreshed hourly wrote 1084 MB a day,
    /// because every feed's merge rewrote the article file of every feed.
    @Test("a refresh of many feeds writes the article file once, and not at all when nothing changed")
    func refreshWritesArticlesOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let ids = ["a", "b", "c"]
        for id in ids {
            fixture.store.addSource(RSSSource(id: id, name: id, url: "https://rss.invalid/ok"))
        }
        let articles = fixture.store.writeCounts["rss_articles.json", default: 0]
        let metadata = fixture.store.writeCounts["rss_feed_metadata.json", default: 0]

        #expect(await RSSFeedRefreshService.refreshAll(store: fixture.store, makeFetcher: fixture.makeFetcher, notify: { _, _ in }))
        #expect(fixture.store.writeCounts["rss_articles.json", default: 0] == articles + 1)
        #expect(fixture.store.writeCounts["rss_feed_metadata.json", default: 0] == metadata + 1)

        #expect(await RSSFeedRefreshService.refreshAll(store: fixture.store, makeFetcher: fixture.makeFetcher, notify: { _, _ in }))
        #expect(fixture.store.writeCounts["rss_articles.json", default: 0] == articles + 1)
        #expect(fixture.store.writeCounts["rss_feed_metadata.json", default: 0] == metadata + 2)

        let reloaded = RSSStore(storageDirectory: fixture.root)
        for id in ids {
            #expect(reloaded.articles(for: id).count == 1)
            #expect(reloaded.feedMetadata(for: id)?.etag == "fixture-v1")
        }
    }

    @Test("a refresh cut short by its background task expiring keeps the feeds it merged")
    func cancelledRefreshKeepsMergedFeeds() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.store.addSource(RSSSource(id: "done", name: "Done", url: "https://rss.invalid/ok"))
        fixture.store.addSource(RSSSource(id: "wait", name: "Wait", url: "https://rss.invalid/wait"))
        let (events, continuation) = AsyncStream<String>.makeStream()
        RSSRefreshHTTPStub.events.withLock { $0 = continuation }
        let work = Task {
            await RSSFeedRefreshService.refreshAll(store: fixture.store, makeFetcher: fixture.makeFetcher, notify: { _, _ in })
        }
        for await path in events where path == "/wait" { break }
        work.cancel()
        #expect(await work.value == false)
        continuation.finish()

        let reloaded = RSSStore(storageDirectory: fixture.root)
        #expect(reloaded.articles(for: "done").count == 1)
        #expect(reloaded.articles(for: "wait").isEmpty)
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let store: RSSStore
        let session: URLSession

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = RSSStore(storageDirectory: root)
            RSSRefreshHTTPStub.paths.withLock { $0 = [] }
            RSSRefreshHTTPStub.events.withLock { $0 = nil }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [RSSRefreshHTTPStub.self]
            session = URLSession(configuration: configuration)
        }

        func makeFetcher() -> RSSFetcher { RSSFetcher(session: session) }

        func cleanup() {
            session.invalidateAndCancel()
            RSSRefreshHTTPStub.events.withLock { $0?.finish(); $0 = nil }
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private final class RSSRefreshHTTPStub: URLProtocol {
    static let paths = OSAllocatedUnfairLock(initialState: [String]())
    static let events = OSAllocatedUnfairLock<AsyncStream<String>.Continuation?>(initialState: nil)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.paths.withLock { $0.append(url.path) }
        _ = Self.events.withLock { $0?.yield(url.path) }
        if url.path == "/wait" { return }
        let status = url.path == "/fail" ? 503 : 200
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/rss+xml", "ETag": "fixture-v1"])!
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel><title>Fixture</title><link>https://rss.invalid</link><description>Test feed</description>
        <item><title>Article</title><link>https://rss.invalid/article</link><guid>article</guid><description>Article body.</description></item>
        </channel></rss>
        """
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(xml.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
