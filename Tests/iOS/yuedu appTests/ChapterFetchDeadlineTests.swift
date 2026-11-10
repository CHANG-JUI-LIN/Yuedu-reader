import Foundation
import Testing
import os
@testable import yuedu_app

/// A chapter takes as long as its requests take, as in Legado: `WebBook.getContentAwait` sets no
/// deadline above OkHttp's 60 s call timeout and `BackstageWebView`'s 60 s. A 35 s cap over the
/// whole chapter raced the fetch and failed pages those limits allow — 17k's WebView chapter
/// (YCK 1330#54) finished loading at 37 s and read `Chapter load timeout`.
@Suite("Chapter fetch has no deadline of its own", .serialized)
struct ChapterFetchDeadlineTests {
    private static func source() -> BookSource {
        var source = BookSource(
            bookSourceUrl: "https://\(SlowChapterURLProtocol.host)/source#\(UUID().uuidString)",
            bookSourceName: "Slow chapter"
        )
        source.ruleContent.content = "#content@html"
        return source
    }

    /// The page answers after 36 s, past the old cap and inside the transport's 60 s.
    @Test("a chapter page that answers after 36 s is read", .timeLimit(.minutes(2)))
    func slowPageIsRead() async throws {
        let fetcher = BookSourceFetcher(webFetcher: WebFetcher(session: SlowChapterURLProtocol.session()))
        let bookId = UUID()
        defer { fetcher.clearAllChapterCache(bookId: bookId) }
        let ref = OnlineChapterRef(
            index: 0, title: "第一章",
            url: "https://\(SlowChapterURLProtocol.host)/after/36/\(UUID().uuidString)"
        )

        let started = ContinuousClock.now
        let package = try await fetcher.fetchChapterPackage(ref: ref, bookId: bookId, source: Self.source())

        #expect(package.content.contains("慢慢送来的正文"))
        #expect(ContinuousClock.now - started >= .seconds(36))
    }

    /// With no deadline inside, leaving the chapter is what stops a slow fetch: cancelling the
    /// caller must reach the request rather than wait for the page.
    @Test("cancelling the caller stops a slow chapter fetch at once", .timeLimit(.minutes(1)))
    func cancellationStopsSlowFetch() async throws {
        let fetcher = BookSourceFetcher(webFetcher: WebFetcher(session: SlowChapterURLProtocol.session()))
        let bookId = UUID()
        defer { fetcher.clearAllChapterCache(bookId: bookId) }
        let id = UUID().uuidString
        let ref = OnlineChapterRef(
            index: 0, title: "第一章", url: "https://\(SlowChapterURLProtocol.host)/after/50/\(id)"
        )
        let source = Self.source()

        let task = Task {
            try await fetcher.fetchChapterPackage(ref: ref, bookId: bookId, source: source)
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while !SlowChapterURLProtocol.isLoading(id), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(SlowChapterURLProtocol.isLoading(id), "the chapter request never went out")

        let cancelled = ContinuousClock.now
        task.cancel()
        let result = await task.result

        #expect((try? result.get()) == nil, "a cancelled fetch must not come back with the chapter")
        #expect(ContinuousClock.now - cancelled < .seconds(3))
        #expect(SlowChapterURLProtocol.wasStopped(id), "the request itself must be stopped")
    }
}

/// `/after/<seconds>/<id>` answers with a chapter page after that many seconds.
private final class SlowChapterURLProtocol: URLProtocol, @unchecked Sendable {
    static let host = "slow-chapter.test"
    private static let loading = OSAllocatedUnfairLock<Set<String>>(initialState: [])
    private static let stoppedIDs = OSAllocatedUnfairLock<Set<String>>(initialState: [])
    private let stopped = OSAllocatedUnfairLock(initialState: false)

    static func isLoading(_ id: String) -> Bool { loading.withLock { $0.contains(id) } }
    static func wasStopped(_ id: String) -> Bool { stoppedIDs.withLock { $0.contains(id) } }

    /// The production session's limits (`WebFetcher.defaultSessionConfiguration`).
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowChapterURLProtocol.self]
        configuration.timeoutIntervalForRequest = WebFetcher.sourceRequestTimeout
        configuration.timeoutIntervalForResource = WebFetcher.sourceRequestTimeout
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var id: String { request.url?.lastPathComponent ?? "" }

    override func startLoading() {
        guard let url = request.url else { return }
        let parts = url.pathComponents
        let seconds = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
        let id = self.id
        Self.loading.withLock { _ = $0.insert(id) }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(seconds)) { [self] in
            guard !stopped.withLock({ $0 }) else { return }
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            let page = "<html><body><div id=\"content\"><p>慢慢送来的正文，第一段。</p><p>第二段。</p></div></body></html>"
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(page.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
        let id = self.id
        Self.stoppedIDs.withLock { _ = $0.insert(id) }
    }
}
