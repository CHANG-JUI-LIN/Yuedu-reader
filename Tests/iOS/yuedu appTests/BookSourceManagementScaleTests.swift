import Foundation
import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// Scale probes for 書源管理 and 書源驗證 with tens of thousands of sources.
///
/// Opt-in, because they build 50,000-source libraries and render the real screens,
/// which takes minutes in a Debug build:
///
///     TEST_RUNNER_BOOK_SOURCE_SCALE_TESTS=1
///     TEST_RUNNER_BOOK_SOURCE_SCALE_CORPUS=<Legado JSON array of real sources>   (optional)
///     TEST_RUNNER_BOOK_SOURCE_SCALE_COUNTS=10000,30000,50000                     (optional)
///
/// Without a corpus the sources are synthesized at the size real packs have (≈5.8 KB of
/// rules per source, measured on 4,765 unique sources from yckceo packs). Every store here
/// lives in a temporary directory: nothing touches the simulator's own library.
/// Each probe prints one `SCALE …` line; the numbers are the evidence, not assertions.
@Suite(.serialized)
@MainActor
struct BookSourceManagementScaleTests {
    nonisolated private static func environment(_ key: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        return env[key] ?? env["TEST_RUNNER_" + key]
    }

    nonisolated private static let enabled = environment("BOOK_SOURCE_SCALE_TESTS") == "1"

    private static var counts: [Int] {
        let raw = environment("BOOK_SOURCE_SCALE_COUNTS") ?? "10000,30000,50000"
        return raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    // MARK: - 書源管理

    @Test(
        "opening 書源管理 with a large library",
        .enabled(if: enabled, "Set BOOK_SOURCE_SCALE_TESTS=1"),
        .timeLimit(.minutes(60))
    )
    func openManagementList() async throws {
        for grouped in [true, false] {
            for count in Self.counts {
                try await measureOpen(count: count, grouped: grouped)
            }
        }
    }

    private func measureOpen(count: Int, grouped: Bool) async throws {
        let fixture = try ScaleFixture(count: count)
        defer { fixture.remove() }
        let settings = GlobalSettings.shared
        let previousGrouped = settings.bookSourceListGrouped
        settings.bookSourceListGrouped = grouped
        defer { settings.bookSourceListGrouped = previousGrouped }

        let checker = BookSourceHealthChecker(fetcher: FatalTransportFetcher(), store: fixture.store)
        let sampler = FootprintSampler()
        let before = MemoryFootprint.current()
        sampler.start()
        let startedAt = ProcessInfo.processInfo.systemUptime
        // Hosted in a stack, as Settings and Explore push it.
        let host = try WindowHost(
            NavigationStack {
                BookSourceListView(store: fixture.store, healthChecker: checker)
            }
            .environmentObject(fixture.bookStore)
        )
        let firstLayoutMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
        host.pump(seconds: 0.5)
        let settledMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
        let settled = MemoryFootprint.current()
        let peak = sampler.stop()
        host.tearDown()
        print(
            "SCALE open grouped=\(grouped) sources=\(count) firstLayoutMs=\(Int(firstLayoutMs)) "
                + "settledMs=\(Int(settledMs)) footprintDeltaMB=\(mb(settled - before)) "
                + "peakDeltaMB=\(mb(peak - before))"
        )
    }

    @Test(
        "書源管理 interactions on a large library",
        .enabled(if: enabled, "Set BOOK_SOURCE_SCALE_TESTS=1"),
        .timeLimit(.minutes(60))
    )
    func managementInteractions() async throws {
        let count = Self.counts.max() ?? 50_000
        let fixture = try ScaleFixture(count: count)
        defer { fixture.remove() }
        let suite = "BookSourceManagementScaleTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let checker = BookSourceHealthChecker(fetcher: FatalTransportFetcher(), store: fixture.store)
        let model = BookSourceManagementModel(
            store: fixture.store,
            healthChecker: checker,
            expansion: BookSourceGroupExpansionStore(defaults: UserDefaults(suiteName: suite) ?? .standard)
        )

        let firstKeystroke = measureMs { model.searchText = "小" }
        let secondKeystroke = measureMs { model.searchText = "小说" }
        let clearSearch = measureMs { model.searchText = "" }
        let selectAll = measureMs { model.toggleSelectAll() }
        let invert = measureMs { model.invertSelection() }
        let switchPage = measureMs { model.filter = .fetchError }
        let switchBack = measureMs { model.filter = .all }

        // A switch in a row: the store write, then the model's rebuild on the next turn.
        let toggleStartedAt = ProcessInfo.processInfo.systemUptime
        fixture.store.toggle(id: fixture.store.sources[count / 2].id)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        let toggle = Int((ProcessInfo.processInfo.systemUptime - toggleStartedAt) * 1000)
        #expect(model.counts.total == count)

        print(
            "SCALE interactions sources=\(count) searchFirstKeyMs=\(firstKeystroke) "
                + "searchSecondKeyMs=\(secondKeystroke) clearSearchMs=\(clearSearch) "
                + "selectAllMs=\(selectAll) invertMs=\(invert) switchPageMs=\(switchPage) "
                + "switchBackMs=\(switchBack) toggleSourceMs=\(toggle)"
        )
    }

    // MARK: - Store

    @Test(
        "bulk store writes scale with the library",
        .enabled(if: enabled, "Set BOOK_SOURCE_SCALE_TESTS=1"),
        .timeLimit(.minutes(60))
    )
    func bulkStoreWrites() throws {
        for count in [10_000, 20_000] {
            let fixture = try ScaleFixture(count: count)
            defer { fixture.remove() }
            let store = fixture.store
            let ids = store.sources.map(\.id)

            var times: [UUID: Int64] = [:]
            for (offset, id) in ids.enumerated() { times[id] = Int64(1_000 + offset) }
            let respond = measureMs { store.setRespondTimes(times) }
            store.waitForQueuedWrites()

            let disable = measureMs { store.setEnabledByUser(ids: Set(ids), enabled: false) }
            store.waitForQueuedWrites()

            print("SCALE store sources=\(count) setRespondTimesMs=\(respond) setEnabledByUserMs=\(disable)")
        }
    }

    @Test(
        "saving and loading a large library",
        .enabled(if: enabled, "Set BOOK_SOURCE_SCALE_TESTS=1"),
        .timeLimit(.minutes(60))
    )
    func saveAndLoad() throws {
        let count = Self.counts.max() ?? 50_000
        let fixture = try ScaleFixture(count: count)
        defer { fixture.remove() }

        let sampler = FootprintSampler()
        let before = MemoryFootprint.current()
        sampler.start()
        let saveMs = measureMs {
            // Five edits in a row, the way toggling switches or a finished validation
            // run (respond times, 停用, 刪除) arrive.
            for index in 0..<5 {
                fixture.store.toggle(id: fixture.store.sources[index].id)
            }
            fixture.store.waitForQueuedWrites()
        }
        let peak = sampler.stop()
        let bytes = (try? FileManager.default.attributesOfItem(
            atPath: fixture.directory.appendingPathComponent("book_sources.json").path
        )[.size] as? Int) ?? -1

        let loadMs = measureMs { _ = BookSourceStore(directory: fixture.directory) }
        print(
            "SCALE persistence sources=\(count) fileMB=\(mb(Int64(bytes))) fiveEditsSaveMs=\(saveMs) "
                + "savePeakDeltaMB=\(mb(peak - before)) loadMs=\(loadMs)"
        )
    }

    // MARK: - 書源驗證

    @Test(
        "validating a large library with the result sheet on screen",
        .enabled(if: enabled, "Set BOOK_SOURCE_SCALE_TESTS=1"),
        .timeLimit(.minutes(60))
    )
    func validateLargeLibrary() async throws {
        let count = Self.counts.max() ?? 50_000
        let fixture = try ScaleFixture(count: count)
        defer { fixture.remove() }

        let checker = BookSourceHealthChecker(fetcher: FatalTransportFetcher(), store: fixture.store)
        checker.prepare(sources: fixture.store.sources)
        let host = try WindowHost(BookSourceCheckView(checker: checker))
        let sampler = FootprintSampler()
        let before = MemoryFootprint.current()
        sampler.start()
        let startedAt = ProcessInfo.processInfo.systemUptime
        await checker.runAll()
        let runMs = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
        host.pump(seconds: 0.5)
        let peak = sampler.stop()
        host.tearDown()
        #expect(checker.finishedCount == count)
        print(
            "SCALE validate sources=\(count) runMs=\(runMs) peakDeltaMB=\(mb(peak - before)) "
                + "mainThreadStallMaxMs=\(sampler.maxMainThreadStallMs)"
        )
    }

    @Test(
        "validating a large library whose sources all pass",
        .enabled(if: enabled, "Set BOOK_SOURCE_SCALE_TESTS=1"),
        .timeLimit(.minutes(60))
    )
    func validatePassingLibrary() async throws {
        let count = Self.counts.max() ?? 50_000
        let fixture = try ScaleFixture(count: count)
        defer { fixture.remove() }

        let checker = BookSourceHealthChecker(fetcher: PassingSourceFetcher(), store: fixture.store)
        checker.policy.checkDiscovery = false
        checker.prepare(sources: fixture.store.sources)
        let host = try WindowHost(BookSourceCheckView(checker: checker))
        let sampler = FootprintSampler()
        let before = MemoryFootprint.current()
        sampler.start()
        let startedAt = ProcessInfo.processInfo.systemUptime
        await checker.runAll()
        let runMs = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
        host.pump(seconds: 0.5)
        let settled = MemoryFootprint.current()
        let peak = sampler.stop()
        host.tearDown()
        print(
            "SCALE validatePassing sources=\(count) passed=\(checker.passedCount) runMs=\(runMs) "
                + "settledDeltaMB=\(mb(settled - before)) peakDeltaMB=\(mb(peak - before)) "
                + "mainThreadStallMaxMs=\(sampler.maxMainThreadStallMs)"
        )
    }

    // MARK: - Launch and the bookshelf

    @Test(
        "opening a large library at launch, and the main thread's share of it",
        .enabled(if: enabled, "Set BOOK_SOURCE_SCALE_TESTS=1"),
        .timeLimit(.minutes(30))
    )
    func openLibraryAtLaunch() async throws {
        for count in Self.counts {
            let fixture = try ScaleFixture(count: count)
            defer { fixture.remove() }
            let startedAt = ProcessInfo.processInfo.systemUptime
            let reopened = BookSourceStore(directory: fixture.directory)
            let initMs = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
            await reopened.waitUntilLoaded()
            let loadedMs = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
            #expect(reopened.sources.count == count)
            print("SCALE launchLoad sources=\(count) mainThreadInitMs=\(initMs) loadedMs=\(loadedMs)")
        }
    }

    @Test(
        "building bookshelf covers with a large library",
        .enabled(if: enabled, "Set BOOK_SOURCE_SCALE_TESTS=1"),
        .timeLimit(.minutes(30))
    )
    func buildShelfCovers() async throws {
        let count = Self.counts.max() ?? 50_000
        let fixture = try ScaleFixture(count: count)
        defer { fixture.remove() }
        let previous = BookSourceStore.shared.sources
        BookSourceStore.shared.sources = fixture.store.sources
        defer { BookSourceStore.shared.sources = previous }
        // Books whose sources sit at the end of the list: the worst case of a linear scan.
        let books: [ReadingBook] = fixture.store.sources.suffix(200).map { source in
            var book = ReadingBook(title: "書", author: "作者", contentFilename: "")
            book.bookSourceId = source.id
            book.coverUrl = "https://example.com/cover.jpg"
            return book
        }
        let ms = measureMs {
            for book in books { _ = BookCoverImage(readingBook: book) }
        }
        print("SCALE shelfCovers sources=\(count) covers=\(books.count) initMs=\(ms)")
    }

    // MARK: - Helpers

    private func measureMs(_ body: () -> Void) -> Int {
        let startedAt = ProcessInfo.processInfo.systemUptime
        body()
        return Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
    }

    private func mb(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1_000_000)
    }
}

// MARK: - Fixture

/// A library of `count` sources on its own temporary store.
@MainActor
struct ScaleFixture {
    let directory: URL
    let store: BookSourceStore
    let bookStore: BookStore

    init(count: Int) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookSourceScale-\(UUID().uuidString)", isDirectory: true)
        store = BookSourceStore(directory: directory)
        store.replaceSourcesFromSync(try Self.sources(count: count))
        // The replace queued a full write; let it land so it doesn't compete with what
        // the probe measures.
        store.waitForQueuedWrites()
        bookStore = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))
    }

    func remove() {
        store.waitForQueuedWrites()
        try? FileManager.default.removeItem(at: directory)
    }

    private static var corpusCache: [BookSource]?

    static func sources(count: Int) throws -> [BookSource] {
        let base = try corpus()
        var result: [BookSource] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            var source = base[index % base.count]
            let copy = index / base.count
            source.id = UUID()
            if copy > 0 {
                source.bookSourceUrl += "#stress-\(copy)"
                source.bookSourceName += " · \(copy)"
            }
            result.append(source)
        }
        return result
    }

    private static func corpus() throws -> [BookSource] {
        if let corpusCache { return corpusCache }
        let key = "BOOK_SOURCE_SCALE_CORPUS"
        let env = ProcessInfo.processInfo.environment
        let decoded: [BookSource]
        if let path = env[key] ?? env["TEST_RUNNER_" + key] {
            decoded = BookSourceStore.dedupedByURL(
                try JSONDecoder().decode([BookSource].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            )
        } else {
            decoded = (0..<4_765).map(synthesized)
        }
        corpusCache = decoded
        return decoded
    }

    /// Field sizes follow the real corpus: most sources carry a search URL and a few rule
    /// fields; a minority carry multi-kilobyte JS in `exploreUrl` / `jsLib`.
    private static func synthesized(_ index: Int) -> BookSource {
        var source = BookSource(
            bookSourceUrl: "https://source-\(index).example.com",
            bookSourceName: "書源 \(index)"
        )
        source.bookSourceGroup = index % 3 == 0 ? "" : "分組 \(index % 88)"
        source.searchUrl = "/search?keyword={{key}}&page={{page}}," + String(repeating: "q", count: 160)
        source.enabledExplore = index % 5 != 0
        source.exploreUrl = index % 5 < 2
            ? "@js:\n" + String(repeating: "var a = java.ajax(baseUrl);\n", count: 90)
            : "分類::/list/{{page}}"
        source.jsLib = index % 10 == 0 ? String(repeating: "function f(){return 1};\n", count: 80) : ""
        source.ruleSearch.bookList = ".result-list li"
        source.ruleSearch.name = "h3@text"
        source.ruleSearch.author = ".author@text"
        source.ruleSearch.bookUrl = "a@href"
        source.ruleBookInfo.intro = ".intro@html"
        source.ruleToc.chapterList = "#list dd"
        source.ruleToc.chapterName = "a@text"
        source.ruleToc.chapterUrl = "a@href"
        source.ruleContent.content = "#content@html##<script.*?</script>"
        return source
    }
}

// MARK: - Window host

/// Renders a SwiftUI screen in a real window of the test host's scene.
@MainActor
final class WindowHost {
    let window: UIWindow
    let controller: UIViewController

    init<Content: View>(_ content: Content) throws {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first
        else { throw WindowHostError.noScene }
        window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        controller = UIHostingController(rootView: content)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
    }

    /// Lets SwiftUI and UIKit run their deferred passes (CA commits, lazy cells).
    func pump(seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
        controller.view.layoutIfNeeded()
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
    }

    enum WindowHostError: Error { case noScene }
}

// MARK: - Samplers

/// Peak `phys_footprint` while a probe runs, plus the longest the main thread went
/// without servicing a ping — how long the UI would have been frozen.
final class FootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Int64 = 0
    private var maxStall: TimeInterval = 0
    private var lastMainPing: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var timer: DispatchSourceTimer?

    var maxMainThreadStallMs: Int {
        lock.lock(); defer { lock.unlock() }
        return Int(maxStall * 1000)
    }

    func start() {
        lock.lock()
        peak = MemoryFootprint.current()
        lastMainPing = ProcessInfo.processInfo.systemUptime
        lock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let footprint = MemoryFootprint.current()
            self.lock.lock()
            self.peak = max(self.peak, footprint)
            self.maxStall = max(self.maxStall, now - self.lastMainPing)
            self.lock.unlock()
            DispatchQueue.main.async {
                self.lock.lock()
                self.lastMainPing = ProcessInfo.processInfo.systemUptime
                self.lock.unlock()
            }
        }
        self.timer = timer
        timer.resume()
    }

    @discardableResult
    func stop() -> Int64 {
        timer?.cancel()
        timer = nil
        lock.lock(); defer { lock.unlock() }
        return max(peak, MemoryFootprint.current())
    }
}

// MARK: - Fetchers

/// Every probe fails at the transport, so a source costs one call and the run
/// exercises bookkeeping and UI rather than the network.
actor FatalTransportFetcher: BookSourceHealthCheckFetching {
    func search(
        query: String,
        in source: BookSource,
        page: Int,
        earlyFilter: ((_ name: String, _ author: String) -> Bool)?,
        onHasMore: ((Bool?) -> Void)?,
        failureMode: BookSourceSearchFailureMode
    ) async throws -> [OnlineBook] {
        throw URLError(.timedOut)
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
    ) async throws -> OnlineBook { throw URLError(.timedOut) }

    func fetchTOC(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) async throws -> [OnlineChapterRef] { throw URLError(.timedOut) }

    func fetchChapter(
        ref: OnlineChapterRef,
        bookId: UUID,
        source: BookSource,
        chapterReferer: String?
    ) async throws -> String { throw URLError(.timedOut) }
}


/// Every stage passes with metadata the size real sites return — a few hundred characters of
/// synopsis, a real chapter — so a run keeps what a real one keeps per source.
actor PassingSourceFetcher: BookSourceHealthCheckFetching {
    private static let intro = String(repeating: "這是一段書籍簡介，描述主角的成長與冒險。", count: 15)
    private static let chapter = String(repeating: "他推開門，看見窗外的雨一直下著，街燈把水窪照得發亮。\n", count: 60)

    func search(
        query: String,
        in source: BookSource,
        page: Int,
        earlyFilter: ((_ name: String, _ author: String) -> Bool)?,
        onHasMore: ((Bool?) -> Void)?,
        failureMode: BookSourceSearchFailureMode
    ) async throws -> [OnlineBook] {
        [book(url: source.bookSourceUrl + "/book/\(query)", toc: "", source: source)]
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
        book(url: url, toc: url + "/toc", source: source)
    }

    func fetchTOC(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) async throws -> [OnlineChapterRef] {
        (0..<20).map { OnlineChapterRef(index: $0, title: "第\($0 + 1)章", url: tocUrl + "/\($0)") }
    }

    func fetchChapter(
        ref: OnlineChapterRef,
        bookId: UUID,
        source: BookSource,
        chapterReferer: String?
    ) async throws -> String { Self.chapter }

    private func book(url: String, toc: String, source: BookSource) -> OnlineBook {
        OnlineBook(
            // Unique per book, like a real synopsis — a shared literal would cost nothing to keep.
            name: "驗證用書 \(source.bookSourceName)", author: "作者名",
            intro: source.bookSourceName + Self.intro,
            coverUrl: source.bookSourceUrl + "/cover/12345.jpg", bookUrl: url, tocUrl: toc,
            wordCount: "123.4萬字", lastChapter: "第一千兩百章 大結局", kind: "玄幻,連載",
            sourceId: source.id, sourceName: source.bookSourceName)
    }
}
