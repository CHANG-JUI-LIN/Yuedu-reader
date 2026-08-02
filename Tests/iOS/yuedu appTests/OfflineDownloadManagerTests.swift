import Foundation
import Testing
@testable import yuedu_app

@Suite("Offline download manager", .serialized)
struct OfflineDownloadManagerTests {
    @Test("one failure does not block the next chapter")
    @MainActor
    func failureContinues() async throws {
        let fixture = makeFixture(chapters: 3, failingIndices: [1])
        defer { fixture.cleanup() }

        await fixture.manager.start(
            book: fixture.book,
            selection: .range(0...2),
            store: fixture.store
        )
        await fixture.manager.waitUntilIdle()

        let task = try #require(fixture.store.books.first?.offlineDownloadTask)
        #expect(task.completedIndices == Set([0, 2]))
        #expect(Set(task.failedChapters.keys) == Set([1]))
        #expect(fixture.store.books.first?.offlineDownloadState == .partial)
        // Chapter 1 is tried three times before being recorded as failed, and the download
        // still moves on to chapter 2 afterwards.
        #expect(await fixture.fetcher.requestedIndices == [0, 1, 1, 1, 2])
    }

    @Test("a chapter that fails once is retried and succeeds")
    @MainActor
    func transientFailureRecoversWithoutUserAction() async throws {
        let fixture = makeFixture(chapters: 2, failingIndices: [0])
        defer { fixture.cleanup() }
        // Fails the first attempt, then behaves — the single blip a paid/login-gated source
        // or a chapter that also fetches 段評 is most likely to hit.
        await fixture.fetcher.setRemainingFailures(1)

        await fixture.manager.start(
            book: fixture.book,
            selection: .range(0...1),
            store: fixture.store
        )
        await fixture.manager.waitUntilIdle()

        let task = try #require(fixture.store.books.first?.offlineDownloadTask)
        #expect(task.completedIndices == Set([0, 1]))
        #expect(task.failedChapters.isEmpty)
        #expect(fixture.store.books.first?.offlineDownloadState == .available)
        #expect(await fixture.fetcher.requestedIndices == [0, 0, 1])
    }

    @Test("a deterministic failure is not retried")
    @MainActor
    func deterministicFailureIsNotRetried() async throws {
        let fixture = makeFixture(chapters: 2, failingIndices: [0])
        defer { fixture.cleanup() }
        // `.invalidChapter`: the same input fails identically every time, so spending two
        // more requests on a source that may be throttling us buys nothing.
        await fixture.fetcher.setFailureError(FetchError.invalidURL("https://example.com/1"))

        await fixture.manager.start(
            book: fixture.book,
            selection: .range(0...1),
            store: fixture.store
        )
        await fixture.manager.waitUntilIdle()

        let task = try #require(fixture.store.books.first?.offlineDownloadTask)
        #expect(Set(task.failedChapters.keys) == Set([0]))
        #expect(task.failedChapters[0]?.category == .invalidChapter)
        #expect(await fixture.fetcher.requestedIndices == [0, 1])
    }

    @Test("an explicit retry gets a fresh set of attempts")
    @MainActor
    func manualRetryResetsAutomaticAttempts() async throws {
        let fixture = makeFixture(chapters: 1, failingIndices: [0])
        defer { fixture.cleanup() }

        await fixture.manager.start(
            book: fixture.book,
            selection: .range(0...0),
            store: fixture.store
        )
        await fixture.manager.waitUntilIdle()
        #expect(await fixture.fetcher.requestedIndices == [0, 0, 0])

        // The user may have logged in or bought the chapter in between, so the attempts
        // already spent must not carry over — otherwise the retry button would fire a
        // single request and give up.
        await fixture.fetcher.setFailingIndices([])
        let failedBook = try #require(fixture.store.books.first)
        await fixture.manager.retryFailed(book: failedBook, store: fixture.store)
        await fixture.manager.waitUntilIdle()

        let task = try #require(fixture.store.books.first?.offlineDownloadTask)
        #expect(task.completedIndices == Set([0]))
        #expect(task.failedChapters.isEmpty)
        #expect(await fixture.fetcher.requestedIndices == [0, 0, 0, 0])
    }

    @Test("volume separator is skipped without a fetch")
    @MainActor
    func volumeSkipped() async throws {
        let refs = [
            OnlineChapterRef(index: 0, title: "第一卷", url: "", isVolume: true),
            OnlineChapterRef(index: 1, title: "Chapter 1", url: "https://example.com/1"),
        ]
        let fixture = makeFixture(refs: refs)
        defer { fixture.cleanup() }

        await fixture.manager.start(
            book: fixture.book,
            selection: .range(0...1),
            store: fixture.store
        )
        await fixture.manager.waitUntilIdle()

        #expect(await fixture.fetcher.requestedIndices == [1])
        let task = try #require(fixture.store.books.first?.offlineDownloadTask)
        #expect(task.requestedIndices == Set([1]))
        #expect(task.completedIndices == Set([1]))
    }

    @Test("a later selection is additive")
    @MainActor
    func selectionIsAdditive() async throws {
        let fixture = makeFixture(chapters: 4)
        defer { fixture.cleanup() }

        await fixture.manager.start(
            book: fixture.book,
            selection: .range(0...1),
            store: fixture.store
        )
        await fixture.manager.waitUntilIdle()
        let updatedBook = try #require(fixture.store.books.first)
        await fixture.manager.start(
            book: updatedBook,
            selection: .range(2...3),
            store: fixture.store
        )
        await fixture.manager.waitUntilIdle()

        let task = try #require(fixture.store.books.first?.offlineDownloadTask)
        #expect(task.requestedIndices == Set(0...3))
        #expect(task.completedIndices == Set(0...3))
        #expect(fixture.store.books.first?.offlineDownloadState == .available)
    }

    @Test("retry fetches only failed chapters")
    @MainActor
    func retryOnlyFailed() async throws {
        let fixture = makeFixture(chapters: 3, failingIndices: [1])
        defer { fixture.cleanup() }

        await fixture.manager.start(
            book: fixture.book,
            selection: .range(0...2),
            store: fixture.store
        )
        await fixture.manager.waitUntilIdle()
        await fixture.fetcher.setFailingIndices([])
        let partialBook = try #require(fixture.store.books.first)
        await fixture.manager.retryFailed(book: partialBook, store: fixture.store)
        await fixture.manager.waitUntilIdle()

        // 1 exhausts its three automatic attempts, then the manual retry fetches it once more.
        #expect(await fixture.fetcher.requestedIndices == [0, 1, 1, 1, 2, 1])
        let task = try #require(fixture.store.books.first?.offlineDownloadTask)
        #expect(task.completedIndices == Set(0...2))
        #expect(task.failedChapters.isEmpty)
        #expect(fixture.store.books.first?.offlineDownloadState == .available)
    }

    @Test("skipping failed chapters finishes the download without fetching them again")
    @MainActor
    func skipFailedFinishesWithoutRefetching() async throws {
        let fixture = makeFixture(chapters: 4, failingIndices: [1, 3])
        defer { fixture.cleanup() }

        await fixture.manager.start(
            book: fixture.book,
            selection: .range(0...3),
            store: fixture.store
        )
        await fixture.manager.waitUntilIdle()
        #expect(fixture.store.books.first?.offlineDownloadState == .partial)

        await fixture.manager.skipFailed(bookId: fixture.book.id, store: fixture.store)

        let task = try #require(fixture.store.books.first?.offlineDownloadTask)
        #expect(task.requestedIndices == Set([0, 2]))
        #expect(task.completedIndices == Set([0, 2]))
        #expect(task.failedChapters.isEmpty)
        #expect(fixture.store.books.first?.offlineDownloadState == .available)
        // Both failing chapters spend their three attempts before being recorded.
        #expect(await fixture.fetcher.requestedIndices == [0, 1, 1, 1, 2, 3, 3, 3])
    }

    @Test("removing a download survives a reconcile pass that is mid-validation")
    @MainActor
    func removalBeatsConcurrentReconcile() async throws {
        let fixture = makeFixture(chapters: 2)
        defer { fixture.cleanup() }

        await fixture.manager.start(
            book: fixture.book,
            selection: .range(0...1),
            store: fixture.store
        )
        await fixture.manager.waitUntilIdle()
        #expect(fixture.store.books.first?.offlineDownloadState == .available)

        // Reconcile validates one chapter per await, and 下載管理 starts a pass on
        // the same screen as the 移除 button. Hold the pass inside its first
        // validation, remove the download, then let it finish: it must not write
        // its pre-removal snapshot back (which also re-queued the download).
        await fixture.artifactStore.holdValidations()
        let reconcile = Task { await fixture.manager.reconcileInterruptedDownloads(store: fixture.store) }
        await fixture.artifactStore.waitUntilValidating()
        try await fixture.manager.remove(bookId: fixture.book.id, store: fixture.store)
        await fixture.artifactStore.releaseValidations()
        await reconcile.value
        await fixture.manager.waitUntilIdle()

        #expect(fixture.store.books.first?.offlineDownloadTask == nil)
        #expect(fixture.store.books.first?.offlineDownloadState == BookOfflineDownloadState.none)
        #expect(await fixture.fetcher.requestedIndices == [0, 1])
    }

    @MainActor
    private func makeFixture(
        chapters: Int,
        failingIndices: Set<Int> = []
    ) -> ManagerFixture {
        makeFixture(
            refs: (0..<chapters).map {
                OnlineChapterRef(
                    index: $0,
                    title: "Chapter \($0 + 1)",
                    url: "https://example.com/\($0 + 1)"
                )
            },
            failingIndices: failingIndices
        )
    }

    @MainActor
    private func makeFixture(
        refs: [OnlineChapterRef],
        failingIndices: Set<Int> = []
    ) -> ManagerFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineDownloadManagerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))
        var book = ReadingBook(title: "Offline Book", author: "Author", contentFilename: "")
        book.isOnline = true
        book.contentPipelineKind = .html
        book.onlineChapters = refs
        store.replaceBooksFromSync([book])

        let ledger = TestArtifactLedger()
        let fetcher = TestOfflineChapterFetcher(ledger: ledger, failingIndices: failingIndices)
        let artifactStore = TestOfflineChapterStore(ledger: ledger)
        let manager = OfflineDownloadManager(
            chapterFetcher: fetcher,
            chapterStore: artifactStore,
            // Exercise the real retry path with no wall-clock wait.
            retryBackoff: 0
        )
        return ManagerFixture(
            directory: directory,
            book: book,
            store: store,
            fetcher: fetcher,
            artifactStore: artifactStore,
            manager: manager
        )
    }
}

private struct ManagerFixture {
    var directory: URL
    var book: ReadingBook
    var store: BookStore
    var fetcher: TestOfflineChapterFetcher
    var artifactStore: TestOfflineChapterStore
    var manager: OfflineDownloadManager

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor TestArtifactLedger {
    private var completed: Set<Int> = []

    func contains(_ index: Int) -> Bool { completed.contains(index) }
    func insert(_ index: Int) { completed.insert(index) }
    func removeAll() { completed.removeAll() }
}

private actor TestOfflineChapterFetcher: ChapterFetching {
    private let ledger: TestArtifactLedger
    private var failingIndices: Set<Int>
    private(set) var requestedIndices: [Int] = []
    /// When set, only this many attempts fail before the chapter starts succeeding — models
    /// a transient blip rather than a permanently broken chapter.
    private var remainingFailures: Int?
    /// Error thrown for a failing index; defaults to a transient network error.
    private var failureError: any Error = URLError(.notConnectedToInternet)

    init(ledger: TestArtifactLedger, failingIndices: Set<Int>) {
        self.ledger = ledger
        self.failingIndices = failingIndices
    }

    func setFailingIndices(_ indices: Set<Int>) {
        failingIndices = indices
    }

    func setRemainingFailures(_ count: Int) {
        remainingFailures = count
    }

    func setFailureError(_ error: any Error) {
        failureError = error
    }

    func isChapterCached(book: ReadingBook, chapterIndex: Int) async -> Bool {
        await ledger.contains(chapterIndex)
    }

    func fetchChapter(
        book: ReadingBook,
        chapterIndex: Int,
        priority: ChapterFetchPriority,
        store: BookStore?
    ) async throws -> ChapterPackage {
        requestedIndices.append(chapterIndex)
        if failingIndices.contains(chapterIndex) {
            if let remaining = remainingFailures {
                if remaining > 0 {
                    remainingFailures = remaining - 1
                    throw failureError
                }
            } else {
                throw failureError
            }
        }
        await ledger.insert(chapterIndex)
        let ref = book.onlineChapters![chapterIndex]
        return ChapterPackage(
            bookId: book.id,
            chapterIndex: chapterIndex,
            sourceURL: ref.url,
            tocTitle: ref.title,
            canonicalTitle: ref.title,
            content: "content \(chapterIndex)",
            contentChecksum: "checksum",
            rawHTMLFilename: nil,
            normalizedHTMLFilename: nil,
            savedAt: Date(),
            state: .cached,
            failureReason: nil
        )
    }

    func cancelChapter(bookId: UUID, chapterIndex: Int) async {}
    func cancelAll(for bookId: UUID) async {}
}

private actor TestOfflineChapterStore: OfflineChapterStoring {
    private let ledger: TestArtifactLedger
    private var holdsValidations = false
    private var didEnterValidation = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var heldValidations: [CheckedContinuation<Void, Never>] = []

    init(ledger: TestArtifactLedger) {
        self.ledger = ledger
    }

    /// Suspends every subsequent `validationState` call until `releaseValidations()`.
    func holdValidations() {
        holdsValidations = true
        didEnterValidation = false
    }

    /// Returns once a caller is parked inside `validationState`.
    func waitUntilValidating() async {
        guard !didEnterValidation else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func releaseValidations() {
        holdsValidations = false
        let parked = heldValidations
        heldValidations.removeAll()
        for continuation in parked { continuation.resume() }
    }

    func validationState(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String?,
        expectedTOCTitle: String?,
        requiresManga: Bool,
        hasBookSource: Bool
    ) async -> OfflineChapterValidation {
        if holdsValidations {
            if !didEnterValidation {
                didEnterValidation = true
                let waiters = entryWaiters
                entryWaiters.removeAll()
                for continuation in waiters { continuation.resume() }
            }
            await withCheckedContinuation { heldValidations.append($0) }
        }
        return await ledger.contains(chapterIndex) ? .complete : .incomplete
    }

    func persistMangaImages(_ request: OfflineMangaChapterRequest) async throws {
        await ledger.insert(request.chapterIndex)
    }

    func removeBook(bookId: UUID) async throws {
        await ledger.removeAll()
    }

    func reconcileBook(
        bookId: UUID,
        oldRefs: [OnlineChapterRef],
        newRefs: [OnlineChapterRef]
    ) async throws {}

    func storageByteCount(bookId: UUID?) async -> Int64 { 0 }
}
