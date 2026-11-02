import Foundation
import Testing
@testable import yuedu_app

/// The text version a converted book's positions, bookmarks and highlights index (MOBI plan,
/// "Positions across devices"): stamped from the first release, so a later converter that
/// changes the text can tell which text each one meant, and never restored over another text.
@Suite("Converted text versions", .serialized)
@MainActor
struct ConvertedTextVersionTests {
    private let positions = JSONFileReadingPositionStore()
    private let place = CoreTextReadingPosition(spineIndex: 2, charOffset: 40)

    @Test("a converted book's saved position is stamped with its text version; another book's is not")
    func saveStamps() async throws {
        let converted = UUID().uuidString, plain = UUID().uuidString
        defer { Self.clean(converted, plain) }
        ConvertedTextVersions.shared.set(1, for: converted)

        await positions.save(place, for: converted)
        await positions.save(place, for: plain)

        #expect(try Self.file(converted)["textVersion"] as? Int == 1)
        let plainFile = try Self.file(plain)
        #expect(plainFile["textVersion"] == nil)
        #expect(plainFile["countsPictures"] as? Bool == true)
    }

    @Test("a position of another text version stays on disk and is not restored; unstamped reads as the first")
    func restoreRefusesAnotherText() async throws {
        let id = UUID().uuidString
        defer { Self.clean(id) }
        ConvertedTextVersions.shared.set(2, for: id)
        await positions.save(place, for: id)
        #expect(positions.loadSync(for: id) == place)

        ConvertedTextVersions.shared.set(1, for: id)
        #expect(positions.loadSync(for: id) == nil)
        #expect(FileManager.default.fileExists(atPath: Self.url(id).path))

        ConvertedTextVersions.shared.set(nil, for: id)
        await positions.save(place, for: id)
        ConvertedTextVersions.shared.set(1, for: id)
        #expect(positions.loadSync(for: id) == place)
        ConvertedTextVersions.shared.set(2, for: id)
        #expect(positions.loadSync(for: id) == nil)
    }

    @Test("a synced position keeps its stamp, and one of another text version does not replace this device's")
    func syncedPositions() async throws {
        let id = UUID().uuidString
        defer { Self.clean(id) }
        ConvertedTextVersions.shared.set(1, for: id)
        await positions.save(place, for: id)
        let other = CoreTextReadingPosition(spineIndex: 5, charOffset: 9)

        JSONFileReadingPositionStore.replacePositionsFromSync([id: SyncedReadingPosition(position: other, textVersion: 2)])
        #expect(positions.loadSync(for: id) == place)

        JSONFileReadingPositionStore.replacePositionsFromSync([id: SyncedReadingPosition(position: other, textVersion: 1)])
        #expect(positions.loadSync(for: id) == other)
        let file = try Self.file(id)
        #expect(file["textVersion"] as? Int == 1)
        #expect(file["countsPictures"] == nil, "another device's build wrote it")
    }

    @Test("a bookmark without a stamp encodes as before, and a stamped one round-trips")
    func bookmarkEncoding() throws {
        let bookmark = Bookmark(chapterIndex: 1, chapterTitle: "一", position: place, excerpt: "摘錄")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(bookmark)) as? [String: Any]
        #expect(Set(object?.keys.map { $0 } ?? []) == [
            "id", "chapterIndex", "chapterTitle", "position", "length", "kind", "date", "note", "excerpt",
        ])
        var stamped = bookmark
        stamped.textVersion = 1
        #expect(try JSONDecoder().decode(Bookmark.self, from: JSONEncoder().encode(stamped)) == stamped)
    }

    @Test("a converted book's bookmarks and highlights are stamped where the store makes them; another text's are not drawn")
    func bookmarksStamped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ConvertedTextVersionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BookStore(metadataFileURL: root.appendingPathComponent("books.json"))
        let book = ReadingBook(title: "題", source: "local_epub", contentFilename: "book.epub")
        store.saveReadingBook(book)
        defer { ConvertedTextVersions.shared.set(nil, for: book.id.uuidString) }
        ConvertedTextVersions.shared.set(1, for: book.id.uuidString)

        store.addTextAnnotation(bookId: book.id, chapterIndex: 0, chapterTitle: "一",
                                position: CoreTextReadingPosition(spineIndex: 0, charOffset: 3), length: 4, excerpt: "劃線")
        store.togglePageBookmark(bookId: book.id, chapterIndex: 1, chapterTitle: "二",
                                 range: ReaderPageBookmarkRange(spineIndex: 1, startOffset: 0, endOffset: 100), excerpt: "頁")
        store.addBookmark(bookId: book.id, bookmark: Bookmark(chapterIndex: 2, chapterTitle: "三", position: place))

        let bookmarks = try #require(store.readingBook(id: book.id)).bookmarks
        #expect(bookmarks.count == 3)
        #expect(bookmarks.allSatisfy { $0.textVersion == 1 })
        #expect(bookmarks.indexingReadText(of: book.id).count == 3)
        ConvertedTextVersions.shared.set(2, for: book.id.uuidString)
        #expect(bookmarks.indexingReadText(of: book.id).isEmpty)
    }

    @Test("an Aozora book is not entered: its records are unstamped and would all read as version 1")
    func aozoraNotEntered() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ConvertedTextVersionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = BookStore(metadataFileURL: root.appendingPathComponent("books.json"))
        defer {
            for book in store.books { store.delete(bookId: book.id) }
            try? FileManager.default.removeItem(at: root)
        }
        let url = root.appendingPathComponent("neko.txt")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/TXTEncodings/aozora-neko-jijo.txt"), to: url)
        let book = try await LocalBookImportService.importBook(at: url, store: store)
        #expect(book.aozora != nil)

        #expect(try await ConvertedBookRegenerator.prepare(book: book, store: store) == .current)
        #expect(ConvertedTextVersions.shared.version(for: book.id.uuidString) == nil)
    }

    // MARK: Helpers

    private static func url(_ bookId: String) -> URL {
        StorageLocations.readingPosition.appendingPathComponent("\(bookId).json")
    }

    private static func file(_ bookId: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url(bookId)))
        return try #require(object as? [String: Any])
    }

    private static func clean(_ bookIds: String...) {
        for id in bookIds {
            ConvertedTextVersions.shared.set(nil, for: id)
            try? FileManager.default.removeItem(at: url(id))
        }
    }
}
