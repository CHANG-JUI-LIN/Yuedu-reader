import Foundation
import Testing
@testable import yuedu_app

@Suite("WebFetcher persisted cookies", .serialized)
struct WebFetcherPersistedCookieTests {

    @Test("native request restores a cookie from CookieStore persistence")
    func nativeRequestRestoresPersistedCookie() async throws {
        PersistedCookieURLProtocol.reset()
        let host = "persisted-cookie-\(UUID().uuidString).example.com"
        let url = try #require(URL(string: "https://\(host)/chapter"))
        CookieStore.shared.set(url: url.absoluteString, cookie: "admin_session=session-token")
        defer { CookieStore.shared.remove(url: url.absoluteString) }

        // Model a cold native HTTP stack: the cookie remains in CookieStore's
        // on-disk snapshot but is absent from HTTPCookieStorage.
        for cookie in HTTPCookieStorage.shared.cookies(for: url) ?? [] {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PersistedCookieURLProtocol.self]
        let fetcher = WebFetcher(session: URLSession(configuration: configuration))

        _ = try await fetcher.fetchHTML(
            url: url,
            method: "GET",
            body: nil,
            headers: [:],
            baseURL: "https://\(host)"
        )

        #expect(PersistedCookieURLProtocol.cookieHeader?.contains("admin_session=session-token") == true)
    }
}

private final class PersistedCookieURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedCookieHeader: String?

    static var cookieHeader: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedCookieHeader
    }

    static func reset() {
        lock.lock()
        storedCookieHeader = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.storedCookieHeader = request.value(forHTTPHeaderField: "Cookie")
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("<html></html>".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
