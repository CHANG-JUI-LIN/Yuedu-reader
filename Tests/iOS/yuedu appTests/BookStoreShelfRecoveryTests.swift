import Foundation
import Testing
@testable import yuedu_app

/// 書架檔讀不到時，不可以被空書架蓋掉。
///
/// `loadMeta` 讀失敗後 `records` 是空的、`lastPersistedMetadataData` 也是 nil，所以下一次存檔
/// （匯入一本書、套用同步、甚至只是記閱讀進度）就會覆蓋原檔，整份書架索引就沒了。
@Suite("BookStore shelf recovery", .serialized)
struct BookStoreShelfRecoveryTests {

    @Test("an unreadable shelf file is kept aside before anything overwrites it")
    @MainActor
    func unreadableShelfIsKeptAside() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadataURL = directory.appendingPathComponent("books_meta.json")
        let unreadable = Data("{ not json".utf8)
        try unreadable.write(to: metadataURL)

        let store = BookStore(metadataFileURL: metadataURL)
        store.replaceBooksFromSync([ReadingBook(title: "新書", author: "Author", contentFilename: "")])

        let backups = try corruptBackups(in: directory)
        #expect(backups.count == 1)
        #expect(try backups.first.map { try Data(contentsOf: $0) } == unreadable)
        // Once the bytes are safe, the shelf is writable again.
        let saved = try JSONDecoder().decode([ReadingBook].self, from: Data(contentsOf: metadataURL))
        #expect(saved.map(\.title) == ["新書"])
    }

    @Test("a shelf that could not be kept aside is never overwritten")
    @MainActor
    func shelfThatCannotBeKeptAsideIsNotOverwritten() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadataURL = directory.appendingPathComponent("books_meta.json")
        let unreadable = Data("{ not json".utf8)
        try unreadable.write(to: metadataURL)
        // Something else already holds the name this file's copy would take.
        let occupied = Data("an older copy".utf8)
        try occupied.write(to: try backupURL(for: metadataURL))

        let store = BookStore(metadataFileURL: metadataURL)
        store.replaceBooksFromSync([ReadingBook(title: "新書", author: "Author", contentFilename: "")])

        #expect(try Data(contentsOf: metadataURL) == unreadable)
        #expect(try Data(contentsOf: backupURL(for: metadataURL)) == occupied)
    }

    @Test("a relaunch recognises the copy it already made")
    @MainActor
    func relaunchReusesTheExistingCopy() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadataURL = directory.appendingPathComponent("books_meta.json")
        let unreadable = Data("{ not json".utf8)
        try unreadable.write(to: metadataURL)

        _ = BookStore(metadataFileURL: metadataURL)
        let relaunched = BookStore(metadataFileURL: metadataURL)
        relaunched.replaceBooksFromSync([ReadingBook(title: "新書", author: "Author", contentFilename: "")])

        #expect(try corruptBackups(in: directory).count == 1)
        let saved = try JSONDecoder().decode([ReadingBook].self, from: Data(contentsOf: metadataURL))
        #expect(saved.map(\.title) == ["新書"])
    }

    // MARK: - Reading records
    //
    // 只讀過、不在書架上的書（立即閱讀、從書架移除的遠端書庫參照）只記在閱讀記錄檔。
    // 這個檔讀不到時一樣不能被下一次存檔（套用同步、移出書架）用空清單蓋掉。

    @Test("an unreadable reading-record file is kept aside before a sync writes over it")
    @MainActor
    func unreadableReadingRecordsAreKeptAside() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadataURL = directory.appendingPathComponent("books_meta.json")
        let (shelf, unreadable) = try seedUnreadableReadingRecords(metadataURL: metadataURL)

        let store = BookStore(metadataFileURL: metadataURL)
        store.replaceBooksFromSync([shelf])

        let backups = try readingRecordBackups(in: directory)
        #expect(backups.count == 1)
        #expect(try backups.first.map { try Data(contentsOf: $0) } == unreadable)
        // Once the bytes are safe, the file is writable again.
        let saved = try JSONDecoder().decode([ReadingBook].self, from: Data(contentsOf: readingURL(for: metadataURL)))
        #expect(saved.isEmpty)
    }

    @Test("a reading-record file that could not be kept aside is never overwritten")
    @MainActor
    func readingRecordsThatCannotBeKeptAsideAreNotOverwritten() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadataURL = directory.appendingPathComponent("books_meta.json")
        let (shelf, unreadable) = try seedUnreadableReadingRecords(metadataURL: metadataURL)
        let readingURL = readingURL(for: metadataURL)
        // Something else already holds the name this file's copy would take.
        let occupied = Data("an older copy".utf8)
        try occupied.write(to: try backupURL(for: readingURL))

        let store = BookStore(metadataFileURL: metadataURL)
        store.replaceBooksFromSync([shelf])
        #expect(try Data(contentsOf: readingURL) == unreadable)

        // Taking a remote reference off the shelf writes the reading records on their own.
        store.delete(bookId: shelf.id)
        store.waitForQueuedWrites()
        #expect(try Data(contentsOf: readingURL) == unreadable)
        #expect(try Data(contentsOf: backupURL(for: readingURL)) == occupied)
    }

    @Test("TXT bookmarks of a book only read are not committed over an unreadable reading-record file")
    @MainActor
    func txtBookmarksAreNotCommittedOverUnreadableReadingRecords() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadataURL = directory.appendingPathComponent("books_meta.json")
        let (_, unreadable) = try seedUnreadableReadingRecords(metadataURL: metadataURL)
        let readingURL = readingURL(for: metadataURL)
        try Data("an older copy".utf8).write(to: try backupURL(for: readingURL))

        let store = BookStore(metadataFileURL: metadataURL)
        let original = [Bookmark(chapterIndex: 3, chapterTitle: "第三章", position: CoreTextReadingPosition(spineIndex: 3, charOffset: 10))]
        let migrated = [Bookmark(chapterIndex: 5, chapterTitle: "第三章", position: CoreTextReadingPosition(spineIndex: 5, charOffset: 10))]
        var book = ReadingBook(title: "立即閱讀", contentFilename: "\(UUID().uuidString).txt")
        book.isInBookshelf = false
        book.bookmarks = original
        store.saveReadingBook(book)
        store.waitForQueuedWrites()

        // The caller publishes the new chapter index only once the bookmarks are durable.
        await #expect(throws: (any Error).self) {
            try await store.commitTXTBookmarks(bookId: book.id, original: original, migrated: migrated)
        }
        store.waitForQueuedWrites()
        #expect(store.readingBook(id: book.id)?.bookmarks == original)
        #expect(try Data(contentsOf: readingURL) == unreadable)
    }

    @Test("a relaunch recognises the reading-record copy it already made")
    @MainActor
    func relaunchReusesTheExistingReadingRecordCopy() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadataURL = directory.appendingPathComponent("books_meta.json")
        let (shelf, _) = try seedUnreadableReadingRecords(metadataURL: metadataURL)

        _ = BookStore(metadataFileURL: metadataURL)
        let relaunched = BookStore(metadataFileURL: metadataURL)
        relaunched.replaceBooksFromSync([shelf])

        #expect(try readingRecordBackups(in: directory).count == 1)
    }

    // MARK: - Helpers

    /// A shelf holding one remote-library book, and a reading-record file holding a book only
    /// read, whose write was cut short. Returns the shelf book and the file's unreadable bytes.
    @MainActor
    private func seedUnreadableReadingRecords(metadataURL: URL) throws -> (ReadingBook, Data) {
        let seeding = BookStore(metadataFileURL: metadataURL)
        var shelf = ReadingBook(title: "書架上的遠端書", source: "local", contentFilename: "\(UUID().uuidString).epub")
        shelf.remoteSource = RemoteBookReference(
            connectionID: "test-connection", entryID: "1",
            format: RemoteLibraryFormat(url: URL(string: "https://example.com/1.epub")!,
                                        fileExtension: "epub", mimeType: "application/epub+zip")
        )
        seeding.saveReadingBook(shelf)
        var readOnly = ReadingBook(title: "只讀過的書", author: "Author", contentFilename: "")
        readOnly.isInBookshelf = false
        seeding.saveReadingBook(readOnly)
        seeding.waitForQueuedWrites()

        let readingURL = readingURL(for: metadataURL)
        let written = try Data(contentsOf: readingURL)
        #expect(String(decoding: written, as: UTF8.self).contains("只讀過的書"))
        let unreadable = Data(written.dropLast())
        try unreadable.write(to: readingURL)
        return (shelf, unreadable)
    }

    private func readingURL(for metadataURL: URL) -> URL {
        metadataURL.deletingPathExtension().appendingPathExtension("reading.json")
    }

    private func readingRecordBackups(in directory: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("books_meta.reading.corrupt-") }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookStoreShelfRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func corruptBackups(in directory: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("corrupt") }
    }

    /// Mirrors the store's own naming: the shelf file's modification time, so a relaunch
    /// recognises the copy it made rather than filling the folder with duplicates.
    private func backupURL(for metadataURL: URL) throws -> URL {
        let modified = try metadataURL
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date()
        return metadataURL
            .deletingPathExtension()
            .appendingPathExtension("corrupt-\(Int(modified.timeIntervalSince1970)).json")
    }
}
