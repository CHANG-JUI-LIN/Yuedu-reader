import Foundation
import SwiftUI
import Testing
@testable import yuedu_app

/// Unified search 4b-1: 搜索's 書架 section, as you type, from the work index in memory.
@MainActor
@Suite("Shelf search", .serialized)
struct ShelfSearchTests {
    @Test("a query finds shelf copies by folded title or author; equal titles first")
    func findsByFoldedKeys() async throws {
        let (store, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sequel = book("三體II：黑暗森林", "劉慈欣")
        let first = book("三體", "劉慈欣")
        let other = book("球狀閃電", "劉慈欣")
        let unrelated = book("活著", "余華")
        for copy in [sequel, first, other, unrelated] { store.saveReadingBook(copy) }
        let model = ShelfSearchModel()

        await model.search("三体", in: store)
        #expect(model.matches.map(\.book.id) == [first.id, sequel.id], "Simplified finds Traditional; the equal title leads")

        await model.search("刘慈欣", in: store)
        #expect(Set(model.matches.map(\.book.id)) == [first.id, sequel.id, other.id])

        await model.search("", in: store)
        #expect(model.matches.isEmpty)
    }

    @Test("a copy added after the first search is found by the next one")
    func followsTheShelf() async throws {
        let (store, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        store.saveReadingBook(book("三體", "劉慈欣"))
        let model = ShelfSearchModel()
        await model.search("三體", in: store)
        #expect(model.matches.count == 1)

        let added = book("三體III：死神永生", "劉慈欣")
        store.saveReadingBook(added)
        await model.search("三體", in: store)
        #expect(model.matches.contains { $0.book.id == added.id })
    }

    @Test("a match opens the copy's 作品詳情")
    func routeIsTheCopy() async throws {
        let (store, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = book("三體", "劉慈欣")
        store.saveReadingBook(copy)
        let model = ShelfSearchModel()
        await model.search("三體", in: store)

        let match = try #require(model.matches.first)
        #expect(match.route.opening == .copy(copy.id))
    }

    @Test("the iOS 17 row takes the shelf's cover plan: a filled cover when the copy has none")
    func iOS17RowCover() {
        let copy = book("三體", "劉慈欣")
        let row = IOS17SearchResultTableRow(shelfBook: copy, colorScheme: .light, filledCover: "/covers/ol-1.jpg")
        #expect(row.id == copy.id)
        #expect(row.content == SearchBookListRowContent(shelfBook: copy))
        #expect(row.shelfCover?.own == .indexedCover(path: "/covers/ol-1.jpg"))
        #expect(row.shelfCover?.usesCatalogCover == false)

        let plain = IOS17SearchResultTableRow(shelfBook: copy, colorScheme: .light, filledCover: nil)
        #expect(plain.shelfCover?.own == nil)
    }

    // MARK: - Helpers

    private func makeStore() throws -> (BookStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShelfSearch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json")), folder)
    }

    private func book(_ title: String, _ author: String) -> ReadingBook {
        ReadingBook(title: title, author: author, source: "local", contentFilename: "\(UUID().uuidString).txt")
    }
}
