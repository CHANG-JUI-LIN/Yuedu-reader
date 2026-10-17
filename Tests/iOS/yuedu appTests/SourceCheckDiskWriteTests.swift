import Foundation
import Testing
@testable import yuedu_app

/// The disk writes Xcode Organizer attributed to 書源驗證 and to source requests (2.0.7 (127)
/// disk-write reports). Each test pins one of them.
@MainActor
@Suite(.serialized)
struct SourceCheckDiskWriteTests {

    // MARK: - TOC probe

    /// The TOC probe validates a book that is not on the shelf. Its table of contents used to
    /// be written to the TOC cache for every source checked — a full package per source, on a
    /// run that can cover 50,000 sources — and nothing ever read it back.
    @Test("the TOC probe of an HTTP source leaves no TOC cache behind")
    func tocProbeOfAnHTTPSourceWritesNoCache() async throws {
        let host = "toc-\(UUID().uuidString.lowercased()).yuedu.test"
        let tocURL = "https://\(host)/toc"
        DiskWriteStubURLProtocol.set(.page(Self.tocHTML), for: host)
        defer { DiskWriteStubURLProtocol.remove(host) }
        let real = BookSourceFetcher(webFetcher: WebFetcher(session: DiskWriteStubURLProtocol.session()))
        let source = Self.tocSource(url: "https://\(host)")
        defer { Self.removeTOCCache(tocURL: tocURL, source: source, fetcher: real) }

        let checker = try await Self.runTOCCheck(source: source, tocURL: tocURL, real: real)

        #expect(checker.items.first?.outcome(.toc).status == .pass)
        #expect(!FileManager.default.fileExists(atPath: real.tocPackagePath(tocUrl: tocURL, source: source).path))
        #expect(!FileManager.default.fileExists(atPath: real.tocFingerprintPath(tocUrl: tocURL, source: source).path))
    }

    /// Same contract on the Legado runtime branch, which saves through its own call site.
    /// A `data:` TOC URL takes that branch without touching the network.
    @Test("the TOC probe of a runtime source leaves no TOC cache behind")
    func tocProbeOfARuntimeSourceWritesNoCache() async throws {
        let marker = UUID().uuidString
        let html = Self.tocHTML.replacingOccurrences(of: "</dl>", with: "<!-- \(marker) --></dl>")
        let tocURL = "data:text/html;base64," + Data(html.utf8).base64EncodedString()
        let source = Self.tocSource(url: "https://runtime-\(marker.lowercased()).yuedu.test")
        let real = BookSourceFetcher(webFetcher: WebFetcher(session: DiskWriteStubURLProtocol.session()))
        #expect(source.shouldUseLegadoRuntimeFetch(for: tocURL))
        defer { Self.removeTOCCache(tocURL: tocURL, source: source, fetcher: real) }

        let checker = try await Self.runTOCCheck(source: source, tocURL: tocURL, real: real)

        #expect(checker.items.first?.outcome(.toc).status == .pass)
        #expect(!FileManager.default.fileExists(atPath: real.tocPackagePath(tocUrl: tocURL, source: source).path))
        #expect(!FileManager.default.fileExists(atPath: real.tocFingerprintPath(tocUrl: tocURL, source: source).path))
    }

    // MARK: - Library writes at the end of a run

    /// A run used to end with three whole-library writes: respond times, then 停用, then 刪除 —
    /// each one re-encoding every source (≈290 MB of JSON at 50,000). Every store mutation
    /// is one `library` assignment followed by one `save()`, so `mutationRevision` counts the
    /// saves deterministically, where counting file writes would depend on how the persist
    /// queue happens to coalesce them.
    @Test("a finished run lands respond times, 停用 and 刪除 in one library write")
    func aFinishedRunWritesTheLibraryOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceCheckDiskWrite-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let slow = BookSource(bookSourceUrl: "https://slow.yuedu.test", bookSourceName: "慢的來源")
        let broken = BookSource(bookSourceUrl: "https://broken.yuedu.test", bookSourceName: "壞的來源")
        var configured = [slow, broken]
        for index in configured.indices {
            configured[index].searchUrl = configured[index].bookSourceUrl + "/search?q={{key}}"
        }
        let store = BookSourceStore(directory: directory)
        store.replaceSourcesFromSync(configured)
        store.waitForQueuedWrites()

        let checker = BookSourceHealthChecker(
            fetcher: EndOfRunFetcher(slowURL: slow.bookSourceUrl, brokenURL: broken.bookSourceUrl),
            store: store
        )
        checker.policy.checkDiscovery = false
        checker.policy.badAction = .delete
        checker.policy.disableSlow = true
        checker.policy.slowThresholdMs = 100
        checker.prepare(sources: store.sources)

        let revisionBefore = store.mutationRevision
        await checker.runAll()

        #expect(store.mutationRevision - revisionBefore == 1)

        store.waitForQueuedWrites()
        let reloaded = BookSourceStore(directory: directory)
        await reloaded.waitUntilLoaded()
        #expect(reloaded.sources.map(\.id) == [slow.id])
        let landed = try #require(reloaded.sources.first)
        #expect(!landed.enabled)
        // The measured time of a passing source, not the 180,000 ms default.
        #expect((300..<180_000).contains(landed.respondTime))
    }

    // MARK: - URL cache

    /// Source requests went through sessions backed by `URLCache.shared`, whose Cache.db
    /// (and its WAL) took a write for every cacheable response — thousands per search or
    /// validation run. Nothing reads source pages back from that cache.
    @Test("source request sessions keep no URL cache")
    func sourceRequestSessionsKeepNoURLCache() {
        #expect(WebFetcher.defaultSessionConfiguration().urlCache == nil)
        #expect(LegadoJSBridge.requestSession.configuration.urlCache == nil)
    }

    /// The runtime fetch (search, detail, TOC and content of every source whose URL carries
    /// options or JS) sent its requests through `URLSession.shared` — the shared URL cache
    /// again — instead of the bridge's own request session.
    @Test("the runtime fetch goes through the bridge's request session")
    func runtimeFetchUsesTheBridgeRequestSession() async throws {
        let host = "runtime-\(UUID().uuidString.lowercased()).yuedu.invalid"
        DiskWriteStubURLProtocol.set(.page("<p>runtime page</p>"), for: host)
        defer { DiskWriteStubURLProtocol.remove(host) }
        let bridge = ModernParserBridge(
            source: BookSource(bookSourceUrl: "https://\(host)", bookSourceName: "runtime fixture"),
            requestSession: DiskWriteStubURLProtocol.session()
        )

        let (body, _) = try await bridge.fetch(ruleUrl: "https://\(host)/page")

        #expect(body.contains("runtime page"))
        #expect(DiskWriteStubURLProtocol.requestCount(for: host) == 1)
    }

    // MARK: - Fixtures

    private static let tocHTML = """
    <html><body><dl id="list">
    <dd><a href="/c/1">第一章 起</a></dd>
    <dd><a href="/c/2">第二章 承</a></dd>
    </dl></body></html>
    """

    private static func tocSource(url: String) -> BookSource {
        var source = BookSource(bookSourceUrl: url, bookSourceName: "目錄快取測試")
        source.searchUrl = url + "/search?q={{key}}"
        source.ruleToc.chapterList = "#list dd"
        source.ruleToc.chapterName = "a@text"
        source.ruleToc.chapterUrl = "a@href"
        return source
    }

    /// The TOC cache lives in the app's real Caches directory; don't leave a failed run's
    /// files in it.
    private static func removeTOCCache(tocURL: String, source: BookSource, fetcher: BookSourceFetcher) {
        try? FileManager.default.removeItem(at: fetcher.tocPackagePath(tocUrl: tocURL, source: source))
        try? FileManager.default.removeItem(at: fetcher.tocFingerprintPath(tocUrl: tocURL, source: source))
    }

    private static func runTOCCheck(
        source: BookSource,
        tocURL: String,
        real: BookSourceFetcher
    ) async throws -> BookSourceHealthChecker {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceCheckDiskWrite-\(UUID().uuidString)")
        let store = BookSourceStore(directory: directory)
        store.replaceSourcesFromSync([source])
        let checker = BookSourceHealthChecker(
            fetcher: TOCForwardingFetcher(real: real, tocURL: tocURL),
            store: store
        )
        checker.policy.checkDiscovery = false
        checker.policy.checkContent = false
        checker.prepare(sources: [source])
        await checker.runAll()
        store.waitForQueuedWrites()
        try FileManager.default.removeItem(at: directory)
        return checker
    }
}

// MARK: - Fetchers

/// Search and detail answer from memory; the TOC goes to a real `BookSourceFetcher`, with
/// exactly the arguments the checker passed, so its cache behaviour is the one under test.
private actor TOCForwardingFetcher: BookSourceHealthCheckFetching {
    private let real: BookSourceFetcher
    private let tocURL: String

    init(real: BookSourceFetcher, tocURL: String) {
        self.real = real
        self.tocURL = tocURL
    }

    func search(
        query: String,
        in source: BookSource,
        page: Int,
        earlyFilter: ((_ name: String, _ author: String) -> Bool)?,
        onHasMore: ((Bool?) -> Void)?,
        failureMode: BookSourceSearchFailureMode
    ) async throws -> [OnlineBook] {
        [validationBook(url: source.bookSourceUrl + "/book", toc: "", source: source)]
    }

    func discoverItems(page: Int, in source: BookSource) async -> [ModernParserBridge.DiscoverItem] { [] }

    func discoverBooks(
        from item: ModernParserBridge.DiscoverItem,
        page: Int,
        in source: BookSource
    ) async throws -> [OnlineBook] { [] }

    func fetchBookInfo(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        knownBook: OnlineBook?
    ) async throws -> OnlineBook {
        validationBook(url: url, toc: tocURL, source: source)
    }

    func fetchTOC(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) async throws -> [OnlineChapterRef] {
        Issue.record("the checker reads the TOC through fetchTOCPackage")
        return []
    }

    func fetchTOCPackage(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        onFirstPageReady: (([OnlineChapterRef]) -> Void)?,
        forceRefresh: Bool,
        runPreUpdateJs: Bool,
        writesCache: Bool
    ) async throws -> TOCPackage {
        try await real.fetchTOCPackage(
            tocUrl: tocUrl,
            source: source,
            runtimeVariables: runtimeVariables,
            onFirstPageReady: onFirstPageReady,
            forceRefresh: forceRefresh,
            runPreUpdateJs: runPreUpdateJs,
            writesCache: writesCache
        )
    }

    func fetchChapter(
        ref: OnlineChapterRef,
        bookId: UUID,
        source: BookSource,
        chapterReferer: String?
    ) async throws -> String {
        Issue.record("content is not checked in this run")
        return ""
    }
}

/// One source passes slowly (停用 under 「停用過慢」), the other fails at search (刪除).
private actor EndOfRunFetcher: BookSourceHealthCheckFetching {
    private let slowURL: String
    private let brokenURL: String

    init(slowURL: String, brokenURL: String) {
        self.slowURL = slowURL
        self.brokenURL = brokenURL
    }

    func search(
        query: String,
        in source: BookSource,
        page: Int,
        earlyFilter: ((_ name: String, _ author: String) -> Bool)?,
        onHasMore: ((Bool?) -> Void)?,
        failureMode: BookSourceSearchFailureMode
    ) async throws -> [OnlineBook] {
        if source.bookSourceUrl == brokenURL { throw URLError(.badServerResponse) }
        return [validationBook(url: source.bookSourceUrl + "/book", toc: "", source: source)]
    }

    func discoverItems(page: Int, in source: BookSource) async -> [ModernParserBridge.DiscoverItem] { [] }

    func discoverBooks(
        from item: ModernParserBridge.DiscoverItem,
        page: Int,
        in source: BookSource
    ) async throws -> [OnlineBook] { [] }

    func fetchBookInfo(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        knownBook: OnlineBook?
    ) async throws -> OnlineBook {
        validationBook(url: url, toc: url + "/toc", source: source)
    }

    func fetchTOC(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) async throws -> [OnlineChapterRef] {
        [OnlineChapterRef(index: 0, title: "第一章", url: tocUrl + "/1")]
    }

    func fetchChapter(
        ref: OnlineChapterRef,
        bookId: UUID,
        source: BookSource,
        chapterReferer: String?
    ) async throws -> String {
        // The fixture's only job here is to make this source's total time exceed the
        // 「過慢」 threshold the test sets.
        if source.bookSourceUrl == slowURL { try await Task.sleep(for: .milliseconds(300)) }
        return "第一章的正文內容，足夠通過驗證。"
    }
}

private func validationBook(url: String, toc: String, source: BookSource) -> OnlineBook {
    OnlineBook(
        name: "驗證用書", author: "作者", intro: "", coverUrl: "", bookUrl: url, tocUrl: toc,
        wordCount: "", lastChapter: "", kind: "", sourceId: source.id,
        sourceName: source.bookSourceName)
}

// MARK: - Stub transport

/// Serves registered hosts. It has to be in the session's configuration:
/// `URLProtocol.registerClass` does not reach a custom session.
private final class DiskWriteStubURLProtocol: URLProtocol {
    enum Reply {
        case page(String)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var requests: [String: Int] = [:]

    static func set(_ reply: Reply, for host: String) {
        lock.withLock { replies[host] = reply }
    }

    static func remove(_ host: String) {
        lock.withLock {
            replies[host] = nil
            requests[host] = nil
        }
    }

    static func requestCount(for host: String) -> Int {
        lock.withLock { requests[host] ?? 0 }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiskWriteStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return lock.withLock { replies[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let reply = Self.lock.withLock({ () -> Reply? in
                  Self.requests[host, default: 0] += 1
                  return Self.replies[host]
              }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        switch reply {
        case .page(let html):
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(html.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
