import Foundation
import os
import Testing
@testable import yuedu_app

/// Legado runs `loginCheckJs` on the first response of every stage — search, 詳情, 目錄, 正文 —
/// whatever its status; the original, Legado-E and MD3 all do. That is where a source notices
/// its Cloudflare page or login wall and swaps in the response it fetched after the check. The
/// native path used to throw a 403 before the script could see it.
@Suite("Stage responses reach loginCheckJs", .serialized)
struct StageLoginCheckTests {
    @Test("a 403 reaches loginCheckJs, which can hand back the response it fetched instead")
    func forbiddenResponseCanBeReplaced() async throws {
        StageURLProtocol.respond(status: 403, body: "<title>Just a moment...</title>")
        let source = makeSource(loginCheckJs: """
            if (result.code() == 403) {
                java.connect(String(result.url).replace('/search', '/verified'));
            } else {
                result;
            }
            """)
        let refetched = OSAllocatedUnfairLock<URL?>(initialState: nil)
        await BookSourceSession.session(for: source).host.run { bridge in
            bridge.sourceScriptNetworkHandler = { request, _ in
                refetched.withLock { $0 = request.url }
                return .bodyOnly(request: request, body: "<p>results</p>")
            }
        }
        let url = try #require(URL(string: source.bookSourceUrl + "/search?q=1"))

        let html = try await makeFetcher().fetchStageHTML(
            url: url, method: "GET", body: nil, headers: [:],
            baseURL: source.bookSourceUrl, source: source)

        #expect(html == "<p>results</p>")
        #expect(refetched.withLock { $0 }?.path == "/verified")
    }

    /// Legado's `WebBook` reads no status: the stage's rules get the page the check leaves.
    @Test("a 403 the check leaves alone goes to the stage's rules, as in Legado")
    func untouchedForbiddenResponseReachesRules() async throws {
        StageURLProtocol.respond(status: 403, body: "forbidden")
        let source = makeSource(loginCheckJs: "result")
        let url = try #require(URL(string: source.bookSourceUrl + "/book/1"))

        let page = try await makeFetcher().fetchStagePage(
            url: url, method: "GET", body: nil, headers: [:],
            baseURL: source.bookSourceUrl, source: source)

        #expect(page.html == "forbidden")
        #expect(page.statusCode == 403)
    }

    @Test("the check sees the real status: a 200 passes through untouched")
    func successfulResponsePassesThrough() async throws {
        StageURLProtocol.respond(status: 200, body: "<p>chapter</p>")
        let source = makeSource(loginCheckJs: """
            if (result.code() != 200) { java.connect('https://unexpected.example/'); } else { result; }
            """)
        let refetched = OSAllocatedUnfairLock(initialState: false)
        await BookSourceSession.session(for: source).host.run { bridge in
            bridge.sourceScriptNetworkHandler = { request, _ in
                refetched.withLock { $0 = true }
                return .bodyOnly(request: request, body: "unexpected")
            }
        }
        let url = try #require(URL(string: source.bookSourceUrl + "/chapter/1"))

        let html = try await makeFetcher().fetchStageHTML(
            url: url, method: "GET", body: nil, headers: [:],
            baseURL: source.bookSourceUrl, source: source)

        #expect(html == "<p>chapter</p>")
        #expect(!refetched.withLock { $0 })
    }

    /// 番茄短剧 (YCK 1330) answers its detail URL with a 404 whose body its `init` script never
    /// reads; Legado opens the book.
    @Test("without loginCheckJs a 404 goes to the stage's rules too")
    func sourceWithoutCheckReadsErrorPage() async throws {
        StageURLProtocol.respond(status: 404, body: "not found")
        let source = makeSource(loginCheckJs: "")
        let url = try #require(URL(string: source.bookSourceUrl + "/detail?series_id=1"))

        let page = try await makeFetcher().fetchStagePage(
            url: url, method: "GET", body: nil, headers: [:],
            baseURL: source.bookSourceUrl, source: source)

        #expect(page.html == "not found")
        #expect(page.statusCode == 404)
    }

    /// A search reads an error page with its rules as well; finding nothing there is the
    /// status's failure, not a source without the book.
    @Test("a search finds books on an error page, and fails with its status when it finds none")
    func searchOnErrorPage() async throws {
        let source = makeSearchSource()
        let fetcher = makeFetcher()

        StageURLProtocol.respond(status: 404, body: #"<ul><li><a href="/b/1">書甲</a></li></ul>"#)
        let found = try await fetcher.searchOutcome(query: "甲\(UUID().uuidString)", in: source)
        #expect(found.books.map(\.name) == ["書甲"])

        StageURLProtocol.respond(status: 404, body: "<p>not found</p>")
        let none = try await fetcher.searchOutcome(query: "乙\(UUID().uuidString)", in: source)
        #expect(none.failure == .http(404))
    }

    private func makeSource(loginCheckJs: String) -> BookSource {
        var source = BookSource(
            bookSourceUrl: "https://stage-\(UUID().uuidString.prefix(8).lowercased()).example",
            bookSourceName: "stage login check fixture"
        )
        source.loginCheckJs = loginCheckJs
        return source
    }

    private func makeSearchSource() -> BookSource {
        var source = makeSource(loginCheckJs: "")
        source.searchUrl = "/search?q={{key}}"
        source.ruleSearch.bookList = "li"
        source.ruleSearch.name = "a@text"
        source.ruleSearch.bookUrl = "a@href"
        return source
    }

    private func makeFetcher() -> BookSourceFetcher {
        BookSourceFetcher(webFetcher: WebFetcher(session: StageURLProtocol.session()))
    }
}

private final class StageURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var body = ""

    static func respond(status: Int, body: String) {
        lock.lock()
        self.status = status
        self.body = body
        lock.unlock()
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StageURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let status = Self.status
        let body = Self.body
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
