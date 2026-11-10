import Foundation
import os
import Testing
@testable import yuedu_app

/// Legado's `retry` URL option, as `OkHttpUtils.newCallResponse` runs it (legado-E, MD3 and
/// upstream agree): `for (i in 0..retry)` the request goes out until an answer `isSuccessful`,
/// and the last answer is the result. Each attempt passes the network interceptor, which for a
/// source with a cookie jar loads the jar into it (`CookieManager.loadRequest`).
///
/// 顶点小说 (YCK1330 #2) fetches its home page with `java.ajax(base + "/,{\"retry\":2}")`: the
/// first answer is a 403 that sets a cookie, the second — with it — is the page. The option was
/// parsed and never used, so the search read the form off the 403 and searched a 404.
@Suite("Legado retry URL option", .serialized)
struct LegadoRequestRetryTests {
    private static func source(cookieJar: Bool = true) -> BookSource {
        var source = BookSource(
            bookSourceUrl: "https://\(RetryURLProtocol.host)/source#\(UUID().uuidString)",
            bookSourceName: "Retry option"
        )
        source.enabledCookieJar = cookieJar
        return source
    }

    private static func host(cookieJar: Bool = true) -> SourceScriptHost<ModernParserBridge> {
        SourceScriptHost(bridgeFor: source(cookieJar: cookieJar), requestSession: RetryURLProtocol.session())
    }

    /// A script's request: the challenge's cookie goes out with the second attempt.
    @Test("java.ajax with retry sends again after a 403 and carries the cookie it set", .timeLimit(.minutes(1)))
    func ajaxRetriesThroughCookieChallenge() async throws {
        let id = RetryURLProtocol.newID()
        defer { RetryURLProtocol.clear(id) }
        let url = "https://\(RetryURLProtocol.host)/challenge/\(id),{\"retry\":2}"

        let body = await Self.host().run { $0.evaluateSourceScript("String(java.ajax('\(url)'))") }

        #expect(body == "home \(id)")
        let cookies = RetryURLProtocol.cookies(sentFor: id)
        #expect(cookies.count == 2)
        #expect(cookies.first.map { $0.contains("pass_\(id)=1") } == false)
        #expect(cookies.last.map { $0.contains("pass_\(id)=1") } == true)
    }

    /// A stage's request (a rule URL with options, `ModernParserBridge.fetch`).
    @Test("a runtime rule-URL fetch with retry sends again after a 403", .timeLimit(.minutes(1)))
    func runtimeFetchRetriesThroughCookieChallenge() async throws {
        let id = RetryURLProtocol.newID()
        defer { RetryURLProtocol.clear(id) }

        let (body, _) = try await Self.host().fetch(
            ruleUrl: "https://\(RetryURLProtocol.host)/challenge/\(id),{\"retry\":2}"
        )

        #expect(body == "home \(id)")
        #expect(RetryURLProtocol.cookies(sentFor: id).count == 2)
    }

    /// Legado returns the last answer once `retry` runs out: `ajax` hands back its body.
    @Test("retry stops after its count and keeps the last error answer", .timeLimit(.minutes(1)))
    func retryKeepsLastAnswer() async throws {
        let id = RetryURLProtocol.newID()
        defer { RetryURLProtocol.clear(id) }
        let url = "https://\(RetryURLProtocol.host)/busy/\(id),{\"retry\":2}"

        let body = await Self.host().run { $0.evaluateSourceScript("String(java.ajax('\(url)'))") }

        #expect(RetryURLProtocol.cookies(sentFor: id).count == 3)
        #expect(body == "busy 3")
    }

    /// No option, no second attempt: the 403 is the answer.
    @Test("a request without retry is sent once", .timeLimit(.minutes(1)))
    func noRetryOptionSendsOnce() async throws {
        let id = RetryURLProtocol.newID()
        defer { RetryURLProtocol.clear(id) }
        let url = "https://\(RetryURLProtocol.host)/challenge/\(id),{\"method\":\"GET\"}"

        let body = await Self.host().run { $0.evaluateSourceScript("String(java.ajax('\(url)'))") }

        #expect(body == "challenge")
        #expect(RetryURLProtocol.cookies(sentFor: id).count == 1)
    }

    /// Without a cookie jar Legado sends every attempt as it was built: no cookie the challenge
    /// set reaches it, and every attempt is answered the challenge.
    @Test("without a cookie jar every attempt goes out as built", .timeLimit(.minutes(1)))
    func noCookieJarSendsAttemptsAsBuilt() async throws {
        let id = RetryURLProtocol.newID()
        defer { RetryURLProtocol.clear(id) }
        let url = "https://\(RetryURLProtocol.host)/challenge/\(id),{\"retry\":2}"

        let body = await Self.host(cookieJar: false).run {
            $0.evaluateSourceScript("String(java.ajax('\(url)'))")
        }

        #expect(body == "challenge")
        let cookies = RetryURLProtocol.cookies(sentFor: id)
        #expect(cookies.count == 3)
        #expect(cookies.allSatisfy { !$0.contains("pass_\(id)=1") })
    }

    /// A request with no answer throws out of Legado's loop (`await()`): it is not retried.
    @Test("a request that gets no answer is not retried", .timeLimit(.minutes(1)))
    func transportErrorIsNotRetried() async throws {
        let id = RetryURLProtocol.newID()
        defer { RetryURLProtocol.clear(id) }

        await #expect(throws: (any Error).self) {
            _ = try await Self.host().fetch(
                ruleUrl: "https://\(RetryURLProtocol.host)/refused/\(id),{\"retry\":2}"
            )
        }
        #expect(RetryURLProtocol.cookies(sentFor: id).count == 1)
    }

    /// A next content page is read from its link as the rule gave it, options included: Legado
    /// builds its AnalyzeUrl from that link (`BookContent.getContent`). Made into a URL first,
    /// 顶点小说's `1823698_2.html,{"retry":2}` went out as `1823698_2.html,%7B%22retry%22:2%7D`.
    @Test("a next content page is fetched from its link, options included")
    func nextContentPageKeepsItsOptions() async throws {
        let first = try #require(URL(string: "https://pages.retry.test/c/1.html"))
        let link = "https://pages.retry.test/c/1_2.html,{\"retry\":2}"
        let fetched = OSAllocatedUnfairLock<[String]>(initialState: [])

        let result = try await ChapterFetcher.shared.fetchPaginatedContent(
            initialHTML: "p1", initialURL: first, initialBaseURL: first.absoluteString,
            parsePage: { html, _, _ in
                ChapterParsePayload(content: html, title: "", sourceMatched: true, isPay: false)
            },
            extractNextURLs: { html, _, _ in html == "p1" ? [link] : [] },
            fetchNextPageHTML: { link in
                fetched.withLock { $0.append(link) }
                return "p2"
            }
        )

        #expect(fetched.withLock { $0 } == [link])
        #expect(result.payload.content == "p1\np2")
    }
}

/// `/challenge/<id>` answers 403 and puts `pass_<id>=1` into the cookie jar (what a real
/// `Set-Cookie` does through `HTTPCookieStorage`) until a request carries it, then 200 with
/// `home <id>`. `/busy/<id>` answers 503 `busy <n>` to its n-th request. `/refused/<id>` fails
/// without an answer. Every request's `Cookie` header is recorded under its id.
private final class RetryURLProtocol: URLProtocol, @unchecked Sendable {
    static let host = "retry-source.test"
    private static let sent = OSAllocatedUnfairLock<[String: [String]]>(initialState: [:])

    static func newID() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    static func cookies(sentFor id: String) -> [String] { sent.withLock { $0[id] ?? [] } }

    static func clear(_ id: String) {
        sent.withLock { _ = $0.removeValue(forKey: id) }
        CookieStore.shared.remove(url: "https://\(host)", key: "pass_\(id)")
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RetryURLProtocol.self]
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
        let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
        let count = Self.sent.withLock { sent -> Int in
            sent[id, default: []].append(cookie)
            return sent[id]?.count ?? 0
        }
        let status: Int
        let body: String
        switch kind {
        case "challenge" where cookie.contains("pass_\(id)=1"):
            (status, body) = (200, "home \(id)")
        case "challenge":
            CookieStore.shared.set(url: "https://\(Self.host)", cookie: "pass_\(id)=1")
            (status, body) = (403, "challenge")
        case "busy":
            (status, body) = (503, "busy \(count)")
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/plain; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
