import Foundation
import Testing
@testable import yuedu_app

/// Unified library, Phase 0b: the native search path tells a legitimately empty page from
/// a failure and logs the failure, while `search(…)` keeps returning exactly what it always
/// did. `SourceHealthStore` is untouched (design §17 item 9).
@Suite("Book source search outcome", .serialized)
struct BookSourceSearchOutcomeTests {
    // MARK: - The mapping, both failure modes

    @Test("errors reported as no results in both modes")
    func reportedAsEmptyInBothModes() {
        let rows: [(Error, BookSourceSearchFailure)] = [
            (FetchError.encodingError, .encoding),
            (FetchError.httpError(401), .http(401)),
            (FetchError.httpError(403), .http(403)),
            (FetchError.httpError(404), .http(404)),
            (FetchError.httpError(429), .http(429)),
            (FetchError.httpError(500), .http(500)),
            (FetchError.httpError(502), .http(502)),
            (FetchError.httpError(503), .http(503)),
            (FetchError.emptyContent, .emptyContent),
        ]
        for (error, failure) in rows {
            for mode in [BookSourceSearchFailureMode.emptyResult, .propagateTransportError] {
                #expect(BookSourceSearchFailure.disposition(of: error, mode: mode) == .reportedAsEmpty(failure))
            }
        }
    }

    @Test("other fetch errors are thrown in both modes")
    func otherFetchErrorsAreThrown() {
        let errors: [Error] = [
            FetchError.httpError(418),
            FetchError.httpError(504),
            FetchError.invalidURL("x"),
            FetchError.cloudflareChallengeRequired("https://phase0-outcome.test"),
            FetchError.noSearchURL,
        ]
        for error in errors {
            for mode in [BookSourceSearchFailureMode.emptyResult, .propagateTransportError] {
                #expect(BookSourceSearchFailure.disposition(of: error, mode: mode) == .thrown)
            }
        }
    }

    @Test("transport errors are reported as no results, unless the caller asked for them")
    func transportErrorsDependOnTheMode() {
        let offline = URLError(.notConnectedToInternet)
        #expect(BookSourceSearchFailure.disposition(of: offline, mode: .emptyResult)
            == .reportedAsEmpty(.transport(offline.localizedDescription)))
        #expect(BookSourceSearchFailure.disposition(of: offline, mode: .propagateTransportError) == .thrown)
    }

    @Test("a cancelled request is reported as no results, as before, but as a cancellation")
    func cancellationIsItsOwnReason() {
        #expect(BookSourceSearchFailure.disposition(of: CancellationError(), mode: .emptyResult)
            == .reportedAsEmpty(.cancelled))
        #expect(BookSourceSearchFailure.disposition(of: URLError(.cancelled), mode: .emptyResult)
            == .reportedAsEmpty(.cancelled))
        #expect(BookSourceSearchFailure.disposition(of: CancellationError(), mode: .propagateTransportError) == .thrown)
    }

    // MARK: - Through a stubbed request

    @Test("a page with books is results")
    func pageWithBooks() async throws {
        let (fetcher, source, query) = setUp("books", reply: .page(
            #"<ul><li class="book"><a href="/b/1">三體</a></li><li class="book"><a href="/b/2">三體II</a></li></ul>"#
        ))
        defer { SearchResultCache.shared.clear(query: query, source: source) }

        let outcome = try await fetcher.searchOutcome(query: query, in: source)

        #expect(outcome.books.map(\.name) == ["三體", "三體II"])
        #expect(outcome.failure == nil)
    }

    @Test("a page without books is legitimately empty")
    func pageWithoutBooks() async throws {
        let (fetcher, source, query) = setUp("empty", reply: .page("<ul></ul>"))

        let outcome = try await fetcher.searchOutcome(query: query, in: source)

        guard case .empty = outcome else {
            Issue.record("Expected .empty, got \(outcome)")
            return
        }
    }

    @Test("a 403 is a failure, and search() still returns no books in both modes")
    func forbiddenIsAFailure() async throws {
        let (fetcher, source, query) = setUp("forbidden", reply: .status(403))

        let outcome = try await fetcher.searchOutcome(query: query, in: source)
        #expect(outcome.failure == .http(403))
        #expect(try await fetcher.search(query: query, in: source).isEmpty)
        #expect(try await fetcher.search(query: query, in: source, failureMode: .propagateTransportError).isEmpty)
    }

    @Test("an unlisted status is thrown, as before")
    func unlistedStatusIsThrown() async {
        let (fetcher, source, query) = setUp("teapot", reply: .status(418))

        await #expect(throws: FetchError.self) {
            _ = try await fetcher.searchOutcome(query: query, in: source)
        }
    }

    @Test("a transport error is a failure for search, and thrown for validation")
    func transportErrorDependsOnTheMode() async throws {
        let (fetcher, source, query) = setUp("offline", reply: .failure(URLError(.notConnectedToInternet)))

        let outcome = try await fetcher.searchOutcome(query: query, in: source)
        guard case .failed(.transport) = outcome else {
            Issue.record("Expected a transport failure, got \(outcome)")
            return
        }
        #expect(try await fetcher.search(query: query, in: source).isEmpty)
        await #expect(throws: (any Error).self) {
            _ = try await fetcher.search(query: query, in: source, failureMode: .propagateTransportError)
        }
    }

    @Test("a failure leaves one log line with the source and the reason, never the query")
    func failureIsLoggedWithoutTheQuery() async throws {
        let (fetcher, source, query) = setUp("logged", reply: .status(503))
        let before = Set(DiagnosticLog.shared.snapshot().map(\.id))

        _ = try await fetcher.searchOutcome(query: query, in: source)

        let added = DiagnosticLog.shared.snapshot()
            .filter { !before.contains($0.id) && $0.message.contains(source.bookSourceName) }
        #expect(added.count == 1)
        let line = try #require(added.first)
        #expect(line.message.contains("shown as no results"))
        #expect(line.message.contains("HTTP 503"))
        #expect(line.message.contains("logged.phase0-outcome.test"))
        #expect(line.severity == .warning)
        #expect(!line.message.contains(query))
        #expect(!line.message.contains("/search"))
    }

    @Test("書源驗證's failures are not logged here: its own results list them")
    func validationFailuresAreNotLogged() async throws {
        let (fetcher, source, query) = setUp("validation", reply: .status(403))
        let before = Set(DiagnosticLog.shared.snapshot().map(\.id))

        let outcome = try await fetcher.searchOutcome(query: query, in: source, failureMode: .propagateTransportError)

        #expect(outcome.failure == .http(403))
        let added = DiagnosticLog.shared.snapshot()
            .filter { !before.contains($0.id) && $0.message.contains(source.bookSourceName) }
        #expect(added.isEmpty)
    }

    // MARK: - Helpers

    /// A fetcher whose requests are answered by `reply`, a native source on its own host,
    /// and a query no other test uses, so the search cache never answers instead.
    private func setUp(
        _ name: String,
        reply: SearchStubURLProtocol.Reply
    ) -> (BookSourceFetcher, BookSource, String) {
        let host = "\(name).phase0-outcome.test"
        SearchStubURLProtocol.set(reply, for: host)
        var source = BookSource()
        source.bookSourceName = "Phase 0 outcome \(name)"
        source.bookSourceUrl = "https://\(host)"
        source.searchUrl = "https://\(host)/search?q={{key}}"
        source.ruleSearch.bookList = "li.book"
        source.ruleSearch.name = "a@text"
        source.ruleSearch.bookUrl = "a@href"
        let fetcher = BookSourceFetcher(webFetcher: WebFetcher(session: SearchStubURLProtocol.session()))
        return (fetcher, source, "三體-\(UUID().uuidString.prefix(8))")
    }
}

/// Answers each test host with a page, a status or a transport error. It lives in the
/// session's configuration: `URLProtocol.registerClass` does not reach a custom session.
private final class SearchStubURLProtocol: URLProtocol {
    enum Reply {
        case page(String)
        case status(Int)
        case failure(URLError)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]

    static func set(_ reply: Reply, for host: String) {
        lock.withLock { replies[host] = reply }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SearchStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return lock.withLock { replies[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let reply = Self.lock.withLock({ Self.replies[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        switch reply {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .page(let html):
            respond(url: url, status: 200, body: Data(html.utf8))
        case .status(let code):
            respond(url: url, status: code, body: Data("<html></html>".utf8))
        }
    }

    private func respond(url: URL, status: Int, body: Data) {
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
