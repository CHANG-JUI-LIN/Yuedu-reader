import Combine
import Foundation
import Testing
@testable import yuedu_app

/// Search 9e (maintainer, 2026-10-15): 搜索 asks for every page by itself after page 1, at a
/// pace the phone allows — at most 10 pages, waiting while the phone is hot, half the width
/// while it is warm or in Low Power Mode. 換源 stays at page 1.
@Suite("Search auto-paging", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct SearchAutoPagingTests {
    // MARK: - The pace

    @Test("the width: configured when cool, half when warm or in Low Power Mode, never 0")
    func laterPageWidth() {
        func width(_ thermal: ProcessInfo.ThermalState, lowPower: Bool = false, configured: Int = 8) -> Int {
            SearchDevicePacing(thermalState: thermal, isLowPower: lowPower).laterPageConcurrency(configured: configured)
        }
        #expect(width(.nominal) == 8)
        #expect(width(.nominal, lowPower: true) == 4)
        #expect(width(.fair) == 4)
        #expect(width(.nominal, configured: 1) == 1)
        #expect(width(.fair, configured: 1) == 1)
    }

    @Test("later pages wait while the phone is hot")
    func holdsWhenHot() {
        #expect(!SearchDevicePacing(thermalState: .nominal, isLowPower: true).holdsLaterPages)
        #expect(!SearchDevicePacing(thermalState: .fair, isLowPower: false).holdsLaterPages)
        #expect(SearchDevicePacing(thermalState: .serious, isLowPower: false).holdsLaterPages)
        #expect(SearchDevicePacing(thermalState: .critical, isLowPower: false).holdsLaterPages)
    }

    // MARK: - Through the aggregator

    @Test("pages come by themselves until a page adds nothing")
    func pagesUntilExhausted() async {
        let site = PagingSite(pages: 3)
        let aggregator = SearchAggregator(fetcher: site.fetcher, device: FakeDevice().conditions)
        defer { site.clearCache() }

        aggregator.search(query: site.query, sources: [site.source])
        await finished(aggregator)

        #expect(site.pagesAsked == [1, 2, 3, 4], "page 4 is empty: the source is done")
        #expect(aggregator.results.count == 9)
    }

    @Test("a source that never runs dry stops at page 10")
    func stopsAtTen() async {
        let site = PagingSite(pages: nil)
        let aggregator = SearchAggregator(fetcher: site.fetcher, device: FakeDevice().conditions)
        defer { site.clearCache() }

        aggregator.search(query: site.query, sources: [site.source])
        await finished(aggregator)

        #expect(site.pagesAsked == Array(1...10))
    }

    @Test("換源 stays at page 1")
    func changeSourceDoesNotPage() async {
        let site = PagingSite(pages: 3)
        let aggregator = SearchAggregator(fetcher: site.fetcher, device: FakeDevice().conditions)
        defer { site.clearCache() }

        aggregator.search(query: site.query, sources: [site.source], origin: .changeSource)
        await finished(aggregator)

        #expect(site.pagesAsked == [1])
    }

    @Test("hot: page 2 waits for the phone to cool, then the rest come")
    func waitsForCooling() async {
        let site = PagingSite(pages: 3)
        let device = FakeDevice()
        device.set(.serious)
        let aggregator = SearchAggregator(fetcher: site.fetcher, device: device.conditions)
        defer { site.clearCache() }

        aggregator.search(query: site.query, sources: [site.source])
        await device.nextWait()

        #expect(site.pagesAsked == [1], "page 1 runs whatever the heat")
        #expect(aggregator.isSearching)
        device.set(.nominal)
        await finished(aggregator)
        #expect(site.pagesAsked == [1, 2, 3, 4])
    }

    @Test("paused while the later pages wait, resumed: they go on from there")
    func pauseAndResumeLaterPages() async {
        let site = PagingSite(pages: 3)
        let device = FakeDevice()
        device.set(.serious)
        let aggregator = SearchAggregator(fetcher: site.fetcher, device: device.conditions)
        defer { site.clearCache() }

        aggregator.search(query: site.query, sources: [site.source])
        await device.nextWait()
        aggregator.pause()
        #expect(aggregator.isPaused)
        #expect(!aggregator.isSearching)

        device.set(.nominal)
        aggregator.resume()
        #expect(aggregator.isSearching)
        await finished(aggregator)
        #expect(site.pagesAsked == [1, 2, 3, 4])
        #expect(!aggregator.isPaused)
    }

    /// Returns once the search has ended.
    private func finished(_ aggregator: SearchAggregator) async {
        for await isSearching in aggregator.$isSearching.values where !isSearching { break }
    }
}

/// A book source on its own stubbed host: `pages` pages of three books whose titles carry the
/// query, then empty pages; `nil` never runs dry.
@MainActor
private struct PagingSite {
    let host = "paging-\(UUID().uuidString.prefix(8).lowercased()).test"
    let query = "pg\(UUID().uuidString.prefix(6).lowercased())"
    let source: BookSource
    let fetcher = BookSourceFetcher(webFetcher: WebFetcher(session: PagingStubURLProtocol.session()))

    init(pages: Int?) {
        var source = BookSource()
        source.bookSourceName = host
        source.bookSourceUrl = "https://\(host)"
        source.searchUrl = "https://\(host)/search?q={{key}}&page={{page}}"
        source.ruleSearch.bookList = "li.book"
        source.ruleSearch.name = "a@text"
        source.ruleSearch.bookUrl = "a@href"
        self.source = source
        PagingStubURLProtocol.serve(host: host, pages: pages, title: query)
    }

    var pagesAsked: [Int] { PagingStubURLProtocol.pagesAsked(host: host) }

    func clearCache() { SearchResultCache.shared.clear(query: query, source: source) }
}

/// The phone's state as a test sets it. `nextWait()` returns once the search has started
/// waiting for a change, so a test checks a held search without timing.
private final class FakeDevice: @unchecked Sendable {
    private let lock = NSLock()
    private var pacing = SearchDevicePacing(thermalState: .nominal, isLowPower: false)
    private var listeners: [AsyncStream<Void>.Continuation] = []
    private let waits: AsyncStream<Void>
    private let waitStarted: AsyncStream<Void>.Continuation

    init() {
        (waits, waitStarted) = AsyncStream.makeStream()
    }

    func set(_ thermal: ProcessInfo.ThermalState) {
        let listeners = lock.withLock {
            pacing.thermalState = thermal
            return self.listeners
        }
        for listener in listeners { listener.yield() }
    }

    func nextWait() async {
        var iterator = waits.makeAsyncIterator()
        _ = await iterator.next()
    }

    var conditions: SearchDeviceConditions {
        SearchDeviceConditions(
            current: { self.lock.withLock { self.pacing } },
            changes: {
                AsyncStream { continuation in
                    self.lock.withLock { self.listeners.append(continuation) }
                    self.waitStarted.yield()
                }
            }
        )
    }
}

/// Serves each test host's pages and remembers which were asked for.
private final class PagingStubURLProtocol: URLProtocol {
    private struct Site {
        var pages: Int?
        var title: String
        var asked: [Int] = []
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var sites: [String: Site] = [:]

    static func serve(host: String, pages: Int?, title: String) {
        lock.withLock { sites[host] = Site(pages: pages, title: title) }
    }

    static func pagesAsked(host: String) -> [Int] {
        lock.withLock { sites[host]?.asked ?? [] }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PagingStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return lock.withLock { sites[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "page" }?.value.flatMap(Int.init) ?? 1
        let site: Site? = Self.lock.withLock {
            Self.sites[host]?.asked.append(page)
            return Self.sites[host]
        }
        guard let site else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let items = site.pages.map { page <= $0 } ?? true
            ? (1...3).map { #"<li class="book"><a href="/b/\#(page)-\#($0)">\#(site.title) \#(page)-\#($0)</a></li>"# }
            : []
        let body = Data("<html><body><ul>\(items.joined())</ul></body></html>".utf8)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
