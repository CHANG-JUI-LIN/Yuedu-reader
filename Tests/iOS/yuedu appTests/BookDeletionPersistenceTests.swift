import Foundation
import Testing
@testable import yuedu_app

/// Deleting a book removes its files at once, so the shelf file has to lose the record at
/// once too. With the record left to the 2-second debounced save, an app killed in between
/// came back with the book on the shelf and no file behind it (2026-10-11: the reader stopped
/// at 「TXT 目錄修復未完成」 on a book a UI test had deleted just before the app was terminated).
@Suite("Book deletion persistence", .serialized)
@MainActor
struct BookDeletionPersistenceTests {
    @Test("a deleted book is gone from the shelf file without waiting for the debounce")
    func deletionIsWrittenAtOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookDeletionPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadataURL = directory.appendingPathComponent("books_meta.json")
        let store = BookStore(metadataFileURL: metadataURL)
        var kept = ReadingBook(title: "留下的書", author: "作者", source: "https://example.com/kept", contentFilename: "")
        kept.isOnline = true
        var deleted = ReadingBook(title: "刪掉的書", author: "作者", source: "https://example.com/deleted", contentFilename: "")
        deleted.isOnline = true
        store.replaceBooksFromSync([kept, deleted])
        store.waitForQueuedWrites()

        store.delete(bookId: deleted.id)
        // No flush: an app killed now never runs a pending debounced save.
        store.waitForQueuedWrites()

        let reopened = BookStore(metadataFileURL: metadataURL)
        #expect(reopened.readingBook(id: deleted.id) == nil)
        #expect(reopened.readingBook(id: kept.id) != nil)
    }
}
