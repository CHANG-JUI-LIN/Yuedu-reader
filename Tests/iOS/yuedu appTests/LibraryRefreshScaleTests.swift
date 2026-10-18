import Foundation
import Testing
@testable import yuedu_app

/// Scale probes for the launch-time library work: the table-of-contents refresh's CPU and the
/// offline-download reconcile's main-thread time, at the size of the shelves in the field
/// reports (hundreds of online books, 2 000-chapter tables of contents). Opt-in:
///
///     TEST_RUNNER_LIBRARY_REFRESH_SCALE_TESTS=1
///
/// Each probe prints one `SCALE …` line; the numbers are the evidence, not assertions.
@Suite(.serialized)
struct LibraryRefreshScaleTests {
    nonisolated private static let enabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        return (env["LIBRARY_REFRESH_SCALE_TESTS"] ?? env["TEST_RUNNER_LIBRARY_REFRESH_SCALE_TESTS"]) == "1"
    }()

    private static func chapters(_ count: Int) -> [OnlineChapterRef] {
        (0..<count).map {
            OnlineChapterRef(
                index: $0,
                title: "第\($0 + 1)章 風起雲湧 之 \($0 % 17)",
                url: "https://example.com/book/1/\($0 + 1).html"
            )
        }
    }

    @Test(
        "refreshing an unchanged 2000-chapter table of contents",
        .enabled(if: enabled, "Set LIBRARY_REFRESH_SCALE_TESTS=1"),
        .timeLimit(.minutes(10))
    )
    func refreshCPU() async throws {
        let source = BookSource(bookSourceUrl: "https://example.com", bookSourceName: "規模測試")
        let previousSources = await MainActor.run { BookSourceStore.shared.sources }
        await MainActor.run { BookSourceStore.shared.replaceSources([source]) }
        defer { Task { @MainActor in BookSourceStore.shared.replaceSources(previousSources) } }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryRefreshScale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = await MainActor.run { BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json")) }
        let book = await MainActor.run {
            store.addOnlineBook(
                name: "規模書", author: "作者", sourceId: source.id, bookInfoURL: "https://example.com/book",
                tocURL: "https://example.com/toc", runtimeVariables: nil, chapters: Self.chapters(2_000)
            )
        }
        let rounds = 5
        let startedAt = ProcessInfo.processInfo.systemUptime
        let cpuStart = Self.processCPUSeconds()
        for _ in 0..<rounds {
            _ = try await store.refreshOnlineBookMetadata(
                bookId: book.id,
                bookSourceFetcher: ScaleTOCFetcher(package: TOCPackage(
                    sourceId: source.id, sourceName: source.bookSourceName, tocURL: "https://example.com/toc",
                    runtimeVariables: nil, chapters: Self.chapters(2_000), rawHTMLFilename: nil, savedAt: Date()
                ))
            )
        }
        let wallMs = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000 / Double(rounds))
        let cpuMs = Int((Self.processCPUSeconds() - cpuStart) * 1000 / Double(rounds))
        await MainActor.run { store.waitForQueuedWrites() }
        print("SCALE refreshCPU chapters=2000 perRefreshWallMs=\(wallMs) perRefreshCPUMs=\(cpuMs)")
    }

    @Test(
        "reconciling 30 downloaded 2000-chapter books",
        .enabled(if: enabled, "Set LIBRARY_REFRESH_SCALE_TESTS=1"),
        .timeLimit(.minutes(10))
    )
    func reconcileMainThread() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryReconcileScale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let refs = Self.chapters(2_000)
        let books: [ReadingBook] = (0..<30).map { index in
            var book = ReadingBook(title: "下載書 \(index)", author: "作者", contentFilename: "")
            book.isOnline = true
            book.contentPipelineKind = .html
            book.onlineChapters = refs
            var task = BookOfflineDownloadTask(requestedIndices: Set(refs.indices))
            for chapter in refs.indices { task.markCompleted(chapter) }
            book.offlineDownloadTask = task
            book.offlineDownloadState = .available
            book.downloadedChapterCount = refs.count
            return book
        }
        let store = await MainActor.run { () -> BookStore in
            let store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))
            store.replaceBooksFromSync(books)
            store.waitForQueuedWrites()
            return store
        }
        // Reopened, as at launch: the lists are on disk and the in-memory cache holds none.
        let launched = await MainActor.run { BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json")) }
        let manager = OfflineDownloadManager(chapterFetcher: NeverFetcher(), chapterStore: AlwaysCompleteStore())
        let sampler = FootprintSampler()
        sampler.start()
        let startedAt = ProcessInfo.processInfo.systemUptime
        await manager.reconcileInterruptedDownloads(store: launched)
        let wallMs = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
        sampler.stop()
        _ = store
        print("SCALE reconcile books=30 chapters=2000 wallMs=\(wallMs) mainThreadStallMaxMs=\(sampler.maxMainThreadStallMs)")
    }

    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    }
}

private actor NeverFetcher: ChapterFetching {
    func isChapterCached(book: ReadingBook, chapterIndex: Int) async -> Bool { true }
    func fetchChapter(book: ReadingBook, chapterIndex: Int, priority: ChapterFetchPriority, store: BookStore?) async throws -> ChapterPackage {
        throw URLError(.notConnectedToInternet)
    }
    func cancelChapter(bookId: UUID, chapterIndex: Int) async {}
    func cancelAll(for bookId: UUID) async {}
}

/// Every chapter validates as complete, instantly: the probe measures the reconcile's own
/// bookkeeping, not disk reads of chapter files.
private struct AlwaysCompleteStore: OfflineChapterStoring {
    func validationState(bookId: UUID, chapterIndex: Int, expectedSourceURL: String?, expectedTOCTitle: String?,
                         requiresManga: Bool, hasBookSource: Bool) async -> OfflineChapterValidation { .complete }
    func persistMangaImages(_ request: OfflineMangaChapterRequest) async throws {}
    func persistTextImages(_ request: OfflineTextImageRequest) async -> Int { 0 }
    func removeBook(bookId: UUID) async throws {}
    func reconcileBook(bookId: UUID, oldRefs: [OnlineChapterRef], newRefs: [OnlineChapterRef],
                       disposition: OfflineContentDisposition) async throws {}
    func storageByteCount(bookId: UUID?) async -> Int64 { 0 }
}

/// Answers a table-of-contents refresh with a fixed package in one go.
private struct ScaleTOCFetcher: BookSourceFetching {
    let package: TOCPackage

    func fetchBookInfoPackage(
        url: String, source: BookSource, runtimeVariables: [String: String]?, knownBook: OnlineBook?
    ) async throws -> BookInfoPackage {
        throw NSError(domain: "ScaleTOCFetcher", code: 1)
    }

    func fetchTOCPackage(
        tocUrl: String, source: BookSource, runtimeVariables: [String: String]?,
        onFirstPageReady: (([OnlineChapterRef]) -> Void)?, forceRefresh: Bool
    ) async throws -> TOCPackage {
        package
    }

    func isChapterCached(
        bookId: UUID, chapterIndex: Int, expectedSourceURL: String?, expectedTOCTitle: String?
    ) -> Bool { false }
    func clearChapterCache(bookId: UUID, chapterIndex: Int) {}
    func clearAllChapterCache(bookId: UUID) {}
    func search(query: String, in source: BookSource) async throws -> [OnlineBook] { [] }
    func search(
        query: String, in source: BookSource, earlyFilter: ((String, String) -> Bool)?
    ) async throws -> [OnlineBook] { [] }
    func loadChapterPackageSync(
        bookId: UUID, chapterIndex: Int, expectedSourceURL: String?, expectedTOCTitle: String?
    ) -> ChapterPackage? { nil }
    func loadNormalizedChapterHTMLSync(
        bookId: UUID, chapterIndex: Int, expectedSourceURL: String?, expectedTOCTitle: String?
    ) -> String? { nil }
}
