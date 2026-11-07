import Foundation
import Testing
import os
@testable import yuedu_app

/// A page far larger than any chapter is refused at the fetch, before anything parses it.
///
/// 3.0.0 (143) died of memory five times on such pages during 書源檢查 and normal reading
/// (Crashlytics dd961765, b18ea7cd, 78aa7546, a8e12705, 038cde45): `WebFetcher` read the whole
/// body, and SwiftSoup plus `ChapterContentCleaner`'s regexes then asked for 51–145 MB in one
/// allocation. The fetch now stops reading at `WebFetcher.responseByteLimit` and says so.
@Suite("Oversized responses", .serialized)
struct OversizedResponseTests {
    private static let fiftyMB = 50 * 1024 * 1024

    @Test("a 50 MB body with no Content-Length is cut off and reported, not parsed")
    func streamedOversizedBodyIsRefused() async throws {
        let fetcher = WebFetcher(session: OversizedURLProtocol.session())
        let url = try #require(URL(string: "https://\(OversizedURLProtocol.host)/stream/\(UUID().uuidString)"))
        OversizedURLProtocol.reset()

        do {
            _ = try await fetcher.fetchHTML(url: url, method: "GET", body: nil, headers: [:], baseURL: "")
            Issue.record("a 50 MB page must not come back")
        } catch let FetchError.responseTooLarge(bytes, limit) {
            #expect(limit == WebFetcher.responseByteLimit)
            #expect(bytes > limit)
        }
        #expect(
            OversizedURLProtocol.chunksSent < OversizedURLProtocol.chunkCount,
            "the download must stop at the limit, not after the whole body arrived"
        )
    }

    @Test("a declared 50 MB Content-Length is refused before the body is read")
    func declaredOversizedBodyIsRefused() async throws {
        let fetcher = WebFetcher(session: OversizedURLProtocol.session())
        let url = try #require(URL(string: "https://\(OversizedURLProtocol.host)/declared/\(UUID().uuidString)"))
        OversizedURLProtocol.reset()

        do {
            _ = try await fetcher.fetchHTML(url: url, method: "GET", body: nil, headers: [:], baseURL: "")
            Issue.record("a 50 MB page must not come back")
        } catch let FetchError.responseTooLarge(bytes, limit) {
            #expect(bytes == Self.fiftyMB)
            #expect(limit == WebFetcher.responseByteLimit)
        }
        #expect(OversizedURLProtocol.chunksSent < OversizedURLProtocol.chunkCount)
    }

    @Test("a page under the limit still arrives whole")
    func pageUnderLimitArrives() async throws {
        let fetcher = WebFetcher(session: OversizedURLProtocol.session())
        let url = try #require(URL(string: "https://\(OversizedURLProtocol.host)/small/\(UUID().uuidString)"))
        OversizedURLProtocol.reset()

        let html = try await fetcher.fetchHTML(url: url, method: "GET", body: nil, headers: [:], baseURL: "")
        #expect(html.contains("第一段正文"))
        #expect(html.utf8.count == OversizedURLProtocol.smallPage.count)
    }

    /// The bounded read against the `data(for:)` it replaced, on a 300 KB page (a chapter's p99 is
    /// ~100 KB, a TOC's ~800 KB): a per-chunk delegate must cost nothing a fetch would notice.
    @Test("reading a 300 KB page bounded costs what data(for:) cost")
    func boundedReadCostsWhatDataForCost() async throws {
        let session = OversizedURLProtocol.session()
        func median(_ work: () async throws -> Void) async rethrows -> Double {
            var samples: [Double] = []
            for _ in 0..<30 {
                let start = ContinuousClock.now
                try await work()
                let elapsed = ContinuousClock.now - start
                samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
            }
            return samples.sorted()[samples.count / 2]
        }
        let request = URLRequest(url: try #require(URL(string: "https://\(OversizedURLProtocol.host)/page300/x")))
        _ = try await session.data(for: request)
        let before = try await median {
            let (data, _) = try await session.data(for: request)
            #expect(data.count == OversizedURLProtocol.page300.count)
        }
        let after = try await median {
            let (data, _) = try await BoundedResponseLoader.load(
                request, session: session, limit: WebFetcher.responseByteLimit
            )
            #expect(data.count == OversizedURLProtocol.page300.count)
        }
        print("⏱ 300KB page: data(for:) median \(String(format: "%.2f", before)) ms, bounded median \(String(format: "%.2f", after)) ms")
        #expect(after < before * 2 + 2, "bounded \(after) ms vs data(for:) \(before) ms")
    }

    /// 書源檢查's content probe on a source with no content rule: the route that went on to
    /// `extractWebContentSinglePage` → `WebNovelParser` → `ChapterContentCleaner` (dd961765).
    @Test("a chapter without a content rule fails with the size error")
    func chapterWithoutContentRuleFails() async throws {
        try await expectChapterFails(contentRule: "")
    }

    /// Normal reading: the rule's text went to `normalizeLegadoContent` → SwiftSoup (038cde45).
    @Test("a chapter with a content rule fails with the size error")
    func chapterWithContentRuleFails() async throws {
        try await expectChapterFails(contentRule: "#content@html")
    }

    private func expectChapterFails(contentRule: String) async throws {
        let fetcher = BookSourceFetcher(webFetcher: WebFetcher(session: OversizedURLProtocol.session()))
        var source = BookSource(
            bookSourceUrl: "https://\(OversizedURLProtocol.host)/source#\(UUID().uuidString)",
            bookSourceName: "Oversized"
        )
        source.ruleContent.content = contentRule
        let bookId = UUID()
        defer { fetcher.clearAllChapterCache(bookId: bookId) }
        OversizedURLProtocol.reset()

        let ref = OnlineChapterRef(
            index: 0, title: "第一章", url: "https://\(OversizedURLProtocol.host)/stream/\(UUID().uuidString)"
        )
        do {
            _ = try await fetcher.fetchChapterPackage(ref: ref, bookId: bookId, source: source)
            Issue.record("an oversized chapter page must not become a chapter")
        } catch let FetchError.responseTooLarge(_, limit) {
            #expect(limit == WebFetcher.responseByteLimit)
        }
        #expect(OversizedURLProtocol.chunksSent < OversizedURLProtocol.chunkCount)
    }
}

/// `/stream/…` sends 50 MB of chapter-like HTML in 1 MB chunks with no Content-Length, paced a
/// few milliseconds apart so a cancelled load is seen to stop sending before the last chunk. `/declared/…` announces 50 MB up front.
/// `/small/…` is an ordinary chapter page.
private final class OversizedURLProtocol: URLProtocol, @unchecked Sendable {
    static let host = "oversized-source.test"
    static let smallPage = Data(
        ("<html><body><div id=\"content\">"
            + (1...30).map { "<p>第\($0 == 1 ? "一" : "\($0)")段正文，内容足够长。</p>" }.joined()
            + "</div></body></html>").utf8
    )
    static let chunkCount = 50
    static let page300: Data = {
        let paragraph = Data("<p>第一段正文，内容足够长，让正文识别认出这是章节。</p>\n".utf8)
        var data = Data(capacity: 300 * 1024)
        while data.count < 300 * 1024 { data.append(paragraph) }
        return data
    }()
    private static let chunk: Data = {
        let paragraph = Data("<div><p>重复的段落文字重复的段落文字重复的段落文字。</p></div>\n".utf8)
        var data = Data(capacity: 1024 * 1024)
        while data.count < 1024 * 1024 { data.append(paragraph) }
        return data.prefix(1024 * 1024)
    }()
    private static let sent = OSAllocatedUnfairLock(initialState: 0)
    private let stopped = OSAllocatedUnfairLock(initialState: false)
    private let queue = DispatchQueue(label: "OversizedURLProtocol")

    static var chunksSent: Int { sent.withLock { $0 } }
    static func reset() { sent.withLock { $0 = 0 } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OversizedURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        var headers = ["Content-Type": "text/html; charset=utf-8"]
        if url.path.hasPrefix("/declared/") {
            headers["Content-Length"] = "\(50 * 1024 * 1024)"
        } else if url.path.hasPrefix("/small/") {
            headers["Content-Length"] = "\(Self.smallPage.count)"
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if url.path.hasPrefix("/page300/") {
            client?.urlProtocol(self, didLoad: Self.page300)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if url.path.hasPrefix("/small/") {
            client?.urlProtocol(self, didLoad: Self.smallPage)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        send(remaining: Self.chunkCount)
    }

    private func send(remaining: Int) {
        queue.asyncAfter(deadline: .now() + .milliseconds(5)) { [self] in
            guard !stopped.withLock({ $0 }) else { return }
            guard remaining > 0 else {
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            Self.sent.withLock { $0 += 1 }
            client?.urlProtocol(self, didLoad: Self.chunk)
            send(remaining: remaining - 1)
        }
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
    }
}
