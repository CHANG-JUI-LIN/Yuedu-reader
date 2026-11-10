import Foundation
import Testing
@testable import yuedu_app

/// What a source's request carries on its way out: the headers of the Legado client it stands
/// for, and nothing the source did not ask for (`LegadoOutgoingHeaders`). okhttp adds the
/// default User-Agent when absent, `Accept-Encoding: gzip, deflate` when absent and
/// `Cache-Control: no-cache` (legado-E HttpHelper.kt:71–81, DecompressInterceptor); neither it
/// nor jsoup adds a Referer or an Accept-Language. CFNetwork sends the device's Accept-Language
/// when a request has none, so "none" goes out as an empty one (maintainer, 11-09).
@Suite("Legado outgoing headers")
struct LegadoOutgoingHeadersTests {
    private static let url = URL(string: "https://outgoing-headers.test/page")!

    @Test func okHttpAddsItsHeadersWhenTheRequestHasNone() {
        let sent = LegadoOutgoingHeaders.prepared(URLRequest(url: Self.url), as: .okHttp)
        #expect(sent.value(forHTTPHeaderField: "User-Agent") == BookSource.legadoDefaultUserAgent)
        #expect(sent.value(forHTTPHeaderField: "Accept-Encoding") == "gzip, deflate")
        #expect(sent.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
        #expect(sent.value(forHTTPHeaderField: "Accept-Language") == "")
        #expect(sent.value(forHTTPHeaderField: "Referer") == nil)
    }

    @Test func theRequestsOwnHeadersWin() {
        var request = URLRequest(url: Self.url)
        request.setValue("SourceUA/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN", forHTTPHeaderField: "Accept-Language")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("max-age=0", forHTTPHeaderField: "Cache-Control")
        let sent = LegadoOutgoingHeaders.prepared(request, as: .okHttp)
        #expect(sent.value(forHTTPHeaderField: "User-Agent") == "SourceUA/1.0")
        #expect(sent.value(forHTTPHeaderField: "Accept-Language") == "zh-CN")
        #expect(sent.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
        #expect(sent.value(forHTTPHeaderField: "Cache-Control") == "max-age=0")
    }

    /// `java.get`/`head`/`post` are jsoup requests: the script's headers only. The mark rides on
    /// the request beside `LegadoRedirectPolicy`'s, and a request without it is okhttp's.
    @Test func jsoupAddsOnlyTheEmptyAcceptLanguage() {
        var request = URLRequest(url: Self.url)
        request.setValue("jsoup UA", forHTTPHeaderField: "User-Agent")
        let marked = LegadoOutgoingHeaders.markingJsoup(LegadoRedirectPolicy.refusingRedirects(request))
        #expect(LegadoOutgoingHeaders.client(of: marked) == .jsoup)
        #expect(LegadoRedirectPolicy.refusesRedirects(marked))
        #expect(LegadoOutgoingHeaders.client(of: URLRequest(url: Self.url)) == .okHttp)

        let sent = LegadoOutgoingHeaders.prepared(marked, as: LegadoOutgoingHeaders.client(of: marked))
        #expect(sent.value(forHTTPHeaderField: "User-Agent") == "jsoup UA")
        #expect(sent.value(forHTTPHeaderField: "Cache-Control") == nil)
        #expect(sent.value(forHTTPHeaderField: "Accept-Encoding") == nil)
        #expect(sent.value(forHTTPHeaderField: "Accept-Language") == "")
    }

    /// A source's rule page sent `Referer: <source URL>`, `Accept-Language: zh-TW,…` and
    /// `Accept-Encoding: gzip, deflate, br` until 11-09.
    @Test func aSourcePageCarriesNoRefererAndNoLanguage() async throws {
        let fetcher = WebFetcher(session: OutgoingHeadersStub.session())
        let page = try await fetcher.fetchPage(
            url: Self.url, method: "GET", body: nil,
            headers: ["User-Agent": "SourceUA/1.0"], baseURL: "https://outgoing-headers.test",
            client: .okHttp
        )
        let sent = page.request
        #expect(page.statusCode == 200)
        #expect(sent.value(forHTTPHeaderField: "Referer") == nil)
        #expect(sent.value(forHTTPHeaderField: "Accept-Language") == "")
        #expect(sent.value(forHTTPHeaderField: "Accept-Encoding") == "gzip, deflate")
        #expect(sent.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
        #expect(sent.value(forHTTPHeaderField: "User-Agent") == "SourceUA/1.0")
    }

    /// The app's own pages (a web page added as a book, a rule module) are not a source's and
    /// keep the browser-like request.
    @Test func theAppsOwnPageKeepsItsBrowserHeaders() async throws {
        let fetcher = WebFetcher(session: OutgoingHeadersStub.session())
        let page = try await fetcher.fetchPage(
            url: Self.url, method: "GET", body: nil, headers: [:], baseURL: "https://outgoing-headers.test"
        )
        #expect(page.request.value(forHTTPHeaderField: "Referer") == "https://outgoing-headers.test")
        #expect(page.request.value(forHTTPHeaderField: "Accept-Language")?.hasPrefix("zh-TW") == true)
        #expect(page.request.value(forHTTPHeaderField: "User-Agent")?.contains("iPhone") == true)
    }
}

/// Answers every request to `outgoing-headers.test` with an empty 200 page.
private final class OutgoingHeadersStub: URLProtocol {
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OutgoingHeadersStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "outgoing-headers.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("<html></html>".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
