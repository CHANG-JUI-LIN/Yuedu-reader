import Foundation
import Testing
@testable import yuedu_app
import YueduCoreText

/// Offsets saved before YueduCoreText 0.11, when a picture had a place in a browser chapter's
/// source text but no extent, move to 0.11's, where it takes one U+FFFC.
@MainActor
@Suite(.serialized)
struct PictureOffsetMigrationTests {
    /// "前文" ⟨picture⟩ "图注后文": 0.10 read "前文图注后文", 0.11 reads this.
    private nonisolated static let text = "前文\u{FFFC}图注后文"
    private nonisolated static let pictures = BrowserPictureOffsets([2])
    private nonisolated static let spine = 3

    private nonisolated static func bookmark(_ location: Int, _ length: Int, excerpt: String,
                                 kind: Bookmark.Kind = .highlight, translationOffset: Int? = nil) -> Bookmark {
        Bookmark(chapterIndex: spine, chapterTitle: "第三章",
                 position: CoreTextReadingPosition(spineIndex: spine, charOffset: location,
                                                   translationOffset: translationOffset),
                 length: length, kind: kind, excerpt: excerpt,
                 annotationStyle: kind == .bookmark ? nil : .highlight, annotationColor: kind == .bookmark ? nil : .yellow)
    }

    private nonisolated static func migrated(_ bookmark: Bookmark) -> [Int] {
        let moved = PictureOffsetMigration.moved([bookmark], spine: spine, sourceText: text, pictures: pictures)?.first
            ?? bookmark
        return [moved.position.charOffset, moved.length]
    }

    @Test("a 0.10 bookmark moves past the pictures before it; 0.11's and the legacy engine's stay", arguments: [
        // 0.10, the text page after the picture: it shared the picture page's place.
        (bookmark(2, 4, excerpt: "图注后文", kind: .bookmark), [3, 4]),
        // 0.10, the page of the picture alone: an empty range, an empty excerpt — its place names it still.
        (bookmark(2, 0, excerpt: "", kind: .bookmark), [2, 0]),
        // 0.11, the page of the picture: its excerpt starts with the picture.
        (bookmark(2, 1, excerpt: "\u{FFFC}", kind: .bookmark), [2, 1]),
        // 0.10, a highlight after the picture.
        (bookmark(3, 2, excerpt: "注后"), [4, 2]),
        // 0.10, a highlight across the picture: it takes the picture in.
        (bookmark(1, 2, excerpt: "文图"), [1, 3]),
        // 0.11, a highlight across the picture.
        (bookmark(1, 3, excerpt: "文\u{FFFC}图"), [1, 3]),
        // 0.11, a highlight after the picture.
        (bookmark(4, 2, excerpt: "注后"), [4, 2]),
        // Before the picture: nothing to move.
        (bookmark(0, 2, excerpt: "前文"), [0, 2]),
        // The legacy engine's, whose text reads at neither place.
        (bookmark(3, 2, excerpt: "插图"), [3, 2]),
        // 整章翻譯: the legacy engine's offsets.
        (bookmark(3, 2, excerpt: "注后", translationOffset: 0), [3, 2]),
    ])
    func bookmarkMoves(bookmark: Bookmark, expected: [Int]) {
        #expect(Self.migrated(bookmark) == expected)
    }

    /// An older build that syncs bookmarks back unmoved, or a second layout of the chapter,
    /// never moves one twice.
    @Test("moving is idempotent")
    func movingTwiceMovesOnce() throws {
        let bookmarks = [Self.bookmark(2, 4, excerpt: "图注后文", kind: .bookmark), Self.bookmark(1, 2, excerpt: "文图")]
        let once = try #require(PictureOffsetMigration.moved(bookmarks, spine: Self.spine, sourceText: Self.text,
                                                              pictures: Self.pictures))
        #expect(PictureOffsetMigration.moved(once, spine: Self.spine, sourceText: Self.text, pictures: Self.pictures) == nil)
        // A moved bookmark keeps everything but its place, and its excerpt is the source text
        // there, as 0.11 cuts one.
        #expect(once.map(\.id) == bookmarks.map(\.id))
        #expect(once.map(\.excerpt) == ["图注后文", "文\u{FFFC}图"])
        #expect(once.map(\.length) == [4, 3])
        #expect(once[1].annotationStyle == .highlight)
    }

    @Test("other chapters' bookmarks stay")
    func otherChapterStays() {
        var other = Self.bookmark(3, 2, excerpt: "注后")
        other = Bookmark(chapterIndex: 4, chapterTitle: "第四章",
                         position: CoreTextReadingPosition(spineIndex: 4, charOffset: 3), length: 2,
                         kind: .highlight, excerpt: "注后", id: other.id)
        #expect(PictureOffsetMigration.moved([other], spine: Self.spine, sourceText: Self.text, pictures: Self.pictures) == nil)
    }

    @Test("a saved position moves past the pictures at or before it", arguments: [
        (CoreTextReadingPosition(spineIndex: 3, charOffset: 2), 3),
        (CoreTextReadingPosition(spineIndex: 3, charOffset: 4), 5),
        (CoreTextReadingPosition(spineIndex: 3, charOffset: 1), 1),
        // A chapter's start and end are places, not text.
        (CoreTextReadingPosition.chapterStart(3), 0),
        (CoreTextReadingPosition.chapterEnd(3), Int.max),
        // 整章翻譯: the legacy engine's offset.
        (CoreTextReadingPosition(spineIndex: 3, charOffset: 2, translationOffset: 5), 2),
    ])
    func positionMoves(position: CoreTextReadingPosition, expected: Int) {
        #expect(PictureOffsetMigration.moved(position, pictures: Self.pictures).charOffset == expected)
    }

    private final class Positions: ReadingPositionStore, @unchecked Sendable {
        let lock = NSLock()
        var value: CoreTextReadingPosition?
        var stamped: Bool
        init(_ position: CoreTextReadingPosition?, stamped: Bool) { value = position; self.stamped = stamped }
        func save(_ position: CoreTextReadingPosition, for bookId: String) async {
            lock.withLock { value = position; stamped = true }
        }
        func load(for bookId: String) async -> CoreTextReadingPosition? { loadSync(for: bookId) }
        func loadSync(for bookId: String) -> CoreTextReadingPosition? { lock.withLock { value } }
        func flush(for bookId: String) async {}
        func countsPictures(for bookId: String) -> Bool { lock.withLock { stamped } }
    }

    @Test("an unstamped position moves once, and is stamped")
    func unstampedPositionMovesOnce() async {
        let positions = Positions(CoreTextReadingPosition(spineIndex: 3, charOffset: 2), stamped: false)
        var asked: [Int] = []
        let moved = await PictureOffsetMigration.migrateSavedPosition(bookId: "b", positions: positions) { spine in
            asked.append(spine)
            return Self.pictures
        }
        #expect(moved)
        #expect(asked == [3])
        #expect(positions.value?.charOffset == 3)
        #expect(positions.countsPictures(for: "b"))
        let again = await PictureOffsetMigration.migrateSavedPosition(bookId: "b", positions: positions) { _ in Self.pictures }
        #expect(!again)
        #expect(positions.value?.charOffset == 3)
    }

    @Test("a legacy chapter's position is stamped where it is")
    func legacyChapterPositionIsStamped() async {
        let positions = Positions(CoreTextReadingPosition(spineIndex: 3, charOffset: 2), stamped: false)
        let moved = await PictureOffsetMigration.migrateSavedPosition(bookId: "b", positions: positions) { _ in nil }
        #expect(!moved)
        #expect(positions.value?.charOffset == 2)
        #expect(positions.countsPictures(for: "b"))
    }

    @Test("a stamped position is not asked about")
    func stampedPositionStays() async {
        let positions = Positions(CoreTextReadingPosition(spineIndex: 3, charOffset: 2), stamped: true)
        var asked = false
        let moved = await PictureOffsetMigration.migrateSavedPosition(bookId: "b", positions: positions) { _ in
            asked = true
            return Self.pictures
        }
        #expect(!moved)
        #expect(!asked)
        #expect(positions.value?.charOffset == 2)
    }

    /// Every save of this build stamps the file; a file an older build wrote, or one that came
    /// through sync, has no stamp, and older builds still read a stamped one.
    @Test("the position file stamps every save")
    func positionFileStamp() async throws {
        let store = JSONFileReadingPositionStore()
        let bookId = UUID().uuidString
        let url = StorageLocations.readingPosition.appendingPathComponent("\(bookId).json")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(store.countsPictures(for: bookId), "no file: nothing to move")

        try JSONEncoder().encode(CoreTextReadingPosition(spineIndex: 3, charOffset: 2)).write(to: url)
        #expect(!store.countsPictures(for: bookId))

        await store.save(CoreTextReadingPosition(spineIndex: 3, charOffset: 3), for: bookId)
        #expect(store.countsPictures(for: bookId))
        #expect(store.loadSync(for: bookId) == CoreTextReadingPosition(spineIndex: 3, charOffset: 3))
        #expect(try JSONDecoder().decode(CoreTextReadingPosition.self, from: Data(contentsOf: url))
            == CoreTextReadingPosition(spineIndex: 3, charOffset: 3))

        JSONFileReadingPositionStore.replacePositionsFromSync([bookId: SyncedReadingPosition(position: CoreTextReadingPosition(spineIndex: 3, charOffset: 2))])
        #expect(!store.countsPictures(for: bookId))
    }

    @Test("the store moves a chapter's bookmarks and saves them")
    func storeMovesBookmarks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books.json"))
        var book = ReadingBook(title: "Test", author: "Test", contentFilename: "book.epub")
        book.bookmarks = [Self.bookmark(3, 2, excerpt: "注后")]
        store.saveReadingBook(book)

        #expect(store.movePictureOffsets(bookId: book.id, spine: Self.spine, sourceText: Self.text, pictures: Self.pictures))
        #expect(store.readingBook(id: book.id)?.bookmarks.first?.position.charOffset == 4)
        #expect(!store.movePictureOffsets(bookId: book.id, spine: Self.spine, sourceText: Self.text, pictures: Self.pictures))
    }
}
