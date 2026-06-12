import Foundation
import Testing
@testable import yuedu_app

@Suite("BookStore metadata write budget", .serialized)
struct BookStoreMetadataWriteBudgetTests {
    @Test("tiny progress changes stay in memory until a forced save")
    @MainActor
    func tinyProgressChangesStayInMemoryUntilForcedSave() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let metadataURL = directory.appendingPathComponent("books_meta.json")
        let store = BookStore(metadataFileURL: metadataURL)

        var book = ReadingBook(title: "Long Online Book", author: "Author", contentFilename: "")
        book.isOnline = true
        book.contentPipelineKind = .html
        book.onlineChapters = (0..<2_000).map {
            OnlineChapterRef(index: $0, title: "Chapter \($0)", url: "https://example.com/\($0)")
        }

        store.replaceBooksFromSync([book])
        let initialData = try Data(contentsOf: metadataURL)

        store.updatePosition(bookId: book.id, position: 0.0001)

        #expect(store.books.first?.currentPosition == 0.0001)
        #expect(try Data(contentsOf: metadataURL) == initialData)

        store.updatePosition(bookId: book.id, position: 0.0001, forceSave: true)

        let saved = try JSONDecoder().decode([ReadingBook].self, from: Data(contentsOf: metadataURL))
        #expect(saved.first?.currentPosition == 0.0001)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookStoreMetadataWriteBudgetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
