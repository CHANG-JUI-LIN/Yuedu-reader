import Foundation
import Testing
@testable import yuedu_app

/// A source's verification page (`java.startBrowserAwait`) holds its engine's JS queue for
/// as long as the reader takes. `BookSource.parsedHeaders` is read on the main thread (cover
/// cells, the reader's inline images), and on a header cache miss it used to `sync` onto that
/// same queue — so the main thread waited for a page it was itself responsible for showing,
/// and the app froze until the watchdog killed it (TestFlight AGT4StkW1MHoKzDbZNJd4So,
/// 「69书吧人机验证卡死」).
@Suite("Header rules read on the main thread", .serialized)
struct ParsedHeadersMainThreadTests {
    @MainActor
    @Test("a parked verification page does not block a main-thread header read")
    func mainThreadHeaderReadDoesNotWaitForParkedScript() async throws {
        let pages = ParkedPages()
        let previous = LegadoJSBridge.sharedBrowserPresenter
        LegadoJSBridge.sharedBrowserPresenter = { _, completion in pages.add(completion) }
        defer { LegadoJSBridge.sharedBrowserPresenter = previous }

        var source = BookSource(
            bookSourceUrl: "https://parked-\(UUID().uuidString.prefix(8).lowercased()).example",
            bookSourceName: "parked header source"
        )
        source.header = "@js:JSON.stringify({'X-Source-Token': 'abc'})"
        source.loginCheckJs = "java.startBrowserAwait('https://verify.example/', '驗證', false); result"
        defer { LoginManager.shared.clearLogin(sourceUrl: source.bookSourceUrl) }

        ParkedSourceProtocol.body = "<p>page</p>"
        let fetcher = BookSourceFetcher(webFetcher: WebFetcher(session: ParkedSourceProtocol.session()))
        let stage = Task.detached {
            try await fetcher.fetchStageHTML(
                url: URL(string: source.bookSourceUrl + "/search")!,
                method: "GET", body: nil, headers: [:],
                baseURL: source.bookSourceUrl, source: source)
        }
        let deadline = Date().addingTimeInterval(20)
        while pages.count < 1, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(pages.count == 1, "the source should be waiting on its verification page")

        // A login change while the page is up invalidates the engine's resolved headers, so
        // the next read has to reach the engine.
        LoginManager.shared.storeLoginHeader(sourceUrl: source.bookSourceUrl, raw: #"{"Cookie":"k=v"}"#)

        // Should the read block after all, release the page from a GCD thread so the test
        // fails on its timing instead of hanging the main thread for good.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { pages.releaseAll() }
        let started = Date()
        let headers = source.parsedHeaders
        let seconds = Date().timeIntervalSince(started)
        #expect(seconds < 1, "the main thread waited \(seconds) s on a script parked for the reader")
        #expect(headers == ["X-Source-Token": "abc"], "the last resolved headers stand in meanwhile")

        pages.releaseAll()
        #expect(try await stage.value == "<p>page</p>")
        // Once the page is gone the rule resolves against the new login state as before.
        #expect(BookSourceSession.session(for: source).bridgeForAsyncOperations.resolvedSourceHeaders() == ["X-Source-Token": "abc"])
    }
}

private final class ParkedPages: @unchecked Sendable {
    private let lock = NSLock()
    private var completions: [(String?) -> Void] = []

    func add(_ completion: @escaping (String?) -> Void) {
        lock.lock()
        completions.append(completion)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return completions.count
    }

    func releaseAll() {
        lock.lock()
        let pending = completions
        completions = []
        lock.unlock()
        pending.forEach { $0("<html>verified</html>") }
    }
}

private final class ParkedSourceProtocol: URLProtocol {
    nonisolated(unsafe) static var body = ""

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ParkedSourceProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
