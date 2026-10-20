import Foundation
import Testing
@testable import yuedu_app

/// Feedback #24: 探索's 書架 section, the shelf's books on the home.
@MainActor
@Suite("Explore 書架 section", .serialized)
struct ExploreBookshelfSectionTests {
    private func titles(_ entries: [CollectionEntry]) -> [String] {
        entries.compactMap { entry in
            if case .item(_, let summary, _) = entry { summary.title } else { nil }
        }
    }

    @Test("it lists the shelf in the 書架 tab's order, books only, the first twenty")
    func shelfInTabOrder() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BookshelfSection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json"))
        defer { store.waitForQueuedWrites() }
        for title in ["Charlie", "Alpha", "Bravo"] {
            var book = ReadingBook(title: title, author: "", source: "local_epub", contentFilename: "\(title).epub")
            book.group = "小說"
            store.saveReadingBook(book)
        }
        let section = HomeSection(layout: .row, binding: .bookshelf)

        let manual = ShelfProvider(store: store, sortOrder: { .manual })
        #expect(manual.loadPolicy(for: section) == .local)
        let shelf = try await manual.load(section)
        // A group's books are listed with the rest; the group itself is no chip.
        #expect(shelf.count == 3)
        #expect(titles(shelf) == store.books.map(\.title))

        let byTitle = ShelfProvider(store: store, sortOrder: { .title })
        #expect(titles(try await byTitle.load(section)) == ["Alpha", "Bravo", "Charlie"])

        for index in 0..<HomeRow.limit {
            store.saveReadingBook(ReadingBook(title: "Book \(index)", author: "", source: "local_epub",
                                              contentFilename: "book\(index).epub"))
        }
        #expect(try await manual.load(section).count == HomeRow.limit)
    }

    @Test("it is saved by name, offered under App 資料, titled 書架, and keeps books read to the end")
    func binding() throws {
        let section = HomeSection(layout: .coverGrid, binding: .bookshelf)
        let data = try JSONEncoder().encode(section)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((json["binding"] as? [String: Any])?["type"] as? String == "bookshelf")
        #expect(try JSONDecoder().decode(HomeSection.self, from: data) == section)

        #expect(HomeSectionBinding.bookshelf.contentOwner == .appData)
        #expect(HomeSectionBinding.appData.contains(.bookshelf))
        #expect(section.isEditable)
        #expect(section.displayTitle(sourceName: "") == localized("書架"))
        #expect(!HomeReadFilter(hides: true, isRead: { _ in true }).hides(in: .bookshelf))
    }
}
