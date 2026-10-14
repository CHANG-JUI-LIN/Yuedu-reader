import Foundation
import SwiftUI
import Testing
@testable import yuedu_app

/// Unified library Phase 3a-2: what the filler filled shows, and removing it sticks.
@MainActor
@Suite("Filled metadata", .serialized)
struct FilledMetadataTests {
    private let filled = "/tmp/filled.jpg"

    // MARK: The shelf's cover plan

    @Test("a book with no artwork of its own draws its filled cover, before 預設封面")
    func filledCoverInOwnSlot() {
        let book = ReadingBook(title: "三體", author: "劉慈欣", source: "local", contentFilename: "a.txt")
        let plan = BookshelfCoverPlan.shelf(for: book, colorScheme: .light, filledCover: filled, forcesDefaultCover: false)
        #expect(plan.ownCover == .indexedCover(path: filled))
    }

    @Test("the book's saved cover wins over a filled one")
    func savedCoverWins() {
        var book = ReadingBook(title: "三體", author: "劉慈欣", source: "local", contentFilename: "a.epub")
        book.coverImagePath = "saved.jpg"
        let plan = BookshelfCoverPlan.shelf(for: book, colorScheme: .light, filledCover: filled, forcesDefaultCover: false)
        #expect(plan.ownCover == .bookCover(filename: "saved.jpg"))
    }

    @Test("強制使用預設封面 wins over a filled cover")
    func forcedDefaultWins() {
        let book = ReadingBook(title: "三體", author: "劉慈欣", source: "local", contentFilename: "a.txt")
        let plan = BookshelfCoverPlan.shelf(for: book, colorScheme: .light, filledCover: filled, forcesDefaultCover: true)
        #expect(plan.ownCover == nil)
    }

    @Test("書籍資訊 shows the filled cover it offers to remove")
    func bookInfoShowsFilled() {
        let book = ReadingBook(title: "三體", author: "劉慈欣", source: "local", contentFilename: "a.txt")
        #expect(BookshelfCoverPlan.bookInfo(for: book, filledCover: filled).ownCover == .indexedCover(path: filled))
    }

    @Test("the index gives no filled cover to a book that has its own")
    func indexRespectsOwnCover() {
        var book = ReadingBook(title: "三體", author: "劉慈欣", source: "local", contentFilename: "a.epub")
        let index = FilledCoverIndex()
        index.set(filled, for: book.id)
        #expect(index.path(for: book) == filled)
        book.coverImagePath = "saved.jpg"
        #expect(index.path(for: book) == nil)
    }

    // MARK: The store

    @Test("a filled cover is read from the sidecar; once removed it is gone and never filled again")
    func removeCoverSticks() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = ReadingBook(title: "三體", author: "劉慈欣", source: "local", contentFilename: "a.txt")
        store.saveReadingBook(book)
        let name = "filled-test-\(UUID().uuidString).jpg"
        let file = FilledMetadata.coverDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: FilledMetadata.coverDirectory, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        writeFilled(store, book, .cover, .text(name))

        await store.refreshFilledCovers()
        #expect(store.filledCovers.path(for: book) == file.path)
        #expect(store.filledValue(.cover, of: book)?.provider == OpenLibrary.key)

        store.removeFilledValue(.cover, of: book.id)
        #expect(store.filledCovers.path(for: book) == nil)
        await store.refreshFilledCovers()
        #expect(store.filledCovers.path(for: book) == nil, "a refresh does not bring it back")
        #expect(store.filledValue(.cover, of: book) == nil)

        let candidate = MetadataFillCandidate(
            copyID: book.id, title: book.title, authors: [book.author], identifiers: [], copySource: .localLibrary,
            sidecarSourceItem: .copy(book.id), hasOwnCover: false, values: [],
            decisions: store.workDecisions.decisions(involving: .copy(book.id)))
        #expect(!candidate.missing.contains(.cover), "the filler does not fill it again")
    }

    @Test("a removed description shows nothing on the detail page")
    func removeIntroSticks() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = ReadingBook(title: "三體", author: "劉慈欣", source: "local", contentFilename: "a.txt")
        store.saveReadingBook(book)
        writeFilled(store, book, .intro, .text("資料庫的簡介"))

        #expect(store.copyMetadata(of: book, sidecar: store.copyIntroValues(of: book)).intro?.text == "資料庫的簡介")
        #expect(store.filledValue(.intro, of: book)?.provider == OpenLibrary.key)

        store.removeFilledValue(.intro, of: book.id)

        #expect(store.copyMetadata(of: book, sidecar: store.copyIntroValues(of: book)).intro == nil)
        #expect(store.filledValue(.intro, of: book) == nil)
    }

    @Test("a value the import read is not offered for removal")
    func importedValueIsNotFilled() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = ReadingBook(title: "三體", author: "劉慈欣", source: "local", contentFilename: "a.epub")
        store.saveReadingBook(book)
        store.importedMetadata.write(ImportedMetadata(copyID: book.id, sourceItem: .copy(book.id), identifiers: [], values: [
            MetadataValue(field: .intro, value: .text("檔案的簡介"), provider: .localLibrary, sourceItem: nil, fetchedAt: Date()),
        ]))
        store.importedMetadata.waitForPendingWritesForTesting()

        #expect(store.filledValue(.intro, of: book) == nil)
    }

    // MARK: - Helpers

    private func makeStore() throws -> (BookStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FilledMetadataTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json")), directory)
    }

    /// What the runner writes for an Open Library answer.
    private func writeFilled(_ store: BookStore, _ book: ReadingBook, _ field: MetadataField, _ value: MetadataPayload) {
        store.importedMetadata.write(ImportedMetadata(copyID: book.id, sourceItem: .copy(book.id), identifiers: [], values: [
            MetadataValue(field: field, value: value, provider: OpenLibrary.key, sourceItem: nil, fetchedAt: Date()),
        ]))
        store.importedMetadata.waitForPendingWritesForTesting()
        store.metadataFillLedger.record(copyID: book.id, provider: OpenLibrary.key, outcome: .found, inputs: "", at: Date())
    }
}
