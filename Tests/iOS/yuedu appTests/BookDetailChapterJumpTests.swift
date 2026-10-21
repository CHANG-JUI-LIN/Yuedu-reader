import Foundation
import Testing
@testable import yuedu_app

/// A chapter chosen in a detail page's 目錄 opens in that chapter, whatever the book's reader.
/// Feedback #34 (2026-10-20): every comic opened from 目錄 started at its first chapter,
/// because the choice went only into the position store, which the image reader never reads.
@Suite("Detail page opens the chosen chapter", .serialized)
@MainActor
struct BookDetailChapterJumpTests {
    @Test("a comic opens at the chosen chapter, from its first page")
    func comicOpensAtChosenChapter() async throws {
        try await withStore { store, positions in
            let book = store.addOnlineBook(name: "我獨自升級", author: "", sourceId: UUID(),
                                           bookInfoURL: "https://comic.test/1", contentKind: .manga,
                                           chapters: Self.chapters(12))
            store.updateMangaPosition(bookId: book.id, chapter: 2, page: 9, totalChapters: 12)

            let place = ReadingChapterPlace(store: store, positionStore: positions)
            await place.open(atChapter: 7, bookId: book.id)

            let opened = try #require(store.readingBook(id: book.id))
            #expect(opened.mangaChapterIndex == 7)
            #expect(opened.mangaPage == 0)
            #expect(await place.resumeChapterIndex(of: book.id) == 7)
            #expect(positions.loadSync(for: book.id.uuidString) == nil)
        }
    }

    @Test("an audiobook plays the chosen chapter from its start")
    func audiobookOpensAtChosenChapter() async throws {
        try await withStore { store, positions in
            let book = store.addOnlineBook(name: "大圣归来", author: "", sourceId: UUID(),
                                           bookInfoURL: "https://audio.test/1", contentKind: .audio,
                                           chapters: Self.chapters(12))
            store.updateAudioPosition(bookId: book.id, chapter: 1, time: 300, totalChapters: 12)

            await ReadingChapterPlace(store: store, positionStore: positions).open(atChapter: 5, bookId: book.id)

            let opened = try #require(store.readingBook(id: book.id))
            #expect(opened.audioChapterIndex == 5)
            #expect(opened.audioTimeSeconds == 0)
        }
    }

    @Test("a text book still opens at the chosen chapter through the position store")
    func textBookOpensAtChosenChapter() async throws {
        try await withStore { store, positions in
            let book = store.addOnlineBook(name: "三體", author: "", sourceId: UUID(),
                                           bookInfoURL: "https://text.test/1", contentKind: .text,
                                           chapters: Self.chapters(12))

            let place = ReadingChapterPlace(store: store, positionStore: positions)
            await place.open(atChapter: 7, bookId: book.id)

            #expect(positions.loadSync(for: book.id.uuidString) == CoreTextReadingPosition(spineIndex: 7, charOffset: 0))
            #expect(await place.resumeChapterIndex(of: book.id) == 7)
        }
    }

    @Test("a comic not read yet shows no resume chapter")
    func unreadComicHasNoResumeChapter() async throws {
        try await withStore { store, positions in
            let book = store.addOnlineBook(name: "未讀", author: "", sourceId: UUID(),
                                           bookInfoURL: "https://comic.test/2", contentKind: .manga,
                                           chapters: Self.chapters(3))
            #expect(await ReadingChapterPlace(store: store, positionStore: positions)
                .resumeChapterIndex(of: book.id) == nil)
        }
    }

    /// A comic from a source typed as text opens in the text reader at the chosen chapter and
    /// flips to the image reader once that chapter comes back as images; it stays there.
    @Test("a comic detected from its content keeps the chapter it was opened at")
    func detectedComicKeepsOpenedChapter() async throws {
        try await withStore { store, _ in
            let book = store.addOnlineBook(name: "聚合漫畫", author: "", sourceId: UUID(),
                                           bookInfoURL: "https://aggregate.test/1", contentKind: .text,
                                           chapters: Self.chapters(12))
            let pages = (1...4).map { "https://img.test/7/\($0).jpg" }.joined(separator: "\n")

            #expect(store.upgradeToMangaIfDetected(bookId: book.id, content: pages, atChapter: 7))

            let flipped = try #require(store.readingBook(id: book.id))
            #expect(flipped.resolvedPipelineKind == .manga)
            #expect(flipped.mangaChapterIndex == 7)
            #expect(flipped.mangaPage == 0)
        }
    }

    // MARK: - Helpers

    private static func chapters(_ count: Int) -> [OnlineChapterRef] {
        (0..<count).map { OnlineChapterRef(index: $0, title: "第\($0)話", url: "https://c.test/\($0)") }
    }

    private func withStore(_ body: (BookStore, InMemoryChapterJumpPositions) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookDetailChapterJumpTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))
        try await body(store, InMemoryChapterJumpPositions())
        store.flushPendingMetadataSave()
        store.waitForQueuedWrites()
    }
}

private final class InMemoryChapterJumpPositions: ReadingPositionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: CoreTextReadingPosition] = [:]

    func save(_ position: CoreTextReadingPosition, for bookId: String) async {
        lock.withLock { storage[bookId] = position }
    }

    func load(for bookId: String) async -> CoreTextReadingPosition? {
        loadSync(for: bookId)
    }

    func loadSync(for bookId: String) -> CoreTextReadingPosition? {
        lock.withLock { storage[bookId] }
    }

    func flush(for bookId: String) async {}
}
