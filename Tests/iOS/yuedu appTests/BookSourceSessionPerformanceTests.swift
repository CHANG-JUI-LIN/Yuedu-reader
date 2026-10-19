import Foundation
import Testing
@testable import yuedu_app

/// Wall-clock cost of the per-source session on the paths the reader and search lean on, with
/// the network stubbed out so only scheduling, script hops and parsing remain. Prints one
/// `SESSION_PERF` line per scenario (median and p90 in ms) for before/after comparisons of the
/// session's scheduling; the assertions only check that every run produced its content.
@Suite("Book source session performance", .serialized)
struct BookSourceSessionPerformanceTests {
    @Test("chapter fetch, one at a time, through the session")
    func sequentialChapterFetch() async throws {
        let fetcher = Self.fetcher()
        let source = Self.chapterSource()
        _ = try await fetcher.fetchChapter(ref: Self.chapter(0), bookId: UUID(), source: source)

        var samples: [Double] = []
        for index in 1...24 {
            let start = ContinuousClock.now
            let content = try await fetcher.fetchChapter(ref: Self.chapter(index), bookId: UUID(), source: source)
            samples.append(Self.ms(since: start))
            #expect(content.contains("第\(index)章正文") && content.contains("〔js〕"), "the JS content rule ran")
        }
        Self.report("chapter.sequential", samples)
    }

    @Test("four chapters at once on one source, as after a jump")
    func prefetchFourChapters() async throws {
        let fetcher = Self.fetcher()
        let source = Self.chapterSource()
        _ = try await fetcher.fetchChapter(ref: Self.chapter(0), bookId: UUID(), source: source)

        var samples: [Double] = []
        for round in 0..<10 {
            let start = ContinuousClock.now
            let contents = try await withThrowingTaskGroup(of: String.self) { group in
                for offset in 1...4 {
                    let index = 100 + round * 4 + offset
                    group.addTask {
                        try await fetcher.fetchChapter(ref: Self.chapter(index), bookId: UUID(), source: source)
                    }
                }
                return try await group.reduce(into: [String]()) { $0.append($1) }
            }
            samples.append(Self.ms(since: start))
            #expect(contents.count == 4 && contents.allSatisfy { $0.contains("章正文") && $0.contains("〔js〕") })
        }
        Self.report("chapter.prefetch4", samples)
    }

    @Test("a chapter whose rule URL is a data URI, through the runtime fetch")
    func runtimeChapterFetch() async throws {
        let fetcher = Self.fetcher()
        let source = Self.chapterSource()
        var samples: [Double] = []
        for index in 0..<24 {
            let html = "<div id=\"c\">第\(index)章正文</div>"
            let url = "data:text/html;base64," + Data(html.utf8).base64EncodedString()
            let ref = OnlineChapterRef(index: index, title: "第\(index)章", url: url)
            let start = ContinuousClock.now
            let content = try await fetcher.fetchChapter(ref: ref, bookId: UUID(), source: source)
            if index > 0 { samples.append(Self.ms(since: start)) }
            #expect(content.contains("第\(index)章正文") && content.contains("〔js〕"), "the JS content rule ran")
        }
        Self.report("chapter.runtime", samples)
    }

    @Test("search across twelve sources at once")
    func searchFanOut() async throws {
        let fetcher = Self.fetcher()
        let sources = (0..<12).map(Self.searchSource)
        var samples: [Double] = []
        for round in 0..<8 {
            let query = "perf-\(round)-\(UUID().uuidString.prefix(6))"
            let start = ContinuousClock.now
            let names = try await withThrowingTaskGroup(of: [String].self) { group in
                for source in sources {
                    group.addTask { try await fetcher.searchOutcome(query: query, in: source).books.map(\.name) }
                }
                return try await group.reduce(into: [[String]]()) { $0.append($1) }
            }
            if round > 0 { samples.append(Self.ms(since: start)) }
            // The JS name rule trims the stub's padded " 書N ".
            #expect(names.count == 12 && names.allSatisfy { $0 == ["書1", "書2", "書3"] })
            for source in sources { SearchResultCache.shared.clear(query: query, source: source) }
        }
        Self.report("search.fanout12", samples)
    }

    /// A reader chapter (task priority `.high`) arriving while four prefetches (`.utility`) are
    /// queued behind a held session: it should wait for its own parse only, not for the four.
    /// Measured from the holder's release to the chapter's content.
    @Test("a jump's chapter behind four queued prefetches", .timeLimit(.minutes(1)))
    func jumpBehindQueuedPrefetches() async throws {
        let fetcher = Self.fetcher()
        let source = Self.chapterSource()
        let session = BookSourceSession.session(for: source)
        _ = try await fetcher.fetchChapter(ref: Self.chapter(0), bookId: UUID(), source: source)

        var samples: [Double] = []
        for round in 0..<6 {
            let release = Self.holdSession(session)
            let prefetches = Self.queuePrefetches(4, holdingEach: 0.04, on: session)
            try await Self.waitUntilQueued(4, on: session)
            let index = 300 + round
            let jump = Task(priority: .high) {
                try await fetcher.fetchChapter(ref: Self.chapter(index), bookId: UUID(), source: source)
            }
            try await Self.waitUntilQueued(5, on: session)
            let start = ContinuousClock.now
            release.signal()
            let content = try await jump.value
            samples.append(Self.ms(since: start))
            #expect(content.contains("第\(index)章正文") && content.contains("〔js〕"))
            await withCheckedContinuation { done in prefetches.notify(queue: .global()) { done.resume() } }
        }
        Self.report("contention.jumpBehind4Prefetches(40ms each)", samples)
    }

    /// The same jump with the holder — and then also the prefetches — taking the turn from a
    /// task (`withTurn`) instead of the raw-thread entry, to tell the entry's own hops apart
    /// from the turn hand-offs themselves.
    @Test("a jump's chapter behind four queued prefetches, turns taken from tasks", .timeLimit(.minutes(1)))
    func jumpBehindQueuedPrefetchesFromTasks() async throws {
        let fetcher = Self.fetcher()
        let source = Self.chapterSource()
        let session = BookSourceSession.session(for: source)
        _ = try await fetcher.fetchChapter(ref: Self.chapter(0), bookId: UUID(), source: source)

        for prefetchesFromTasks in [false, true] {
            var samples: [Double] = []
            for round in 0..<6 {
                let release = await Self.holdTurn(session)
                let prefetches = prefetchesFromTasks
                    ? Self.queueTurnPrefetches(4, holdingEach: 0.04, on: session)
                    : Self.queuePrefetches(4, holdingEach: 0.04, on: session)
                try await Self.waitUntilQueued(4, on: session)
                let index = 400 + round + (prefetchesFromTasks ? 10 : 0)
                let jump = Task(priority: .high) {
                    try await fetcher.fetchChapter(ref: Self.chapter(index), bookId: UUID(), source: source)
                }
                try await Self.waitUntilQueued(5, on: session)
                let start = ContinuousClock.now
                release.signal()
                let content = try await jump.value
                samples.append(Self.ms(since: start))
                #expect(content.contains("第\(index)章正文") && content.contains("〔js〕"))
                await withCheckedContinuation { done in prefetches.notify(queue: .global()) { done.resume() } }
            }
            Self.report(
                prefetchesFromTasks
                    ? "contention.jumpBehind4Prefetches.allTurnsFromTasks"
                    : "contention.jumpBehind4Prefetches.holderFromTask",
                samples
            )
        }
    }

    /// A runtime fetch's script half (here `prepareFetch` answering a `data:` URI, no JS) while
    /// another caller holds the session for 100 ms, standing in for a parse parked in
    /// `java.startBrowserAwait`. Measured from the fetch's start to its result.
    @Test("a fetch's script half while a parse holds the session", .timeLimit(.minutes(1)))
    func scriptHalfBehindParkedParse() async throws {
        let source = Self.chapterSource()
        let session = BookSourceSession.session(for: source)
        let url = "data:text/html;base64," + Data("<p>x</p>".utf8).base64EncodedString()
        _ = try await Self.runtimeFetch(url, on: session)

        var samples: [Double] = []
        for _ in 0..<6 {
            let release = Self.holdSession(session)
            Thread {
                Thread.sleep(forTimeInterval: 0.1)
                release.signal()
            }.start()
            let start = ContinuousClock.now
            let (body, _) = try await Self.runtimeFetch(url, on: session)
            samples.append(Self.ms(since: start))
            #expect(body.contains("x"))
            try await Self.waitUntilIdle(session)
        }
        Self.report("contention.scriptHalfBehind100msHold", samples)
    }

    /// While a source's verification page is open (a parse parked in `startBrowserAwait`,
    /// here a caller holding the session for 1 s), four prefetches of that source fetch pages
    /// with 150 ms of network each. Wall time of the four, from their start.
    @Test("four fetches while a verification page holds the source for 1 s", .timeLimit(.minutes(1)))
    func prefetchesWhileVerificationPageOpen() async throws {
        let session = BookSourceSession(source: Self.chapterSource(), requestSession: SessionPerfNetworkURLProtocol.session())
        _ = try await Self.runtimeFetch(SessionPerfNetworkURLProtocol.page(0), on: session)

        var samples: [Double] = []
        for round in 0..<4 {
            let release = Self.holdSession(session)
            Thread {
                Thread.sleep(forTimeInterval: 1)
                release.signal()
            }.start()
            let start = ContinuousClock.now
            let bodies = try await Self.fetchConcurrently((1...4).map { SessionPerfNetworkURLProtocol.page(round * 4 + $0) }, on: session)
            samples.append(Self.ms(since: start))
            #expect(bodies.count == 4 && bodies.allSatisfy { $0.contains("第") && $0.count > 30_000 })
            try await Self.waitUntilIdle(session)
        }
        Self.report("verification.4fetchesWhileHeld1s(net150ms)", samples)
    }

    /// Four fetches of large GBK pages on one CSS-only source at once, nothing holding it: the
    /// response decodes run concurrently or one after another. Wall time of the four, and of a
    /// single fetch for scale.
    @Test("four fetches with charset decodes on one source", .timeLimit(.minutes(1)))
    func concurrentCharsetDecodes() async throws {
        let session = BookSourceSession(source: Self.chapterSource(), requestSession: SessionPerfNetworkURLProtocol.session())
        _ = try await Self.runtimeFetch(SessionPerfNetworkURLProtocol.page(0), on: session)

        var single: [Double] = []
        var four: [Double] = []
        for round in 0..<6 {
            var start = ContinuousClock.now
            _ = try await Self.runtimeFetch(SessionPerfNetworkURLProtocol.page(100 + round), on: session)
            single.append(Self.ms(since: start))
            start = ContinuousClock.now
            let bodies = try await Self.fetchConcurrently((1...4).map { SessionPerfNetworkURLProtocol.page(200 + round * 4 + $0) }, on: session)
            four.append(Self.ms(since: start))
            #expect(bodies.count == 4 && bodies.allSatisfy { $0.count > 30_000 })
        }
        Self.report("decode.single(net150ms)", single)
        Self.report("decode.4concurrent(net150ms)", four)
    }

    static func fetchConcurrently(_ urls: [String], on session: BookSourceSession) async throws -> [String] {
        try await withThrowingTaskGroup(of: String.self) { group in
            for url in urls {
                group.addTask { try await runtimeFetch(url, on: session).0 }
            }
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }
    }

    // MARK: - Contention helpers

    /// The one call that changes when the runtime fetch moves onto the per-source host.
    static func runtimeFetch(_ url: String, on session: BookSourceSession) async throws -> (String, String) {
        try await session.fetch(ruleUrl: url)
    }

    /// Takes the session on its own thread at `.utility` until the returned semaphore is signalled.
    static func holdSession(_ session: BookSourceSession) -> DispatchSemaphore {
        let release = DispatchSemaphore(value: 0)
        let held = DispatchSemaphore(value: 0)
        Thread {
            session.withBridge(priority: .utility) { _ in
                held.signal()
                release.wait()
            }
        }.start()
        held.wait()
        return release
    }

    /// `holdSession`, with the turn taken from a `.utility` task through `withTurn`.
    static func holdTurn(_ session: BookSourceSession) async -> DispatchSemaphore {
        let release = DispatchSemaphore(value: 0)
        await withCheckedContinuation { (held: CheckedContinuation<Void, Never>) in
            Task(priority: .utility) {
                await session.withTurn { _ in
                    held.resume()
                    release.wait()
                }
            }
        }
        return release
    }

    /// `queuePrefetches`, each caller a `.utility` task taking the turn through `withTurn`.
    static func queueTurnPrefetches(_ count: Int, holdingEach seconds: TimeInterval, on session: BookSourceSession) -> DispatchGroup {
        let done = DispatchGroup()
        for _ in 0..<count {
            done.enter()
            Task(priority: .utility) {
                await session.withTurn { _ in Thread.sleep(forTimeInterval: seconds) }
                done.leave()
            }
        }
        return done
    }

    /// Queues `count` `.utility` callers that each keep the session for `seconds`, as a 段評
    /// source's neighbour prefetches do; the group is left when all have run.
    static func queuePrefetches(_ count: Int, holdingEach seconds: TimeInterval, on session: BookSourceSession) -> DispatchGroup {
        let done = DispatchGroup()
        for _ in 0..<count {
            done.enter()
            Thread {
                session.withBridge(priority: .utility) { _ in Thread.sleep(forTimeInterval: seconds) }
                done.leave()
            }.start()
        }
        return done
    }

    static func waitUntilQueued(_ count: Int, on session: BookSourceSession) async throws {
        let deadline = Date().addingTimeInterval(5)
        while session.queuedCallers < count {
            try #require(Date() < deadline, "session queue never reached \(count) callers")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// Until the holder of the previous round has released, so rounds do not overlap.
    static func waitUntilIdle(_ session: BookSourceSession) async throws {
        await withCheckedContinuation { idle in
            Thread {
                session.withBridge(priority: .utility) { _ in }
                idle.resume()
            }.start()
        }
    }

    // MARK: - Fixtures

    static func fetcher() -> BookSourceFetcher {
        BookSourceFetcher(webFetcher: WebFetcher(session: SessionPerfURLProtocol.session()))
    }

    static func chapter(_ index: Int) -> OnlineChapterRef {
        OnlineChapterRef(index: index, title: "第\(index)章", url: "https://\(SessionPerfURLProtocol.host)/c/\(index)")
    }

    /// Native fetch, JS in the content rule, so every chapter takes the session for a script.
    static func chapterSource() -> BookSource {
        var source = BookSource(
            bookSourceUrl: "https://\(SessionPerfURLProtocol.host)/chapters#\(UUID().uuidString)",
            bookSourceName: "Session perf chapters"
        )
        source.ruleContent.content = "div#c@text@js:result + '〔js〕'"
        return source
    }

    /// Native search with a JS name rule, so each source's parse runs a script per book.
    static func searchSource(_ index: Int) -> BookSource {
        var source = BookSource(
            bookSourceUrl: "https://\(SessionPerfURLProtocol.host)/search-\(index)#\(UUID().uuidString)",
            bookSourceName: "Session perf search \(index)"
        )
        source.searchUrl = "https://\(SessionPerfURLProtocol.host)/s/\(index)?q={{key}}"
        source.ruleSearch.bookList = "li.book"
        source.ruleSearch.name = "a@text@js:result.trim()"
        source.ruleSearch.author = "span@text"
        source.ruleSearch.bookUrl = "a@href"
        return source
    }

    static func ms(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    static func report(_ name: String, _ samples: [Double]) {
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let p90 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
        print(String(format: "SESSION_PERF %@ n=%d median=%.2fms p90=%.2fms", name, sorted.count, median, p90))
    }
}

/// Answers chapter pages and search pages for `BookSourceSessionPerformanceTests` from the
/// session's configuration, without delay: the scenarios measure the session, not a network.
private final class SessionPerfURLProtocol: URLProtocol {
    static let host = "session-perf.test"

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SessionPerfURLProtocol.self]
        configuration.httpMaximumConnectionsPerHost = 32
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let parts = url.path.split(separator: "/")
        let html: String
        if parts.first == "c", let index = parts.last {
            html = "<html><body><div id=\"c\">第\(index)章正文" + String(repeating: "段落。", count: 400) + "</div></body></html>"
        } else {
            html = "<ul>" + (1...3).map {
                "<li class=\"book\"><a href=\"/b/\($0)\"> 書\($0) </a><span>作者\($0)</span></li>"
            }.joined() + "</ul>"
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Pages with 150 ms of network and a GBK body (~100 KB) that the fetch has to decode, for
/// the scenarios that measure what waits behind a held source.
private final class SessionPerfNetworkURLProtocol: URLProtocol {
    static let host = "session-perf-net.test"
    private static let gbk = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SessionPerfNetworkURLProtocol.self]
        configuration.httpMaximumConnectionsPerHost = 16
        return URLSession(configuration: configuration)
    }

    static func page(_ index: Int) -> String { "https://\(host)/p/\(index)" }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let html = "<html><body><div id=\"c\">" + url.lastPathComponent
            + String(repeating: "第一段落的文字內容，用來量測解碼。", count: 3_000) + "</div></body></html>"
        let data = (html as NSString).data(using: Self.gbk) ?? Data()
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=gbk"]
        )!
        // Stands in for the network round trip.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
