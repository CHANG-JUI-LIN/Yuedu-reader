import Foundation
import Testing
@testable import yuedu_app

@Suite("Bookshelf group actions", .serialized)
@MainActor
struct BookshelfGroupActionsTests {
    @Test("重命名分組 moves every book in the group, trimmed, and saves it")
    func renameMovesEveryBook() throws {
        let (store, directory, metadataURL) = try makeStore(groups: ["色", "色", "玄幻", ""])
        defer { try? FileManager.default.removeItem(at: directory) }

        store.renameGroup("色", to: "  在追 ")
        // The shelf's own debounce holds the write; the scene flushes it on the way out.
        store.flushPendingMetadataSave()
        store.waitForQueuedWrites()

        #expect(groups(store.books) == ["在追", "在追", "玄幻", ""])
        #expect(store.allGroups == ["在追", "玄幻"])
        let saved = try JSONDecoder().decode([ReadingBook].self, from: Data(contentsOf: metadataURL))
        #expect(groups(saved) == ["在追", "在追", "玄幻", ""])
    }

    @Test("a name another group has merges the two")
    func renameOntoExistingGroupMerges() throws {
        let (store, directory, _) = try makeStore(groups: ["色", "玄幻", "玄幻"])
        defer { try? FileManager.default.removeItem(at: directory) }

        store.renameGroup("色", to: "玄幻")

        #expect(groups(store.books) == ["玄幻", "玄幻", "玄幻"])
        #expect(store.allGroups == ["玄幻"])
    }

    @Test("an empty or unchanged name leaves the shelf as it is")
    func emptyOrUnchangedNameDoesNothing() throws {
        let (store, directory, metadataURL) = try makeStore(groups: ["色", ""])
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = try Data(contentsOf: metadataURL)

        store.renameGroup("色", to: "   ")
        store.renameGroup("色", to: " 色 ")
        store.flushPendingMetadataSave()
        store.waitForQueuedWrites()

        #expect(groups(store.books) == ["色", ""])
        #expect(try Data(contentsOf: metadataURL) == before)
    }

    @Test("解散分組 keeps the books on the shelf in no group")
    func dissolveKeepsBooksUngrouped() throws {
        let (store, directory, _) = try makeStore(groups: ["色", "色", "玄幻"])
        defer { try? FileManager.default.removeItem(at: directory) }

        store.dissolveGroup("色")

        #expect(store.books.count == 3)
        #expect(groups(store.books) == ["", "", "玄幻"])
        #expect(store.allGroups == ["玄幻"])
    }

    /// Each book's group, in the order `makeStore` seeded them: the shelf keeps its own order.
    private func groups(_ books: [ReadingBook]) -> [String] {
        books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.map(\.group)
    }

    private func makeStore(groups: [String]) throws -> (BookStore, URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookshelfGroupActionsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadataURL = directory.appendingPathComponent("books_meta.json")
        let store = BookStore(metadataFileURL: metadataURL)
        let books = groups.enumerated().map { index, group in
            var book = ReadingBook(title: "書\(index)", author: "作者", contentFilename: "")
            book.group = group
            return book
        }
        store.replaceBooksFromSync(books)
        store.waitForQueuedWrites()
        return (store, directory, metadataURL)
    }
}
