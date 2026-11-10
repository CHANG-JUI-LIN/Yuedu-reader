import Foundation
import os
import Testing

@testable import yuedu_app

/// A source that names no User-Agent sends Legado's `AppConfig.userAgent` (desktop Chrome 128)
/// on every route, as Legado's `BaseSource.getHeaderMap` and OkHttp interceptor do — its rules
/// were written against the pages a site serves that identity. A source's own User-Agent, in
/// any case, always wins.
@Suite("Legado default User-Agent", .serialized)
struct LegadoDefaultUserAgentTests {
    @Test("a source's header map carries the default User-Agent only when it names none")
    func headerMapCarriesDefault() async {
        let bare = Self.source(header: "")
        #expect(await bare.resolvedHeaders() == ["User-Agent": BookSource.legadoDefaultUserAgent])
        #expect(bare.parsedHeaders == ["User-Agent": BookSource.legadoDefaultUserAgent])

        let referer = Self.source(header: #"{"Referer":"https://ua.test/"}"#)
        #expect(await referer.resolvedHeaders()["User-Agent"] == BookSource.legadoDefaultUserAgent)

        let own = Self.source(header: #"{"user-agent":"Own/1.0"}"#)
        #expect(await own.resolvedHeaders() == ["user-agent": "Own/1.0"])

        let engine = JSCoreEngine()
        engine.bookSource = Self.source(header: "")
        #expect(engine.resolvedSourceHeaders() == ["User-Agent": BookSource.legadoDefaultUserAgent])
    }

    @Test("a native stage request sends the source map's User-Agent")
    func nativeStageSendsDefault() async throws {
        UARecordingProtocol.reset()
        let source = Self.source(header: "")
        let fetcher = BookSourceFetcher(webFetcher: WebFetcher(session: UARecordingProtocol.session()))
        let url = try #require(URL(string: source.bookSourceUrl + "/search?q=abc"))

        _ = try await fetcher.fetchStagePage(
            url: url, method: "GET", body: nil, headers: await source.resolvedHeaders(),
            baseURL: source.bookSourceUrl, source: source
        )

        #expect(UARecordingProtocol.userAgents() == [BookSource.legadoDefaultUserAgent])
    }

    @Test(
        "an AnalyzeUrl request sends the default, or the source's own User-Agent",
        arguments: [
            ("", BookSource.legadoDefaultUserAgent),
            (#"{"user-agent":"Own/1.0"}"#, "Own/1.0"),
        ]
    )
    func analyzeUrlRequestSendsSourceIdentity(header: String, expected: String) async throws {
        UARecordingProtocol.reset()
        let source = Self.source(header: header)
        let host = SourceScriptHost(bridgeFor: source, requestSession: UARecordingProtocol.session())

        let (body, _) = try await host.fetch(ruleUrl: source.bookSourceUrl + "/search?q=abc")

        #expect(body == "ok")
        #expect(UARecordingProtocol.userAgents() == [expected])
    }

    /// `java.post` is jsoup's request (Legado-E `JsExtensions.post`), with jsoup's UA, not
    /// Legado's own.
    @Test("java.post without a source sends jsoup's UA; getUserAgent and getWebViewUA differ")
    func scriptIdentity() {
        let engine = JSCoreEngine()
        let sent = OSAllocatedUnfairLock<[String]>(initialState: [])
        engine.networkHandler = { request, _ in
            sent.withLock { $0.append(request.value(forHTTPHeaderField: "User-Agent") ?? "-") }
            return .bodyOnly(request: request, body: "")
        }

        _ = engine.evaluate("java.post('https://ua.test/p', 'b', {}).body()")

        #expect(sent.withLock { $0 } == [LegadoJSBridge.jsoupDefaultUserAgent])
        #expect(engine.evaluate("java.getUserAgent()") == BookSource.legadoDefaultUserAgent)
        // Legado's `getWebViewUA` is the phone browser's own identity, `Mobile/… Safari/…` tail
        // included — what sources put in their header rule for a site's mobile pages.
        #expect(engine.evaluate("java.getWebViewUA()") == SourceWebIdentity.phoneUserAgent)

        engine.bookSource = Self.source(header: #"{"User-Agent":"Own/1.0"}"#)
        #expect(engine.evaluate("java.getUserAgent()") == "Own/1.0")
    }

    private static func source(header: String) -> BookSource {
        var source = BookSource(
            bookSourceUrl: "https://ua-\(UUID().uuidString.prefix(8).lowercased()).example",
            bookSourceName: "default User-Agent fixture"
        )
        source.header = header
        return source
    }
}

/// Answers every request with `ok` and keeps each request's User-Agent.
private final class UARecordingProtocol: URLProtocol {
    private static let sent = OSAllocatedUnfairLock<[String]>(initialState: [])

    static func reset() { sent.withLock { $0 = [] } }
    static func userAgents() -> [String] { sent.withLock { $0 } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UARecordingProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        Self.sent.withLock { $0.append(request.value(forHTTPHeaderField: "User-Agent") ?? "-") }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("ok".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
