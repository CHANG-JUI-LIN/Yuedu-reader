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
        #expect(await fixture.fetcher.requestedIndices == [0, 1, 2])
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

        #expect(await fixture.fetcher.requestedIndices == [0, 1, 2, 1])
        let task = try #require(fixture.store.books.first?.offlineDownloadTask)
        #expect(task.completedIndices == Set(0...2))
        #expect(task.failedChapters.isEmpty)
        #expect(fixture.store.books.first?.offlineDownloadState == .available)
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
            chapterStore: artifactStore
        )
        return ManagerFixture(
            directory: directory,
            book: book,
            store: store,
            fetcher: fetcher,
            manager: manager
        )
    }
}

private struct ManagerFixture {
    var directory: URL
    var book: ReadingBook
    var store: BookStore
    var fetcher: TestOfflineChapterFetcher
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

    init(ledger: TestArtifactLedger, failingIndices: Set<Int>) {
        self.ledger = ledger
        self.failingIndices = failingIndices
    }

    func setFailingIndices(_ indices: Set<Int>) {
        failingIndices = indices
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
            throw URLError(.notConnectedToInternet)
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

    init(ledger: TestArtifactLedger) {
        self.ledger = ledger
    }

    func validationState(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String?,
        expectedTOCTitle: String?,
        requiresManga: Bool
    ) async -> OfflineChapterValidation {
        await ledger.contains(chapterIndex) ? .complete : .incomplete
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
