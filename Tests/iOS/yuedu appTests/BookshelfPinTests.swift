import Foundation
import Testing
@testable import yuedu_app

/// 置頂 on the shelf (feedback #17): a pinned book comes first in every order, and a book
/// nobody pinned encodes exactly as before, so its sync hash does not change.
@MainActor
struct BookshelfPinTests {
    private func book(_ title: String, pinnedAt: Date? = nil) -> ReadingBook {
        var book = ReadingBook(title: title, contentFilename: "\(title).txt")
        book.pinnedAt = pinnedAt
        return book
    }

    @Test("pinned books come first in every order, the latest pinned on top")
    func pinnedFirstInEveryOrder() {
        let early = Date(timeIntervalSince1970: 1_000)
        let late = Date(timeIntervalSince1970: 2_000)
        let books = [
            book("A"), book("B", pinnedAt: early), book("C"), book("D", pinnedAt: late),
        ]
        for order in [BookSortOrder.manual, .recentlyRead, .title, .author] {
            let titles = order.sorted(books).map(\.title)
            #expect(Array(titles.prefix(2)) == ["D", "B"], "\(order)")
        }
        // 手動 keeps the unpinned books where the shelf holds them.
        #expect(BookSortOrder.manual.sorted(books).map(\.title) == ["D", "B", "A", "C"])
    }

    @Test("no pinned book leaves the order untouched")
    func noPinnedBooks() {
        let books = [book("B"), book("A")]
        #expect(BookSortOrder.pinnedFirst(books).map(\.title) == ["B", "A"])
    }

    @Test("an unpinned book does not write the new key")
    func unpinnedBookEncodesAsBefore() throws {
        let json = String(decoding: try JSONEncoder().encode(book("Plain")), as: UTF8.self)
        #expect(!json.contains("pinnedAt"))
    }

    @Test("a pin survives encoding")
    func pinRoundTrips() throws {
        let pinned = book("Pinned", pinnedAt: Date(timeIntervalSince1970: 3_000))
        let decoded = try JSONDecoder().decode(ReadingBook.self, from: JSONEncoder().encode(pinned))
        #expect(decoded.isPinned)
        #expect(decoded.pinnedAt == pinned.pinnedAt)
    }

    @Test("setPinned pins and unpins through the store")
    func storePinsAndUnpins() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookshelfPin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))
        let target = book("Target")
        store.replaceBooksFromSync([book("Other"), target])

        store.setPinned(true, bookId: target.id)
        #expect(store.books.first { $0.id == target.id }?.isPinned == true)

        store.setPinned(false, bookId: target.id)
        #expect(store.books.first { $0.id == target.id }?.pinnedAt == nil)
        store.waitForQueuedWrites()
    }
}
