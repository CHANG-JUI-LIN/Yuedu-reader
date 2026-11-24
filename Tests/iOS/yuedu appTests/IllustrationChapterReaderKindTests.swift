import Foundation
import Testing
@testable import yuedu_app

/// Feedback #251: a light novel's 插圖 chapter — nothing but pictures — turned the whole book
/// into a comic, and it stayed one. The image reader is chosen from several chapters, and a
/// text-declared book in it goes back to the text reader on its first prose chapter.
@Suite("Illustration chapters keep a novel in the text reader", .serialized)
@MainActor
struct IllustrationChapterReaderKindTests {
    private static let prose = "利姆露望著洞窟深處，心裡盤算著接下來要怎麼辦。哥布林們圍在身旁，等著他開口。"

    private static func illustrations(_ chapter: Int, count: Int = 19) -> String {
        (1...count).map { #"<img src="https://pic.wenku8.test/\#(chapter)/\#($0).jpg">"# }.joined(separator: "\n")
    }

    @Test("an illustration chapter between prose chapters leaves a novel in the text reader")
    func illustrationChapterStaysText() async throws {
        try await withStore { store, positions in
            let book = store.addOnlineBook(name: "關於我轉生變成史萊姆這檔事", author: "", sourceId: UUID(),
                                           bookInfoURL: "https://wenku8.test/1", contentKind: .text,
                                           chapters: Self.chapters(330))
            // The 插圖 chapter the reader opened, then its neighbours as they come back.
            for (chapter, content) in [(40, Self.illustrations(40)), (41, Self.illustrations(41)),
                                       (39, Self.prose), (42, Self.illustrations(42))] {
                #expect(await store.noteChapterContent(bookId: book.id, content: content, chapterIndex: chapter,
                                                       positionStore: positions) == .unchanged)
            }
            #expect(store.readingBook(id: book.id)?.resolvedPipelineKind == .html)
        }
    }

    @Test("two illustration chapters side by side do not make a novel a comic")
    func twoIllustrationChaptersStayText() async throws {
        try await withStore { store, positions in
            let book = store.addOnlineBook(name: "輕小說", author: "", sourceId: UUID(),
                                           bookInfoURL: "https://wenku8.test/2", contentKind: .text,
                                           chapters: Self.chapters(30))
            for chapter in [10, 11] {
                #expect(await store.noteChapterContent(bookId: book.id, content: Self.illustrations(chapter),
                                                       chapterIndex: chapter, positionStore: positions) == .unchanged)
            }
            #expect(store.readingBook(id: book.id)?.resolvedPipelineKind == .html)
        }
    }

    @Test("a comic under a text source with fewer chapters than the threshold needs all of them")
    func shortComicNeedsEveryChapter() async throws {
        try await withStore { store, positions in
            let book = store.addOnlineBook(name: "短篇漫畫", author: "", sourceId: UUID(),
                                           bookInfoURL: "https://aggregate.test/short", contentKind: .text,
                                           chapters: Self.chapters(2))
            #expect(await store.noteChapterContent(bookId: book.id, content: Self.illustrations(0),
                                                   chapterIndex: 0, positionStore: positions) == .unchanged)
            #expect(await store.noteChapterContent(bookId: book.id, content: Self.illustrations(1),
                                                   chapterIndex: 1, positionStore: positions) == .movedToImageReader)
        }
    }

    /// A book moved to the image reader by the single-chapter rule (3.0.2 and before) is stored
    /// as a comic though its source declares text; its first prose chapter brings it back, at
    /// the chapter the image reader had open.
    @Test("a text-declared book in the image reader goes back to text on a prose chapter")
    func wronglyMovedBookComesBack() async throws {
        try await withSources([Self.source(type: 0)]) { sources in
            try await withStore { store, positions in
                let book = store.addOnlineBook(name: "關於我轉生變成史萊姆這檔事", author: "", sourceId: sources[0].id,
                                               bookInfoURL: "https://wenku8.test/3", contentKind: .manga,
                                               chapters: Self.chapters(330))
                store.updateMangaPosition(bookId: book.id, chapter: 40, page: 5, totalChapters: 330, forceSave: true)

                #expect(await store.noteChapterContent(bookId: book.id, content: Self.illustrations(40),
                                                       chapterIndex: 40, positionStore: positions) == .unchanged)
                #expect(store.readingBook(id: book.id)?.resolvedPipelineKind == .manga)

                #expect(await store.noteChapterContent(bookId: book.id, content: Self.prose, chapterIndex: 41,
                                                       readingChapter: 40, positionStore: positions) == .movedToTextReader)
                #expect(store.readingBook(id: book.id)?.resolvedPipelineKind == .html)
                #expect(positions.loadSync(for: book.id.uuidString)?.spineIndex == 40)
            }
        }
    }

    @Test("a book its source declares a comic stays in the image reader on a prose chapter")
    func declaredComicStays() async throws {
        try await withSources([Self.source(type: 2)]) { sources in
            try await withStore { store, positions in
                let book = store.addOnlineBook(name: "漫畫", author: "", sourceId: sources[0].id,
                                               bookInfoURL: "https://comic.test/9", chapters: Self.chapters(20))
                #expect(book.contentPipelineKind == .manga)
                #expect(await store.noteChapterContent(bookId: book.id, content: Self.prose, chapterIndex: 3,
                                                       positionStore: positions) == .unchanged)
                #expect(store.readingBook(id: book.id)?.resolvedPipelineKind == .manga)
            }
        }
    }

    // MARK: - Helpers

    private static func source(type: Int) -> BookSource {
        var source = BookSource(bookSourceUrl: "https://source.test/\(type)", bookSourceName: "來源\(type)")
        source.bookSourceType = type
        return source
    }

    private static func chapters(_ count: Int) -> [OnlineChapterRef] {
        (0..<count).map { OnlineChapterRef(index: $0, title: "第\($0)章", url: "https://c.test/\($0)") }
    }

    private func withSources(_ sources: [BookSource], _ body: ([BookSource]) async throws -> Void) async throws {
        let previous = BookSourceStore.shared.sources
        BookSourceStore.shared.replaceSources(sources)
        defer { BookSourceStore.shared.replaceSources(previous) }
        try await body(sources)
    }

    private func withStore(_ body: (BookStore, InMemoryReaderKindPositions) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IllustrationChapterReaderKindTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))
        try await body(store, InMemoryReaderKindPositions())
        store.flushPendingMetadataSave()
        store.waitForQueuedWrites()
    }
}

private final class InMemoryReaderKindPositions: ReadingPositionStore, @unchecked Sendable {
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
