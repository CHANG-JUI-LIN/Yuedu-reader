import Foundation
import Testing
@testable import yuedu_app

/// A chapter's following page answers like any other page whatever its status, as Legado's
/// `BookContent.getContent` reads it: `newCallStrResponse` hands back the error body, which
/// the content rule reads as no text and the next-page rule as no further link.
@Suite("Content next pages read error pages", .serialized)
struct ContentNextPageStatusTests {
    /// 黄金书屋 (YCK1331) builds a page's next link from that page's own URL, so its last page
    /// links to `…/2.html/2.html`, which the site answers with a 404.
    @Test("a 404 next page ends the chapter and keeps the pages read before it")
    func notFoundNextPageEndsTheChapter() async throws {
        let host = "content-next-\(UUID().uuidString.prefix(8).lowercased()).yuedu.test"
        let first = "https://\(host)/novel/1/9"
        ContentPageStubURLProtocol.set(host: host, pages: [
            "/novel/1/9": (200, Self.page(text: "第一頁正文", next: "/novel/1/9/2.html")),
            "/novel/1/9/2.html": (200, Self.page(text: "第二頁正文", next: "/novel/1/9/2.html/2.html")),
        ])
        defer { ContentPageStubURLProtocol.remove(host: host) }
        var source = BookSource(bookSourceUrl: "https://\(host)", bookSourceName: "正文續頁狀態測試")
        source.ruleContent.content = "#c@text"
        source.ruleContent.nextContentUrl = "#next@href"
        #expect(!source.shouldUseLegadoRuntimeFetch(for: first))

        let fetcher = BookSourceFetcher(webFetcher: WebFetcher(session: ContentPageStubURLProtocol.session()))
        let content = try await fetcher.fetchChapter(
            ref: OnlineChapterRef(index: 0, title: "第1章", url: first), bookId: UUID(), source: source
        )

        #expect(content.contains("第一頁正文"))
        #expect(content.contains("第二頁正文"))
        #expect(ContentPageStubURLProtocol.requestCount(host: host, path: "/novel/1/9/2.html/2.html") == 1)
    }

    private static func page(text: String, next: String) -> String {
        "<html><body><div id=\"c\">\(text)</div><a id=\"next\" href=\"\(next)\">下一頁</a></body></html>"
    }
}

/// Replies by host and path; a path with no page is a 404 with an nginx-style body.
private final class ContentPageStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pages: [String: [String: (Int, String)]] = [:]
    nonisolated(unsafe) private static var requests: [String: Int] = [:]

    static func set(host: String, pages hostPages: [String: (Int, String)]) {
        lock.withLock { pages[host] = hostPages }
    }

    static func remove(host: String) {
        lock.withLock {
            pages[host] = nil
            requests = requests.filter { !$0.key.hasPrefix(host + "/") }
        }
    }

    static func requestCount(host: String, path: String) -> Int {
        lock.withLock { requests[host + path] ?? 0 }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContentPageStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".yuedu.test") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let reply = Self.lock.withLock { () -> (Int, String)? in
            Self.requests[host + url.path, default: 0] += 1
            return Self.pages[host]?[url.path]
        }
        let (status, body) = reply ?? (404, "<html><head><title>404 Not Found</title></head><body>nginx</body></html>")
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
