import Foundation
import Testing
@testable import yuedu_app

/// Feedback #251: a light novel's 插圖 chapter — nothing but pictures — turned the whole book
/// into a comic, and it stayed one. The image reader now follows the source's declared type
/// alone, as in legado, and books moved there by a chapter's content go back.
@Suite("Illustration chapters keep a novel in the text reader", .serialized)
@MainActor
struct IllustrationChapterReaderKindTests {
    @Test("a text-declared book stored as a comic goes back to the text reader at its chapter")
    func wronglyMovedBookComesBack() async throws {
        try await withSources([Self.source(type: 0)]) { sources in
            try await withStore { store, positions in
                let book = store.addOnlineBook(name: "關於我轉生變成史萊姆這檔事", author: "", sourceId: sources[0].id,
                                               bookInfoURL: "https://wenku8.test/3", contentKind: .manga,
                                               chapters: Self.chapters(330))
                store.updateMangaPosition(bookId: book.id, chapter: 40, page: 5, totalChapters: 330, forceSave: true)

                #expect(await store.returnTextDeclaredComicsToTextReader(positionStore: positions) == 1)
                #expect(store.readingBook(id: book.id)?.resolvedPipelineKind == .html)
                #expect(positions.loadSync(for: book.id.uuidString)?.spineIndex == 40)
                #expect(await store.returnTextDeclaredComicsToTextReader(positionStore: positions) == 0,
                        "nothing is left to move")
            }
        }
    }

    @Test("a book its source declares a comic stays in the image reader")
    func declaredComicStays() async throws {
        try await withSources([Self.source(type: 2)]) { sources in
            try await withStore { store, positions in
                let book = store.addOnlineBook(name: "漫畫", author: "", sourceId: sources[0].id,
                                               bookInfoURL: "https://comic.test/9", chapters: Self.chapters(20))
                #expect(book.contentPipelineKind == .manga)
                #expect(await store.returnTextDeclaredComicsToTextReader(positionStore: positions) == 0)
                #expect(store.readingBook(id: book.id)?.resolvedPipelineKind == .manga)
                #expect(positions.loadSync(for: book.id.uuidString) == nil)
            }
        }
    }

    @Test("a comic whose source is not on this device is left alone")
    func comicWithoutSourceStays() async throws {
        try await withSources([]) { _ in
            try await withStore { store, positions in
                let book = store.addOnlineBook(name: "漫畫", author: "", sourceId: UUID(),
                                               bookInfoURL: "https://comic.test/10", contentKind: .manga,
                                               chapters: Self.chapters(20))
                #expect(await store.returnTextDeclaredComicsToTextReader(positionStore: positions) == 0)
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
