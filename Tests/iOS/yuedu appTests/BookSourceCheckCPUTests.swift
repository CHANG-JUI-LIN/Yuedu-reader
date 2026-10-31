import Foundation
import os
import Testing
@testable import yuedu_app

/// The two stages that put 書源檢查 over MetricKit's CPU budget (90 s in 180 s; Crashlytics
/// 20727455, c0ec35f1, 77f93443, bdd4dca3), each on its own path. Measured on a 1492-source
/// check: one table of contents with a `~` rule took 129 s of CPU, and audio sources with no
/// content rule had their streams downloaded and parsed as pages — 61 s for one 37.8 MB file,
/// and a stack overflow on another.
@Suite("Book-source check CPU", .serialized)
struct BookSourceCheckCPUTests {

    // MARK: - Audio sources with no content rule

    @Test("an audio source with no content rule reads its chapter URL, unfetched")
    func audioSourceWithoutContentRuleReadsChapterURL() async throws {
        let fetcher = BookSourceFetcher(webFetcher: WebFetcher(session: MediaURLProtocol.session()))
        let source = Self.sourceWithoutContentRule(type: 1)
        let bookId = UUID()
        defer { fetcher.clearAllChapterCache(bookId: bookId) }

        let urls = [
            "https://\(MediaURLProtocol.host)/audio/1.mp3",
            "https://\(MediaURLProtocol.host)/audio/2.m4a,{\"headers\":{\"Referer\":\"https://\(MediaURLProtocol.host)/\"}}",
        ]
        for (index, url) in urls.enumerated() {
            let requestsBefore = MediaURLProtocol.requests
            let ref = OnlineChapterRef(index: index, title: "第\(index + 1)集", url: url)
            let package = try await fetcher.fetchChapterPackage(ref: ref, bookId: bookId, source: source)
            #expect(package.content == url)
            #expect(MediaURLProtocol.requests == requestsBefore, "the chapter URL was fetched: \(url)")
            #expect(DirectChapterAudioResolver.request(from: package.content) != nil)
        }
    }

    @Test("a text source with no content rule still reads its page through the heuristic")
    func textSourceWithoutContentRuleReadsPage() async throws {
        let fetcher = BookSourceFetcher(webFetcher: WebFetcher(session: MediaURLProtocol.session()))
        let source = Self.sourceWithoutContentRule(type: 0)
        let bookId = UUID()
        defer { fetcher.clearAllChapterCache(bookId: bookId) }

        let requestsBefore = MediaURLProtocol.requests
        let ref = OnlineChapterRef(index: 0, title: "第一章", url: "https://\(MediaURLProtocol.host)/text/1.html")
        let package = try await fetcher.fetchChapterPackage(ref: ref, bookId: bookId, source: source)
        #expect(MediaURLProtocol.requests == requestsBefore + 1)
        #expect(package.content.contains("第一段正文"))
        #expect(!package.content.contains("https://"))
    }

    // MARK: - General-sibling TOC rules

    /// ❤️图书迷子's rule on its page's shape: twelve 最新章节 entries under the first `dt`, the
    /// chapters under the second. SwiftSoup 2.13.7 walked back through every earlier sibling
    /// for each `dd`, rebuilding the sibling list at each step, so the rule grew cubically.
    /// Timed against a rule that selects the same entries without a combinator, on the same
    /// page, so the bound holds on any machine.
    @Test("a general-sibling TOC rule costs about what a plain one does")
    func generalSiblingTOCRule() throws {
        let sibling = Self.tocSource(chapterList: "#list > dl > dt:nth-of-type(2) ~ dd")
        let plain = Self.tocSource(chapterList: "#list > dl > dd")
        let siblingBridge = ModernParserBridge(source: sibling)
        let plainBridge = ModernParserBridge(source: plain)
        let baseURL = "https://\(Self.tocHost)/book/1/"

        var cells: [String] = []
        var ratio = 0.0
        for count in [150, 300, 600] {
            let html = Self.tocPage(chapters: count)
            var chapters: [OnlineChapterRef] = []
            var plainChapters: [OnlineChapterRef] = []
            let siblingMs = try Self.median {
                chapters = try siblingBridge.parseTOC(html: html, baseURL: baseURL, source: sibling)
            }
            let plainMs = try Self.median {
                plainChapters = try plainBridge.parseTOC(html: html, baseURL: baseURL, source: plain)
            }
            #expect(chapters.count == count)
            #expect(chapters.first?.url.hasSuffix("/book/1/1.html") == true)
            #expect(chapters.last?.url.hasSuffix("/book/1/\(count).html") == true)
            #expect(!chapters.contains { $0.url.contains("/latest/") })
            #expect(chapters.map(\.url) == plainChapters.dropFirst(12).map(\.url))
            ratio = siblingMs / plainMs
            cells.append("\(count)=\(String(format: "%.1f", siblingMs))ms/\(String(format: "%.1f", plainMs))ms")
        }
        print("TOC-SIBLING ~rule/plain \(cells.joined(separator: " ")) ratio@600=\(String(format: "%.1f", ratio))")
        #expect(ratio < 20, "\(cells)")
    }

    // MARK: - CPU pacing

    /// With both pathologies fixed, 1492 sources at 32 wide still spent 228 s of CPU in their
    /// busiest 180 s: many ordinary table-of-contents parses, no single culprit. The check
    /// narrows to what 0.4 of a core allows, measured on the process's own CPU, and to its
    /// floor while the trailing 180 s near MetricKit's 90.
    @Test("a check starts at a quarter of the configured width")
    func pacingStartsAtAQuarter() {
        #expect(BookSourceCheckPacing(ceiling: 32, start: .init(wall: 0, cpu: 0)).width == 8)
        #expect(BookSourceCheckPacing(ceiling: 6, start: .init(wall: 0, cpu: 0)).width == 2)
        #expect(BookSourceCheckPacing(ceiling: 1, start: .init(wall: 0, cpu: 0)).width == 1)
    }

    @Test("a window over the CPU target narrows the check to what the target allows")
    func pacingNarrowsWhenHot() {
        var pacing = BookSourceCheckPacing(ceiling: 32, start: .init(wall: 0, cpu: 0))
        // 8 sources in flight burning 0.7 of a core: 0.4 of a core allows 4.6 of them.
        #expect(pacing.sourceFinished(at: .init(wall: 5, cpu: 3.5), inFlight: 8) == nil)
        let cut = pacing.sourceFinished(at: .init(wall: 10, cpu: 7), inFlight: 8)
        #expect(cut?.from == 8)
        #expect(cut?.to == 4)
        #expect(pacing.width == 4)
    }

    /// The sources already in flight keep burning CPU after a cut. Acting on every completion
    /// would read their CPU as the new width's and cut straight to the floor.
    @Test("the next window measures the narrower width before the width changes again")
    func pacingWaitsOutTheWindow() {
        var pacing = BookSourceCheckPacing(ceiling: 32, start: .init(wall: 0, cpu: 0))
        _ = pacing.sourceFinished(at: .init(wall: 10, cpu: 7), inFlight: 8)
        #expect(pacing.sourceFinished(at: .init(wall: 15, cpu: 10.5), inFlight: 8) == nil)
        #expect(pacing.width == 4)
    }

    @Test("the mean in-flight count over the window, not the width, sizes the cut")
    func pacingUsesMeanInFlight() {
        var pacing = BookSourceCheckPacing(ceiling: 32, start: .init(wall: 0, cpu: 0))
        // 8 in flight for five seconds, 4 for the next five: 6 on average, at half a core.
        // The width (8) would allow 6; the last count (4) would allow 3.
        _ = pacing.sourceFinished(at: .init(wall: 5, cpu: 2.5), inFlight: 8)
        let cut = pacing.sourceFinished(at: .init(wall: 10, cpu: 5), inFlight: 4)
        #expect(cut?.to == 4)
    }

    /// Measured: `11→14 cores=0.62 inFlight=21.7`. Right after a cut, the sources still
    /// draining raise the mean in-flight count above the width, and the CPU each one spent
    /// came out low enough to allow more — in a window that had run over the target.
    @Test("a window over the CPU target never widens the check")
    func pacingDoesNotWidenWhileHot() {
        var pacing = BookSourceCheckPacing(ceiling: 32, start: .init(wall: 0, cpu: 0))
        // 20 in flight at 0.6 of a core would allow 13 at the CPU each spent.
        #expect(pacing.sourceFinished(at: .init(wall: 10, cpu: 6), inFlight: 20) == nil)
        #expect(pacing.width == 8)
    }

    @Test("a cool window widens by half, up to the configured width")
    func pacingWidensWhenCool() {
        var pacing = BookSourceCheckPacing(ceiling: 32, start: .init(wall: 0, cpu: 0))
        var widths: [Int] = []
        var wall = 0.0
        for _ in 0..<5 {
            wall += 10
            _ = pacing.sourceFinished(at: .init(wall: wall, cpu: 0), inFlight: pacing.width)
            widths.append(pacing.width)
        }
        #expect(widths == [12, 18, 27, 32, 32])
    }

    @Test("the width never falls below two, nor above the configured width")
    func pacingFloorAndCeiling() {
        var hot = BookSourceCheckPacing(ceiling: 32, start: .init(wall: 0, cpu: 0))
        _ = hot.sourceFinished(at: .init(wall: 10, cpu: 50), inFlight: 8)
        #expect(hot.width == 2)
        #expect(hot.minWidth == 2)

        var single = BookSourceCheckPacing(ceiling: 1, start: .init(wall: 0, cpu: 0))
        _ = single.sourceFinished(at: .init(wall: 10, cpu: 50), inFlight: 1)
        #expect(single.width == 1)
        _ = single.sourceFinished(at: .init(wall: 20, cpu: 50), inFlight: 1)
        #expect(single.width == 1)
    }

    /// Single sources spend up to 8 s of CPU on one table of contents, so a window can run
    /// hot at any width; at 0.4 of a core the measured run still had 180 s windows of 92.5 s.
    /// What MetricKit counts is the trailing 180 s, so that is watched at every completion.
    @Test("the trailing 180 s nearing the budget drops the check to its floor at once")
    func pacingGuardsTheTrailingBudget() {
        var pacing = BookSourceCheckPacing(ceiling: 32, start: .init(wall: 0, cpu: 0))
        _ = pacing.sourceFinished(at: .init(wall: 1, cpu: 0.4), inFlight: 8)
        let guarded = pacing.sourceFinished(at: .init(wall: 3, cpu: 66), inFlight: 8)
        #expect(guarded?.from == 8)
        #expect(guarded?.to == 2)

        // Cool windows do not widen it while the spike is inside the trailing 180 s...
        var wall = 3.0
        while wall < 170 {
            wall += 10
            _ = pacing.sourceFinished(at: .init(wall: wall, cpu: 66), inFlight: 2)
            #expect(pacing.width == 2, "widened at \(wall) s with the spike still counted")
        }
        // ...and do once it has rolled out.
        wall = 193
        _ = pacing.sourceFinished(at: .init(wall: wall, cpu: 66), inFlight: 2)
        #expect(pacing.width == 3)
    }

    @MainActor
    @Test("a check whose process runs hot narrows to the pacing's width")
    func hotCheckNarrows() async {
        let fetcher = InFlightRecordingFetcher()
        let clock = FakeCPUClock(busyCores: 4)
        let checker = BookSourceHealthChecker(fetcher: fetcher, cpuClock: clock.clock)
        checker.prepare(sources: Self.pacingSources(1_000))
        await checker.runAll()

        #expect(checker.finishedCount == 1_000)
        let inFlight = await fetcher.inFlightAtStart
        // 8 start, nine refill before the first window closes at four cores; then 0.4 of a
        // core allows less than one, and the check runs at its floor of two.
        #expect((inFlight.prefix(17).max() ?? 0) > 2)
        #expect((inFlight.dropFirst(17).max() ?? 0) <= 2, "\(inFlight.dropFirst(17).prefix(40))")
    }

    @MainActor
    @Test("a check whose process stays cool widens to the configured width")
    func coolCheckWidens() async {
        let fetcher = InFlightRecordingFetcher()
        let clock = FakeCPUClock(busyCores: 0)
        let checker = BookSourceHealthChecker(fetcher: fetcher, cpuClock: clock.clock)
        checker.prepare(sources: Self.pacingSources(1_000))
        await checker.runAll()

        #expect(checker.finishedCount == 1_000)
        let inFlight = await fetcher.inFlightAtStart
        #expect((inFlight.dropFirst(500).max() ?? 0) > 16)
    }

    // MARK: - Fixtures

    static let tocHost = "toc-sibling.test"

    /// A thousand sources, so the check runs at its 32-wide ceiling whatever 網路設定 says.
    static func pacingSources(_ count: Int) -> [BookSource] {
        (0..<count).map { index in
            var source = BookSource(
                bookSourceUrl: "https://pacing-\(index).test",
                bookSourceName: "pacing \(index)"
            )
            source.searchUrl = "https://pacing-\(index).test/search?q={{key}}"
            return source
        }
    }

    static func tocSource(chapterList: String) -> BookSource {
        var source = BookSource(
            bookSourceUrl: "https://\(tocHost)#\(UUID().uuidString)",
            bookSourceName: "TOC \(chapterList)"
        )
        source.ruleToc.chapterList = chapterList
        source.ruleToc.chapterName = "a@text"
        source.ruleToc.chapterUrl = "a@href"
        return source
    }

    static func sourceWithoutContentRule(type: Int) -> BookSource {
        var source = BookSource(
            bookSourceUrl: "https://\(MediaURLProtocol.host)/source-\(type)#\(UUID().uuidString)",
            bookSourceName: "No content rule \(type)"
        )
        source.bookSourceType = type
        return source
    }

    static func tocPage(chapters: Int) -> String {
        var html = "<html><body><div id=\"list\"><dl><dt>最新章节</dt>"
        for index in 1...12 {
            html += "<dd><a href=\"/latest/\(index).html\">最新第\(index)章</a></dd>"
        }
        html += "<dt>正文卷</dt>"
        for index in 1...chapters {
            html += "<dd><a href=\"/book/1/\(index).html\">第\(index)章 标题\(index)</a></dd>"
        }
        return html + "</dl></div></body></html>"
    }

    static func median(runs: Int = 3, _ work: () throws -> Void) rethrows -> Double {
        var samples: [Double] = []
        for _ in 0..<runs {
            let start = ContinuousClock.now
            try work()
            let elapsed = ContinuousClock.now - start
            samples.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        return samples.sorted()[samples.count / 2]
    }
}

/// Serves `/audio/…` as an audio stream (binary, `audio/mpeg`) and `/text/…` as a chapter page,
/// and counts every request so a test can tell whether a chapter URL was fetched at all.
private final class MediaURLProtocol: URLProtocol {
    static let host = "media-source.test"
    private static let counter = OSAllocatedUnfairLock(initialState: 0)

    static var requests: Int { counter.withLock { $0 } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.counter.withLock { $0 += 1 }
        let body: Data
        let contentType: String
        if url.path.hasPrefix("/audio/") {
            var generator = SystemRandomNumberGenerator()
            body = Data("ID3".utf8) + Data((0..<262_144).map { _ in UInt8.random(in: 0...255, using: &generator) })
            contentType = "audio/mpeg"
        } else {
            let paragraphs = (1...30).map { "<p>第\($0 == 1 ? "一" : "\($0)")段正文，内容足够长，让正文识别认出这是章节。</p>" }
            body = Data(("<html><body><div id=\"content\">" + paragraphs.joined() + "</div></body></html>").utf8)
            contentType = "text/html; charset=utf-8"
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Fails every source at search after holding it briefly, and records how many sources were in
/// flight as each one started.
private actor InFlightRecordingFetcher: BookSourceHealthCheckFetching {
    private(set) var inFlightAtStart: [Int] = []
    private var inFlight = 0

    nonisolated func search(
        query: String,
        in source: BookSource,
        page: Int,
        earlyFilter: (@Sendable (_ name: String, _ author: String) -> Bool)?,
        onHasMore: ((Bool?) -> Void)?,
        failureMode: BookSourceSearchFailureMode
    ) async throws -> [OnlineBook] {
        await enter()
        // The site's response time: long enough that the sources started together overlap.
        do {
            try await Task.sleep(for: .milliseconds(10))
        } catch {
            await leave()
            throw error
        }
        await leave()
        throw URLError(.timedOut)
    }

    private func enter() {
        inFlight += 1
        inFlightAtStart.append(inFlight)
    }

    private func leave() {
        inFlight -= 1
    }

    func discoverItems(page: Int, in source: BookSource) async -> [ModernParserBridge.DiscoverItem] { [] }

    func discoverBooks(
        from item: ModernParserBridge.DiscoverItem,
        page: Int,
        in source: BookSource
    ) async throws -> [OnlineBook] {
        []
    }

    func fetchBookInfo(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        knownBook: OnlineBook?
    ) async throws -> OnlineBook {
        throw URLError(.timedOut)
    }

    func fetchTOC(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) async throws -> [OnlineChapterRef] {
        throw URLError(.timedOut)
    }

    func fetchChapter(
        ref: OnlineChapterRef,
        bookId: UUID,
        source: BookSource,
        chapterReferer: String?
    ) async throws -> String {
        throw URLError(.timedOut)
    }
}

/// A process clock where each reading is one second after the last, with `busyCores` of CPU
/// spent per second: a check's pacing sees a hot or a cool process without burning either.
private final class FakeCPUClock: Sendable {
    private let wall = OSAllocatedUnfairLock(initialState: 0.0)
    private let busyCores: Double

    init(busyCores: Double) {
        self.busyCores = busyCores
    }

    var clock: BookSourceCheckCPUClock {
        BookSourceCheckCPUClock { [wall, busyCores] in
            let now = wall.withLock { value in
                value += 1
                return value
            }
            return BookSourceCheckPacing.Sample(wall: now, cpu: now * busyCores)
        }
    }
}
