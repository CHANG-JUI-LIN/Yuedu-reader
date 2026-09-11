import Foundation
import Testing
@testable import yuedu_app

@Suite("Remote reading records", .serialized)
@MainActor
struct RemoteReadingRecordTests {
    @Test("An unlisted book retains progress and stable bookmarks after restarting the store")
    func unlistedReadingStatePersists() throws {
        let metadataURL = try makeMetadataURL()
        defer { try? FileManager.default.removeItem(at: metadataURL.deletingLastPathComponent()) }
        let store = BookStore(metadataFileURL: metadataURL)
        let book = try remoteBook()
        let earlier = bookmark(chapter: 1, offset: 140)
        let later = bookmark(chapter: 4, offset: 920)
        store.saveReadingBook(book)
        store.addBookmark(bookId: book.id, bookmark: later)
        store.addBookmark(bookId: book.id, bookmark: earlier)
        store.updateLastOpened(bookId: book.id)
        // This is the reader's explicit close/background persistence boundary.
        store.updatePosition(bookId: book.id, position: 0.375, forceSave: true)

        let restarted = BookStore(metadataFileURL: metadataURL)
        let restored = try #require(restarted.readingBook(id: book.id))
        #expect(restarted.books.isEmpty)
        #expect(restarted.readingBooks.count == 1)
        #expect(!restored.isInBookshelf)
        #expect(restored.currentPosition == 0.375)
        #expect(restored.lastOpenedDate != nil)
        #expect(restored.bookmarks.map(\.id) == [earlier.id, later.id])
        #expect(restored.bookmarks.map(\.position) == [earlier.position, later.position])
        #expect(restored.bookmarks.map(\.note) == [earlier.note, later.note])
        #expect(restored.remoteSource == book.remoteSource)
        let shelfFile = try JSONDecoder().decode([ReadingBook].self, from: Data(contentsOf: metadataURL))
        #expect(shelfFile.isEmpty)
    }

    @Test("Joining the shelf promotes the same record without losing position or bookmarks")
    func addingToShelfPreservesReadingIdentity() throws {
        let metadataURL = try makeMetadataURL()
        defer { try? FileManager.default.removeItem(at: metadataURL.deletingLastPathComponent()) }
        let store = BookStore(metadataFileURL: metadataURL)
        var book = try remoteBook()
        book.currentPosition = 0.625
        book.bookmarks = [bookmark(chapter: 3, offset: 720)]
        store.saveReadingBook(book)

        let promoted = try #require(store.addReadingBookToShelf(id: book.id))
        #expect(promoted.id == book.id)
        #expect(promoted.isInBookshelf)
        #expect(promoted.currentPosition == book.currentPosition)
        #expect(promoted.bookmarks == book.bookmarks)
        #expect(store.books.map(\.id) == [book.id])
        #expect(store.readingBooks.count == 1)
        _ = store.addReadingBookToShelf(id: book.id)
        #expect(store.readingBooks.count == 1)

        let restarted = BookStore(metadataFileURL: metadataURL)
        let restored = try #require(restarted.books.first)
        #expect(restored.id == book.id)
        #expect(restored.currentPosition == book.currentPosition)
        #expect(restored.bookmarks == book.bookmarks)
        #expect(restarted.readingBooks.count == 1)
        let readingURL = metadataURL.deletingPathExtension().appendingPathExtension("reading.json")
        let unlisted = try JSONDecoder().decode([ReadingBook].self, from: Data(contentsOf: readingURL))
        #expect(unlisted.isEmpty)
    }

    @Test("Removing a remote shelf book keeps the same reading record and offline copy after restart")
    func removingFromShelfPreservesReadingStateAndOfflineCopy() throws {
        let metadataURL = try makeMetadataURL()
        defer { try? FileManager.default.removeItem(at: metadataURL.deletingLastPathComponent()) }
        let store = BookStore(metadataFileURL: metadataURL)
        var book = try remoteBook()
        book.currentPosition = 0.72
        book.bookmarks = [bookmark(chapter: 5, offset: 630)]
        let offlineFilename = "RemoteReadingRecordTests-\(UUID().uuidString).epub"
        let offlineURL = StorageLocations.bookFile(offlineFilename)
        try FileManager.default.createDirectory(at: offlineURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let offlineData = Data("An explicit offline copy".utf8)
        try offlineData.write(to: offlineURL)
        defer { try? FileManager.default.removeItem(at: offlineURL) }
        book.contentFilename = offlineFilename
        book.remoteSource?.offlineFilename = offlineFilename
        store.saveReadingBook(book)
        _ = store.addReadingBookToShelf(id: book.id)

        store.delete(bookId: book.id)

        #expect(store.books.isEmpty)
        #expect(store.readingBook(id: book.id)?.currentPosition == 0.72)
        #expect(store.readingBook(id: book.id)?.bookmarks == book.bookmarks)
        #expect(store.readingBook(id: book.id)?.isInBookshelf == false)
        #expect(try Data(contentsOf: offlineURL) == offlineData)
        let restarted = BookStore(metadataFileURL: metadataURL)
        let restored = try #require(restarted.readingBook(id: book.id))
        #expect(restarted.books.isEmpty)
        #expect(restarted.readingBooks.count == 1)
        #expect(restored.id == book.id)
        #expect(restored.currentPosition == 0.72)
        #expect(restored.bookmarks == book.bookmarks)
        #expect(restored.remoteSource?.offlineFilename == offlineFilename)
        #expect(try Data(contentsOf: offlineURL) == offlineData)
        let promotedAgain = try #require(restarted.addReadingBookToShelf(id: book.id))
        #expect(promotedAgain.id == book.id)
        #expect(promotedAgain.bookmarks == book.bookmarks)
        #expect(restarted.readingBooks.count == 1)
    }

    @Test("Replacing shelf contents leaves unlisted reading records available and persisted")
    func shelfReplacementPreservesUnlistedRecords() throws {
        let metadataURL = try makeMetadataURL()
        defer { try? FileManager.default.removeItem(at: metadataURL.deletingLastPathComponent()) }
        let store = BookStore(metadataFileURL: metadataURL)
        var unlisted = try remoteBook()
        unlisted.currentPosition = 0.45
        unlisted.bookmarks = [bookmark(chapter: 2, offset: 30)]
        store.saveReadingBook(unlisted)
        let firstShelfBook = ReadingBook(title: "First shelf book", contentFilename: "first.txt")
        let replacement = ReadingBook(title: "Replacement shelf book", contentFilename: "replacement.txt")

        store.books = [firstShelfBook]
        #expect(store.books.map(\.id) == [firstShelfBook.id])
        #expect(store.readingBook(id: unlisted.id)?.bookmarks == unlisted.bookmarks)
        #expect(store.readingBooks.count == 2)
        store.replaceBooksFromSync([replacement])

        let restarted = BookStore(metadataFileURL: metadataURL)
        #expect(restarted.books.map(\.id) == [replacement.id])
        #expect(restarted.readingBook(id: firstShelfBook.id) == nil)
        #expect(restarted.readingBook(id: unlisted.id)?.currentPosition == 0.45)
        #expect(restarted.readingBook(id: unlisted.id)?.bookmarks == unlisted.bookmarks)
        #expect(restarted.readingBooks.count == 2)
        let shelfFile = try JSONDecoder().decode([ReadingBook].self, from: Data(contentsOf: metadataURL))
        #expect(shelfFile.map(\.id) == [replacement.id])
    }

    @Test("Saving revised metadata updates one unlisted record instead of duplicating it")
    func savingExistingRecordUsesSameID() throws {
        let metadataURL = try makeMetadataURL()
        defer { try? FileManager.default.removeItem(at: metadataURL.deletingLastPathComponent()) }
        let store = BookStore(metadataFileURL: metadataURL)
        var book = try remoteBook()
        store.saveReadingBook(book)
        book.title = "Revised remote title"
        book.bookmarks = [bookmark(chapter: 1, offset: 55)]
        store.saveReadingBook(book)

        let restarted = BookStore(metadataFileURL: metadataURL)
        #expect(restarted.readingBooks.count == 1)
        #expect(restarted.readingBook(id: book.id)?.title == "Revised remote title")
        #expect(restarted.readingBook(id: book.id)?.bookmarks == book.bookmarks)
        #expect(restarted.books.isEmpty)
    }

    @Test("Fixed-page progress is also persisted before the book is on the shelf")
    func unlistedFixedPagePositionPersists() throws {
        let metadataURL = try makeMetadataURL()
        defer { try? FileManager.default.removeItem(at: metadataURL.deletingLastPathComponent()) }
        let store = BookStore(metadataFileURL: metadataURL)
        var book = try remoteBook()
        book.contentPipelineKind = .fixedPage
        store.saveReadingBook(book)
        store.updateMangaPosition(bookId: book.id, chapter: 0, page: 12, totalChapters: 1,
                                  pageProgress: 0.6, forceSave: true)

        let restarted = BookStore(metadataFileURL: metadataURL)
        let restored = try #require(restarted.readingBook(id: book.id))
        #expect(restored.mangaChapterIndex == 0)
        #expect(restored.mangaPage == 12)
        #expect(restored.currentPosition == 0.6)
        #expect(restarted.books.isEmpty)
    }

    @Test("Books saved before remote reading existed remain shelf members")
    func legacyJSONDefaultsToShelfMembership() throws {
        let metadataURL = try makeMetadataURL()
        defer { try? FileManager.default.removeItem(at: metadataURL.deletingLastPathComponent()) }
        let id = UUID()
        let legacyJSON = """
        [{"id":"\(id.uuidString)","title":"Existing local book","author":"Author",\
        "source":"local_epub","contentFilename":"existing.epub","currentPosition":0.3,"addedDate":0}]
        """
        try Data(legacyJSON.utf8).write(to: metadataURL)

        let store = BookStore(metadataFileURL: metadataURL)
        let book = try #require(store.books.first)
        #expect(book.id == id)
        #expect(book.isInBookshelf)
        #expect(book.remoteSource == nil)
        #expect(book.currentPosition == 0.3)
        #expect(store.readingBooks.count == 1)
    }

    private func makeMetadataURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteReadingRecordTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("books_meta.json")
        // Avoid the app-wide legacy UserDefaults migration in these isolated stores.
        try Data("[]".utf8).write(to: url)
        return url
    }

    private func remoteBook() throws -> ReadingBook {
        var book = ReadingBook(title: "Remote book", author: "Author", source: "local_epub", contentFilename: "remote.epub")
        book.isInBookshelf = false
        book.remoteSource = RemoteBookReference(
            connectionID: "test-connection", entryID: "remote-book",
            format: RemoteLibraryFormat(url: try #require(URL(string: "https://example.com/book.epub")),
                                        fileExtension: "epub", mimeType: "application/epub+zip")
        )
        return book
    }

    private func bookmark(chapter: Int, offset: Int) -> Bookmark {
        Bookmark(chapterIndex: chapter, chapterTitle: "Chapter \(chapter)",
                 position: CoreTextReadingPosition(spineIndex: chapter, charOffset: offset),
                 note: "Keep this note", excerpt: "Saved text", date: Date(timeIntervalSinceReferenceDate: 100))
    }
}
