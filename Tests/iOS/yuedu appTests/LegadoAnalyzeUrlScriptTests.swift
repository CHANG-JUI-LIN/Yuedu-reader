import Foundation
import os
import Testing

@testable import yuedu_app

/// `java` inside an AnalyzeUrl's own scripts is that AnalyzeUrl, as Legado's `AnalyzeUrl.evalJS`
/// binds it (`LegadoAnalyzeUrlScriptView`): the `js` option and `loginCheckJs` read and change
/// the request through `java.url`, `java.ruleUrl`, `java.headerMap`, `java.initUrl()` and
/// `java.getStrResponse()`. Each test follows a source in the YCK 1329–1331 packs.
@Suite("AnalyzeUrl java in URL scripts and loginCheckJs", .serialized)
struct LegadoAnalyzeUrlScriptTests {
    /// 刚够小说网 (1330 #314): the `js` option fetches the 访问验证 page, puts its cookie in the
    /// headers and returns `java.url`. The option's value is the URL from then on.
    @Test("the js option changes the request through java, and what it returns is the URL")
    func jsOptionUsesAnalyzeUrlJava() async throws {
        AnalyzeUrlPageProtocol.reset(["/search": (200, "page /search")])
        let host = SourceScriptHost(bridgeFor: Self.source(), requestSession: AnalyzeUrlPageProtocol.session())
        let fetched = OSAllocatedUnfairLock<[String]>(initialState: [])
        await host.run { bridge in
            bridge.sourceScriptNetworkHandler = { request, _ in
                fetched.withLock { $0.append(request.url?.absoluteString ?? "") }
                return .bodyOnly(request: request, body: #"<script>var encryptedCookieValue = "c0ffee";</script>"#)
            }
        }
        let rule = #"https://au.test/search?q=abc,{"js":"let v = java.ajax(java.url).match(/encryptedCookieValue = \"([^\"]+)\"/)[1]; java.headerMap.put('Cookie', 'is_human=' + v); java.url + '&p=2'"}"#

        let (body, _) = try await host.fetch(ruleUrl: rule)

        #expect(body == "page /search")
        #expect(fetched.withLock { $0 } == ["https://au.test/search?q=abc"])
        let sent = try #require(AnalyzeUrlPageProtocol.requests().last)
        #expect(sent.url?.absoluteString == "https://au.test/search?q=abc&p=2")
        #expect(sent.value(forHTTPHeaderField: "Cookie") == "is_human=c0ffee")
    }

    /// 一笔阁 / 顶点小说 (1330 #129, #455): the check answers the 访问验证 page with
    /// `java.connect(source.key + java.ruleUrl)`. `java.ruleUrl` is the rule after its
    /// templates, still relative; before 11-07 it was `undefined`.
    @Test("loginCheckJs reads java.ruleUrl and hands back the response it fetched")
    func loginCheckReadsRuleUrl() async throws {
        AnalyzeUrlPageProtocol.reset(["/modules/search.php": (200, "<title>安全验证-反机器人</title>")])
        var source = Self.source()
        source.loginCheckJs = """
            if (result.body().match(/安全验证/)) {
                java.connect(source.key + java.ruleUrl)
            } else result
            """
        let host = SourceScriptHost(bridgeFor: source, requestSession: AnalyzeUrlPageProtocol.session())
        let fetched = OSAllocatedUnfairLock<[String]>(initialState: [])
        await host.run { bridge in
            bridge.sourceScriptNetworkHandler = { request, _ in
                fetched.withLock { $0.append(request.url?.absoluteString ?? "") }
                return .bodyOnly(request: request, body: "<p>results</p>")
            }
        }

        let (body, _) = try await host.fetch(
            ruleUrl: "/modules/search.php?searchkey={{key}}&type=name", key: "abc"
        )

        #expect(body == "<p>results</p>")
        #expect(fetched.withLock { $0 } == ["https://au.test/modules/search.php?searchkey=abc&type=name"])
    }

    /// 爱尚小说网 (1330 #382): on a 403 the check redoes the request —
    /// `java.initUrl(); result = java.getStrResponse()`. The resend is the request as it now
    /// stands: the rule read again, and what the check put in `java.headerMap`.
    @Test("java.initUrl() and java.getStrResponse() resend the request with the check's headers")
    func loginCheckResendsRequest() async throws {
        AnalyzeUrlPageProtocol.reset(["/list": (403, "forbidden")])
        var source = Self.source()
        source.loginCheckJs = """
            if (result.code() == 403) {
                java.headerMap.put('X-Pass', 'yes');
                java.initUrl();
                result = java.getStrResponse();
            }
            result
            """
        let host = SourceScriptHost(bridgeFor: source, requestSession: AnalyzeUrlPageProtocol.session())
        let resent = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)
        await host.run { bridge in
            bridge.sourceScriptNetworkHandler = { request, _ in
                resent.withLock { $0 = request }
                return .bodyOnly(request: request, body: "<p>second</p>")
            }
        }

        let (body, _) = try await host.fetch(ruleUrl: "https://au.test/list?n={{1 + 1}}")

        #expect(body == "<p>second</p>")
        let request = try #require(resent.withLock { $0 })
        #expect(request.url?.absoluteString == "https://au.test/list?n=2")
        #expect(request.value(forHTTPHeaderField: "X-Pass") == "yes")
    }

    /// The native path (`BookSourceFetcher.fetchStagePage`) builds no AnalyzeUrl. Its check gets
    /// a view of the stage's request, with the rule URL the stage rendered as `java.ruleUrl`.
    @Test("a native stage's check reads java.ruleUrl and java.url")
    func nativeStageCheckReadsRuleUrl() async throws {
        AnalyzeUrlPageProtocol.reset(["/s": (403, "<title>访问验证</title>")])
        var source = BookSource(
            bookSourceUrl: "https://au-\(UUID().uuidString.prefix(8).lowercased()).example",
            bookSourceName: "AnalyzeUrl native fixture"
        )
        source.loginCheckJs = """
            if (result.code() == 403) java.connect(source.key + java.ruleUrl + '&from=' + java.url.length);
            else result
            """
        let fetched = OSAllocatedUnfairLock<[String]>(initialState: [])
        await BookSourceSession.session(for: source).host.run { bridge in
            bridge.sourceScriptNetworkHandler = { request, _ in
                fetched.withLock { $0.append(request.url?.absoluteString ?? "") }
                return .bodyOnly(request: request, body: "<p>verified</p>")
            }
        }
        let absolute = source.bookSourceUrl + "/s?q=abc"
        let url = try #require(URL(string: absolute))
        let fetcher = BookSourceFetcher(webFetcher: WebFetcher(session: AnalyzeUrlPageProtocol.session()))

        let page = try await fetcher.fetchStagePage(
            url: url, method: "GET", body: nil, headers: [:], baseURL: source.bookSourceUrl,
            ruleURL: "/s?q=abc", source: source
        )

        #expect(page.html == "<p>verified</p>")
        #expect(fetched.withLock { $0 } == [source.bookSourceUrl + "/s?q=abc&from=\(absolute.count)"])
    }

    private static func source() -> BookSource {
        var source = BookSource()
        source.bookSourceUrl = "https://au.test"
        source.bookSourceName = "AnalyzeUrl java fixture"
        return source
    }
}

/// Answers each path with its configured status and body, and keeps the requests it saw.
private final class AnalyzeUrlPageProtocol: URLProtocol {
    private struct State {
        var pages: [String: (status: Int, body: String)] = [:]
        var requests: [URLRequest] = []
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func reset(_ pages: [String: (status: Int, body: String)]) {
        state.withLock { $0 = State(pages: pages) }
    }

    static func requests() -> [URLRequest] { state.withLock { $0.requests } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnalyzeUrlPageProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let page = Self.state.withLock { state -> (status: Int, body: String) in
            state.requests.append(request)
            return state.pages[request.url?.path ?? ""] ?? (404, "missing")
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: page.status, httpVersion: nil,
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(page.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
