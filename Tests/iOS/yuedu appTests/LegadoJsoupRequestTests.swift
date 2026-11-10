import Foundation
import os
import Testing
@testable import yuedu_app

/// Legado-E's and MD3's `java.get(url, headers)`, `java.head` and `java.post` are jsoup 1.16.2
/// requests (`JsExtensions`), not AnalyzeUrl ones: the script's headers over jsoup's defaults,
/// `CookieJar: 1` when the source keeps a cookie jar, and no cookie of the shared jar in or
/// out. `java.ajax` is an AnalyzeUrl request and keeps the source's header rule and its jar.
///
/// 八零电子书 (YCK1330 #744) posts its search form with `java.post(url, body, {})`.
@Suite("Legado jsoup requests", .serialized)
struct LegadoJsoupRequestTests {
    private static let sourceUA = "SourceRule/1.0"

    private static func host(cookieJar: Bool) -> SourceScriptHost<ModernParserBridge> {
        var source = BookSource(
            bookSourceUrl: "https://\(JsoupURLProtocol.host)/source#\(UUID().uuidString)",
            bookSourceName: "jsoup identity"
        )
        source.header = #"{"User-Agent":"\#(sourceUA)","X-Source":"yes"}"#
        source.enabledCookieJar = cookieJar
        return SourceScriptHost(bridgeFor: source, requestSession: JsoupURLProtocol.session())
    }

    @Test("java.post sends jsoup's identity: its UA and form type, no source header, no shared cookie", .timeLimit(.minutes(1)))
    func postIsJsoup() async throws {
        let id = JsoupURLProtocol.newID()
        defer { JsoupURLProtocol.clear(id) }
        CookieStore.shared.set(url: "https://\(JsoupURLProtocol.host)", cookie: "stored_\(id)=1")
        let url = "https://\(JsoupURLProtocol.host)/form/\(id)"

        let answer = await Self.host(cookieJar: true).run {
            $0.evaluateSourceScript("var r = java.post('\(url)', 'q=1', {}); r.code() + '|' + r.header('Location')")
        }

        #expect(answer == "302|/result/\(id)")
        let sent = try #require(JsoupURLProtocol.requests(for: id).first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "User-Agent") == LegadoJSBridge.jsoupDefaultUserAgent)
        #expect(sent.value(forHTTPHeaderField: "X-Source") == nil)
        #expect(sent.value(forHTTPHeaderField: "CookieJar") == "1")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded; charset=UTF-8")
        #expect(sent.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(sent.httpShouldHandleCookies == false)
        #expect(JsoupURLProtocol.requests(for: id).count == 1)
        #expect(!CookieStore.shared.get(url: "https://\(JsoupURLProtocol.host)").contains("set_\(id)"))
    }

    @Test("java.get and java.head send only the script's headers; no CookieJar marker without a jar", .timeLimit(.minutes(1)))
    func getAndHeadAreJsoup() async throws {
        let id = JsoupURLProtocol.newID()
        defer { JsoupURLProtocol.clear(id) }
        let url = "https://\(JsoupURLProtocol.host)/page/\(id)"

        let answer = await Self.host(cookieJar: false).run {
            $0.evaluateSourceScript("""
                java.get('\(url)', {'User-Agent': 'Mine/2', 'X-Script': 's'}).body() + '|' + java.head('\(url)', {}).code()
                """)
        }

        #expect(answer == "page \(id)|200")
        let sent = JsoupURLProtocol.requests(for: id)
        #expect(sent.map(\.httpMethod) == ["GET", "HEAD"])
        #expect(sent.first?.value(forHTTPHeaderField: "User-Agent") == "Mine/2")
        #expect(sent.first?.value(forHTTPHeaderField: "X-Script") == "s")
        #expect(sent.last?.value(forHTTPHeaderField: "User-Agent") == LegadoJSBridge.jsoupDefaultUserAgent)
        #expect(sent.allSatisfy { $0.value(forHTTPHeaderField: "X-Source") == nil })
        #expect(sent.allSatisfy { $0.value(forHTTPHeaderField: "CookieJar") == nil })
        #expect(sent.allSatisfy { !$0.httpShouldHandleCookies })
    }

    /// The control: an AnalyzeUrl request is Legado's OkHttp one, with the source's header rule
    /// and its jar.
    @Test("java.ajax still carries the source's header rule and its cookie jar", .timeLimit(.minutes(1)))
    func ajaxKeepsSourceIdentity() async throws {
        let id = JsoupURLProtocol.newID()
        defer { JsoupURLProtocol.clear(id) }
        let url = "https://\(JsoupURLProtocol.host)/page/\(id)"

        let body = await Self.host(cookieJar: true).run { $0.evaluateSourceScript("String(java.ajax('\(url)'))") }

        #expect(body == "page \(id)")
        let sent = try #require(JsoupURLProtocol.requests(for: id).first)
        #expect(sent.value(forHTTPHeaderField: "User-Agent") == Self.sourceUA)
        #expect(sent.value(forHTTPHeaderField: "X-Source") == "yes")
        // The shared jar's cookies go with it (`URLSession` attaches them).
        #expect(sent.httpShouldHandleCookies)
        #expect(sent.value(forHTTPHeaderField: "CookieJar") == nil)
    }
}

/// `/form/<id>` answers 302 to `/result/<id>` with a `Set-Cookie`; `/page/<id>` answers 200
/// `page <id>`. Every request is recorded under its id.
private final class JsoupURLProtocol: URLProtocol, @unchecked Sendable {
    static let host = "jsoup-source.test"
    private static let sent = OSAllocatedUnfairLock<[String: [URLRequest]]>(initialState: [:])

    static func newID() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    static func requests(for id: String) -> [URLRequest] { sent.withLock { $0[id] ?? [] } }

    static func clear(_ id: String) {
        sent.withLock { _ = $0.removeValue(forKey: id) }
        CookieStore.shared.remove(url: "https://\(host)", key: "stored_\(id)")
        CookieStore.shared.remove(url: "https://\(host)", key: "set_\(id)")
    }

    /// The production session's configuration (`LegadoJSBridge.requestSession`): the shared
    /// cookie storage, so a request that handles cookies would carry and keep them.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.protocolClasses = [JsoupURLProtocol.self]
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
        let (kind, id) = (parts[0], parts[1])
        let received = request
        Self.sent.withLock { $0[id, default: []].append(received) }
        let status: Int
        var headers = ["Content-Type": "text/plain; charset=utf-8"]
        let body: String
        switch kind {
        case "form":
            status = 302
            headers["Location"] = "/result/\(id)"
            headers["Set-Cookie"] = "set_\(id)=1; Path=/"
            body = ""
        default:
            status = 200
            body = "page \(id)"
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
