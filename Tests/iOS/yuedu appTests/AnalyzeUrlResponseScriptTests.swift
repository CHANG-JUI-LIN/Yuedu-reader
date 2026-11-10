import Foundation
import os
import Testing
@testable import yuedu_app

/// An AnalyzeUrl's response scripts run as Legado runs them (`analyzeUrl.evalJS`): `bodyJs`
/// inside `AnalyzeUrl.getStrResponseAwait` (AnalyzeUrl.kt:507), then the source's
/// `loginCheckJs` on that answer (WebBook.kt:73). In both, `java` is the AnalyzeUrl — its
/// `put`/`get` the page's `RuleData`, where the URL's own scripts put — and `baseUrl` is the
/// request URL's scheme and host (`NetworkUtils.getBaseUrl`, AnalyzeUrl.kt:228).
///
/// 破天小说 (YCK1330 #704) puts its search key in the search URL and reads it back in its
/// check with `java.get("key")`; it read the source's variables instead and searched for "".
@Suite("AnalyzeUrl response scripts", .serialized)
struct AnalyzeUrlResponseScriptTests {
    @Test("bodyJs, then loginCheckJs, both reading the page's puts and the URL's host as baseUrl", .timeLimit(.minutes(1)))
    func responseScriptsShareThePageScope() async throws {
        let id = ResponseScopeURLProtocol.newID()
        defer { ResponseScopeURLProtocol.clear(id) }
        let origin = "https://\(ResponseScopeURLProtocol.host)"
        var source = BookSource(
            bookSourceUrl: "https://source-home.test/books/",
            bookSourceName: "response scope"
        )
        source.searchUrl = #"\#(origin)/s/\#(id)?q={{java.put('kw', key)}},{"bodyJs":"result + '|bodyJs:' + java.get('kw') + '|' + java.url + '|' + baseUrl"}"#
        source.loginCheckJs = """
            java.ajax('\(origin)/echo/\(id)?kw=' + java.get('kw') + '&base=' + encodeURIComponent(baseUrl)
                + '&body=' + encodeURIComponent(result.body()));
            result
            """
        source.ruleSearch.bookList = ".b"
        source.ruleSearch.name = "a@text"
        source.ruleSearch.bookUrl = "a@href"
        let host = SourceScriptHost(bridgeFor: source, requestSession: ResponseScopeURLProtocol.session())

        let books = try await host.searchBooks(keyword: "dune")

        #expect(books.map(\.name) == ["Book One"])
        let sent = ResponseScopeURLProtocol.requests(for: id)
        #expect(sent.map(\.url?.path) == ["/s/\(id)", "/echo/\(id)"])
        let echo = try #require(sent.last?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        func query(_ name: String) -> String? { echo.queryItems?.first { $0.name == name }?.value }
        // The check reads what the URL put.
        #expect(query("kw") == "dune")
        // The scheme and host of the request URL — not the response URL, not the source's.
        #expect(query("base") == origin)
        // The check saw the body `bodyJs` made, and `bodyJs` read the page's put, the
        // AnalyzeUrl's `url` and the host base.
        #expect(query("body")?.hasSuffix("|bodyJs:dune|\(origin)/s/\(id)?q=dune|\(origin)") == true)
    }

    @Test("an AnalyzeUrl's baseUrl is its URL's scheme and host, as NetworkUtils.getBaseUrl reads it")
    func baseUrlIsTheURLsOrigin() {
        #expect(AnalyzeUrl.legadoBaseUrl(of: "https://a.test/x/y?z=1") == "https://a.test")
        #expect(AnalyzeUrl.legadoBaseUrl(of: "https://a.test") == "https://a.test")
        #expect(AnalyzeUrl.legadoBaseUrl(of: "HTTP://A.test:8080/p") == "HTTP://A.test:8080")
        #expect(AnalyzeUrl.legadoBaseUrl(of: "data:;base64,eyJ9") == nil)

        // A stage's first request on the native path has no AnalyzeUrl; its check's `java`
        // reads the same base.
        let request = URLRequest(url: URL(string: "https://a.test/book/1?p=2")!)
        let (view, _) = LegadoAnalyzeUrlScriptView.snapshot(
            of: request, ruleUrl: "/book/1?p=2", baseUrl: "https://source-home.test/books/"
        )
        #expect(view.baseUrl == "https://a.test")
    }

    /// A stage page that answers an error status is the source's API failure, with or without
    /// a check — as every runtime response is. 领域书库's 正文 (YCK1330 #462) answered 429 and
    /// the 書源檢查 reported only 「正文失效」.
    @Test("a native stage page's error status is the source's API failure", arguments: [false, true])
    func stageStatusIsRecorded(checked: Bool) async throws {
        let id = ResponseScopeURLProtocol.newID()
        defer { ResponseScopeURLProtocol.clear(id) }
        var source = BookSource(
            bookSourceUrl: "https://stage-\(id).test", bookSourceName: "stage status"
        )
        if checked { source.loginCheckJs = "result" }
        let fetcher = BookSourceFetcher(webFetcher: WebFetcher(session: ResponseScopeURLProtocol.session()))
        let url = try #require(URL(string: "https://\(ResponseScopeURLProtocol.host)/limited/\(id)"))

        let page = try await fetcher.fetchStagePage(
            url: url, method: "GET", body: nil, headers: [:], baseURL: source.bookSourceUrl, source: source
        )

        #expect(page.statusCode == 429)
        #expect(SourceAPIErrorLog.shared.last(for: source.bookSourceUrl)?.statusCode == 429)
        SourceAPIErrorLog.shared.clear(for: source.bookSourceUrl)
    }
}

/// `/s/<id>` answers one search row; `/echo/<id>` answers `ok`; `/limited/<id>` answers 429.
/// Every request is recorded under its id.
private final class ResponseScopeURLProtocol: URLProtocol, @unchecked Sendable {
    static let host = "response-scope.test"
    private static let sent = OSAllocatedUnfairLock<[String: [URLRequest]]>(initialState: [:])

    static func newID() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
    static func requests(for id: String) -> [URLRequest] { sent.withLock { $0[id] ?? [] } }
    static func clear(_ id: String) { sent.withLock { _ = $0.removeValue(forKey: id) } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponseScopeURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 2 else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let received = request
        Self.sent.withLock { $0[parts[1], default: []].append(received) }
        let body = parts[0] == "s" ? #"<div class="b"><a href="/book/1">Book One</a></div>"# : "ok"
        let response = HTTPURLResponse(
            url: url, statusCode: parts[0] == "limited" ? 429 : 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
