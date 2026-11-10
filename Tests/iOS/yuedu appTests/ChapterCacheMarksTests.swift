import Foundation
import Testing
@testable import yuedu_app

/// 目錄's marks on the chapters that are not cached yet (回饋 #88).
@Suite("Chapter cache marks", .serialized)
struct ChapterCacheMarksTests {

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-marks-\(UUID().uuidString)", isDirectory: true)
    }

    private func refs(_ count: Int) -> [OnlineChapterRef] {
        (0..<count).map { OnlineChapterRef(index: $0, title: "第\($0 + 1)章", url: "https://toc.example/\($0)") }
    }

    private func cache(_ ref: OnlineChapterRef, at index: Int, bookId: UUID, in repository: ChapterCacheRepository) throws {
        try repository.saveToCache(
            content: "正文 \(index)", bookId: bookId, chapterIndex: index, sourceURL: ref.url, tocTitle: ref.title
        )
    }

    @Test("only a body that still belongs to its chapter counts as cached")
    func listingChecksEachBody() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ChapterCacheRepository(rootDirectory: root)
        let bookId = UUID()
        var list = refs(4)
        try cache(list[0], at: 0, bookId: bookId, in: repository)
        try cache(list[2], at: 2, bookId: bookId, in: repository)
        // A refresh put another chapter at 3; the old one's file stays there (`.preserveContent`).
        try cache(list[3], at: 3, bookId: bookId, in: repository)
        list[3] = OnlineChapterRef(index: 3, title: "第四章 新", url: "https://toc.example/3-new")
        // Past the end of the list the refresh left.
        try cache(OnlineChapterRef(index: 7, title: "第八章", url: "https://toc.example/7"),
                  at: 7, bookId: bookId, in: repository)

        #expect(repository.cachedChapterIndices(bookId: bookId, refs: list) == [0, 2])
    }

    @Test("a chapter cached under its unsanitized URL counts, as the reader reads it")
    func unsanitizedURL() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ChapterCacheRepository(rootDirectory: root)
        let bookId = UUID()
        let ref = OnlineChapterRef(index: 0, title: "第一章", url: " https://toc.example/0 ")
        try cache(ref, at: 0, bookId: bookId, in: repository)

        #expect(repository.cachedChapterIndices(bookId: bookId, refs: [ref]) == [0])
    }

    @Test("a book with nothing cached has no cached chapters")
    func nothingCached() {
        let repository = ChapterCacheRepository(rootDirectory: temporaryRoot())
        #expect(repository.cachedChapterIndices(bookId: UUID(), refs: refs(3)).isEmpty)
    }

    @Test("a volume heading is never marked; a cached chapter is not either")
    @MainActor
    func volumesAndCachedChaptersUnmarked() async throws {
        var book = ReadingBook(title: "Book", author: "Author", source: "https://toc.example", contentFilename: "")
        book.isOnline = true
        let list = [
            OnlineChapterRef(index: 0, title: "第一卷", url: "", isVolume: true),
            OnlineChapterRef(index: 1, title: "第一章", url: "https://toc.example/1"),
            OnlineChapterRef(index: 2, title: "第二章", url: "https://toc.example/2"),
        ]
        book.onlineChapters = list
        defer { BookSourceFetcher.shared.clearAllChapterCache(bookId: book.id) }
        try BookSourceFetcher.shared.saveToCache(
            content: "正文", bookId: book.id, chapterIndex: 1, sourceURL: list[1].url, tocTitle: list[1].title
        )
        let manager = ChapterFetchManager()

        #expect(manager.uncachedChapterIndexes(book: book) == [2])
        let fetcher = LiveChapterFetcher(chapterFetchManager: manager)
        #expect(await fetcher.uncachedChapterIndexes(book: book) == [2])
    }

    /// Not a budget, a number for the record: what opening 目錄 on a long book costs.
    @Test("a long book's marks come from one listing")
    func longBookTiming() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ChapterCacheRepository(rootDirectory: root)
        let list = refs(3000)
        let emptyBook = UUID()
        let cachedBook = UUID()
        for index in 0..<2000 {
            try cache(list[index], at: index, bookId: cachedBook, in: repository)
        }
        let clock = ContinuousClock()
        var none: Set<Int> = []
        var many: Set<Int> = []
        let noneTime = clock.measure { none = repository.cachedChapterIndices(bookId: emptyBook, refs: list) }
        let manyTime = clock.measure { many = repository.cachedChapterIndices(bookId: cachedBook, refs: list) }
        print("⏱ toc.cacheMarks 3000 chapters: none cached \(noneTime), 2000 cached \(manyTime)")
        #expect(none.isEmpty)
        #expect(many == Set(0..<2000))
    }
}
