import Foundation
import ReadiumShared
import Testing
import UIKit
@testable import yuedu_app

@Suite("Remote library HTTP", .serialized)
struct RemoteLibraryHTTPTests {
    private let base = URL(string: "https://library.example/proxy/opds")!

    @Test("Basic and Digest challenges use configured credentials only on their origin")
    func authenticationScope() throws {
        let delegate = RemoteLibraryAuthenticationDelegate(baseURL: base, username: "reader", password: "secret")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: base)
        for method in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest] {
            let space = URLProtectionSpace(host: "library.example", port: 443, protocol: "https", realm: "Library", authenticationMethod: method)
            let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil, sender: LibraryChallengeSender())
            var received: URLCredential?
            var disposition: URLSession.AuthChallengeDisposition?
            delegate.urlSession(session, task: task, didReceive: challenge) { disposition = $0; received = $1 }
            #expect(disposition == .useCredential)
            #expect(received?.user == "reader")
            #expect(received?.password == "secret")
        }
        for (host, port, scheme, failures) in [("other.example", 443, "https", 0), ("library.example", 80, "http", 0), ("library.example", 8443, "https", 0), ("library.example", 443, "https", 1)] {
            let space = URLProtectionSpace(host: host, port: port, protocol: scheme, realm: nil, authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
            let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: failures, failureResponse: nil, error: nil, sender: LibraryChallengeSender())
            var received: URLCredential?
            delegate.urlSession(session, task: task, didReceive: challenge) { _, credential in received = credential }
            #expect(received == nil)
        }
    }

    @Test("Cross-origin redirects strip credentials and cookies")
    func redirectScope() throws {
        let delegate = RemoteLibraryAuthenticationDelegate(baseURL: base, username: "reader", password: "secret")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://other.example/book.epub")!)
        request.setValue("Basic secret", forHTTPHeaderField: "Authorization")
        request.setValue("login=private", forHTTPHeaderField: "Cookie")
        let response = HTTPURLResponse(url: base, statusCode: 302, httpVersion: nil, headerFields: nil)!
        var redirected: URLRequest?
        delegate.urlSession(session, task: session.dataTask(with: base), willPerformHTTPRedirection: response, newRequest: request) { redirected = $0 }
        #expect(redirected?.url == request.url)
        #expect(redirected?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(redirected?.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(RemoteLibraryHTTPClient.sameOrigin(base, URL(string: "https://LIBRARY.example:443/book")))
    }

    @Test("mutations reject redirects without replaying bytes or changing POST into GET")
    func mutationRedirectScope() throws {
        let delegate = RemoteLibraryAuthenticationDelegate(baseURL: base, username: "reader", password: "secret")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for method in ["POST", "PUT", "MKCOL", "MOVE"] {
            var original = URLRequest(url: base)
            original.httpMethod = method
            let task = session.dataTask(with: original)
            for status in [301, 302, 303, 307, 308] {
                for target in [base, URL(string: "https://other.example/upload")!] {
                    var redirected = URLRequest(url: target)
                    redirected.httpMethod = status == 307 || status == 308 ? method : "GET"
                    let response = HTTPURLResponse(url: base, statusCode: status, httpVersion: nil, headerFields: nil)!
                    var allowed = true
                    delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirected) { allowed = $0 != nil }
                    #expect(!allowed)
                }
            }
        }
    }

    @Test("mutating requests cannot send bodies directly to a different origin")
    func mutationDirectOrigin() async throws {
        let http = fixtureClient()
        LibraryHTTPProtocol.handler = { _ in
            Issue.record("A cross-origin mutation must never start a request")
            return (201, [:], Data())
        }
        var request = URLRequest(url: URL(string: "https://other.example/upload")!)
        request.httpMethod = "POST"
        request.httpBody = Data("private book".utf8)
        await #expect(throws: RemoteLibraryWriteError.invalidDestination) { try await http.data(for: request) }
    }

    @Test("Readium receives only the requested range and preserves its response")
    func rangeStreaming() async throws {
        let http = fixtureClient()
        LibraryHTTPProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "Range") == "bytes=2-5")
            return (206, ["Content-Range": "bytes 2-5/1000000", "Content-Length": "4"], Data("book".utf8))
        }
        var request = HTTPRequest(url: HTTPURL(url: base)!)
        request.setRange(2..<6)
        let response = try await http.fetch(request).get()
        #expect(response.body == Data("book".utf8))
        #expect(response.status == .partialContent)
    }

    @Test("Range refusal is distinct from authentication errors")
    func rangeFailureClassification() async throws {
        let http = fixtureClient()
        var request = HTTPRequest(url: HTTPURL(url: base)!)
        request.setRange(0..<1)
        LibraryHTTPProtocol.handler = { _ in (200, ["Content-Length": "4"], Data("full".utf8)) }
        switch await http.fetch(request) {
        case .failure(.rangeNotSupported): break
        default: Issue.record("A full response to Range must be rejected")
        }
        LibraryHTTPProtocol.handler = { _ in (401, [:], Data("Login".utf8)) }
        switch await http.fetch(request) {
        case .failure(.errorResponse(let response)): #expect(response.status == .unauthorized)
        default: Issue.record("Authentication must not become a Range fallback")
        }
    }

    @Test("a 200 login page is not a range-refusal full-download trigger")
    func loginPageDoesNotTriggerDownload() async throws {
        let http = fixtureClient()
        var request = HTTPRequest(url: HTTPURL(url: base)!)
        request.setRange(0..<1)
        LibraryHTTPProtocol.handler = { _ in (200, ["Content-Type": "text/html"], Data("<html>Login</html>".utf8)) }
        switch await http.fetch(request) {
        case .failure(.other(let error)):
            guard case OPDSError.loginPage = error else { Issue.record("Expected login page error"); return }
        default: Issue.record("Login HTML must not trigger complete caching")
        }
        LibraryHTTPProtocol.handler = { _ in (200, ["Content-Type": "application/epub+zip"], Data("book".utf8)) }
        switch await http.fetch(request) {
        case .failure(.rangeNotSupported): break
        default: Issue.record("A server's full EPUB response is the supported compatibility trigger")
        }
    }

    @Test("malformed 206 must not publish or cache a different byte slice")
    func malformedPartialResponse() async throws {
        let http = fixtureClient()
        var request = HTTPRequest(url: HTTPURL(url: base)!)
        request.setRange(2..<6)
        for range in ["bytes 3-6/100", "bytes 2-5/4", "invalid"] {
            LibraryHTTPProtocol.handler = { _ in (206, ["Content-Range": range], Data("oops".utf8)) }
            switch await http.fetch(request) {
            case .failure(.malformedResponse): break
            default: Issue.record("Invalid partial bytes must fail without a full-file fallback")
            }
        }
    }

    @Test("OpenSearch description shares the configured transport and preserves query structure")
    func searchDescription() async throws {
        let http = fixtureClient()
        LibraryHTTPProtocol.handler = { request in
            #expect(request.url?.path == "/proxy/search.xml")
            return (200, ["Content-Type": "application/xml"], Data("""
                <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/"><Url type="application/atom+xml" template="opds/search?q={searchTerms}&amp;library=Main"/></OpenSearchDescription>
                """.utf8))
        }
        let client = OPDSClient(httpClient: http)
        let url = try await client.searchFeedURL(search: .description(URL(string: "https://library.example/proxy/search.xml")!), query: "中文 &")
        #expect(url?.path == "/proxy/opds/search")
        #expect(URLComponents(url: try #require(url), resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "中文 &")
    }

    @Test("Authenticated cover sessions reuse decoding and isolate memory cache")
    func coverSessionCache() async throws {
        BookCoverLoader.clearMemoryCache()
        let first = fixtureClient()
        let second = fixtureClient()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let bytes = try #require(image.pngData())
        LibraryHTTPProtocol.handler = { _ in (200, ["Content-Type": "image/png"], bytes) }
        let url = "https://library.example/cover.png"
        #expect(await BookCoverLoader.loadImage(urlString: url, headers: [:], session: first.session) != nil)
        #expect(BookCoverLoader.cachedImage(for: url, session: first.session) != nil)
        #expect(BookCoverLoader.cachedImage(for: url, session: second.session) == nil)
        #expect(BookCoverLoader.cachedImage(for: url) == nil)
        BookCoverLoader.clearMemoryCache()
    }

    private func fixtureClient() -> RemoteLibraryHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LibraryHTTPProtocol.self]
        return RemoteLibraryHTTPClient(baseURL: base, configuration: configuration)
    }
}

private final class LibraryHTTPProtocol: Foundation.URLProtocol {
    static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { return }
        let (status, headers, data) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class LibraryChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}
