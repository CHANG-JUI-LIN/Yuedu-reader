import Foundation
import Testing
@testable import yuedu_app

/// Unified library 5d-3c: 精簡閱讀卡片's ground colour, its ••• menu, and what the menu's
/// 從繼續閱讀移除 and 標記為已讀完 do to the shelf (Phase 5 plan, decision 20).
@MainActor
@Suite("Home compact reading card", .serialized)
struct HomeCompactReadingCardTests {
    private func folder() throws -> (URL, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CompactCard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (folder, { try? FileManager.default.removeItem(at: folder) })
    }

    private func continueReading(_ store: BookStore) async throws -> [UUID] {
        try await ShelfProvider(store: store).load(HomeSection(layout: .compactReadingCard, binding: .continueReading))
            .compactMap { entry -> UUID? in
                if case .item(_, _, .copy(let id)) = entry { return id }
                return nil
            }
    }

    @Test("a dark cover keeps its colour; a pale one darkens just enough for white text")
    func groundContrast() {
        let navy = CoverTint.RGB(red: 0.1, green: 0.15, blue: 0.35)
        #expect(CoverTint.background(for: navy, minimumContrast: 4.5) == navy)

        for pale in [CoverTint.RGB(red: 1, green: 1, blue: 1), CoverTint.RGB(red: 0.95, green: 0.85, blue: 0.4)] {
            for minimum in [4.5, 7.0] {
                let ground = CoverTint.background(for: pale, minimumContrast: minimum)
                #expect(CoverTint.contrastWithWhite(ground) >= minimum)
                // Just enough: barely lighter would fall short.
                #expect(CoverTint.contrastWithWhite(ground.scaled(by: 1.02)) < minimum)
                // The hue stays: the channels keep their proportions.
                #expect(abs(ground.red / max(ground.blue, 0.0001) - pale.red / pale.blue) < 0.001)
            }
        }
    }

    @Test("the kind line is the cover's hue made light, and the ground darkens until that line reads at 4.5:1 (7:1)")
    func kindLineTint() {
        let green = CoverTint.RGB(red: 0.12, green: 0.42, blue: 0.23)
        let tint = CoverTint.lightTint(for: green)
        // The cover's hue: green stays the strongest channel, and the line is light.
        #expect(tint.green > tint.red && tint.green > tint.blue)
        #expect(CoverTint.luminance(tint) > 0.3)
        // A grey cover gives a grey line, not a colour it does not have.
        let grey = CoverTint.lightTint(for: CoverTint.RGB(red: 0.5, green: 0.5, blue: 0.5))
        #expect(abs(grey.red - grey.green) < 0.001 && abs(grey.green - grey.blue) < 0.001)

        for cover in [green, CoverTint.RGB(red: 1, green: 1, blue: 1), CoverTint.RGB(red: 0.95, green: 0.85, blue: 0.4),
                      CoverTint.RGB(red: 0.02, green: 0.02, blue: 0.05)] {
            let line = CoverTint.lightTint(for: cover)
            for minimum in [4.5, 7.0] {
                let ground = CoverTint.background(for: cover, under: line, minimumContrast: minimum)
                #expect(CoverTint.contrast(line, ground) >= minimum)
                // White, lighter than the line, reads at least as well.
                #expect(CoverTint.contrastWithWhite(ground) >= minimum)
            }
        }
    }

    private func card(_ book: ReadingBook) throws -> HomeCardContent {
        let record = SourceRecord.derived(from: book, context: SourceRecordContext(bookSourceURL: { _ in nil },
                                                                                    connectionKind: { _ in nil },
                                                                                    webDAVRoot: { _ in nil }))
        let entry = CollectionEntry.item(record, WorkSummary(title: book.title, authors: [book.author], cover: nil,
                                                             blurb: nil, language: nil, contentKind: .text),
                                         .copy(book.id))
        return try #require(HomeCardContent(entry, status: { _ in nil }, shelfBooks: [book.id: book]))
    }

    @Test("a shelf copy's ••• in 繼續閱讀 offers both items; a finished copy, a store book or no actions fewer")
    func menuItems() throws {
        var book = ReadingBook(title: "宿命之環", author: "愛潛水的烏賊", contentFilename: "a.txt")
        book.currentPosition = 0.4
        let reading = try card(book)
        let actions = HomeBookActions(removeFromContinueReading: { _ in }, markFinished: { _ in })
        #expect(HomeCardMenuItem.items(for: reading, actions: actions).map(\.id) == ["removeFromContinueReading", "markFinished"])
        #expect(HomeCardMenuItem.items(for: reading, actions: HomeBookActions(markFinished: { _ in })).map(\.id)
                    == ["markFinished"])
        #expect(HomeCardMenuItem.items(for: reading, actions: nil).isEmpty)
        #expect(reading.kindAndDetail == localized("書籍") + "・" + String(format: localized("已讀 %d%%"), 40))

        book.currentPosition = 1
        #expect(HomeCardMenuItem.items(for: try card(book), actions: actions).map(\.id) == ["removeFromContinueReading"])

        let gutenberg = GutenbergBook(id: 1, title: "A", author: "B")
        let storeBook = try #require(HomeCardContent(
            .item(SourceRecord.derived(from: gutenberg), WorkSummary(title: "A", authors: ["B"], cover: nil, blurb: nil,
                                                                     language: nil, contentKind: .text), .gutenberg(gutenberg)),
            status: { _ in nil }, shelfBooks: [:]))
        #expect(HomeCardMenuItem.items(for: storeBook, actions: actions).isEmpty)
        #expect(storeBook.kindAndDetail == localized("書籍"))
    }

    @Test("從繼續閱讀移除 keeps the book out until it is opened again, and leaves its progress alone")
    func removeFromContinueReading() async throws {
        let (folder, cleanup) = try folder()
        defer { cleanup() }
        let store = BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json"))
        defer { store.waitForQueuedWrites() }
        var kept = ReadingBook(title: "留", author: "", source: "local_epub", contentFilename: "a.epub")
        kept.lastOpenedDate = Date(timeIntervalSinceNow: -200)
        var removed = ReadingBook(title: "移除", author: "", source: "local_epub", contentFilename: "b.epub")
        removed.lastOpenedDate = Date(timeIntervalSinceNow: -100)
        removed.currentPosition = 0.3
        [kept, removed].forEach { store.saveReadingBook($0) }
        #expect(try await continueReading(store) == [removed.id, kept.id])

        store.removeFromContinueReading(bookId: removed.id)
        #expect(try await continueReading(store) == [kept.id])
        #expect(store.books.first { $0.id == removed.id }?.currentPosition == 0.3)
        #expect(store.books.first { $0.id == removed.id }?.lastOpenedDate == removed.lastOpenedDate)

        store.updateLastOpened(bookId: removed.id)
        #expect(try await continueReading(store) == [removed.id, kept.id])
    }

    @Test("標記為已讀完 shows the book as finished and takes it out of 繼續閱讀")
    func markFinished() async throws {
        let (folder, cleanup) = try folder()
        defer { cleanup() }
        let store = BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json"))
        defer { store.waitForQueuedWrites() }
        var book = ReadingBook(title: "讀完", author: "", source: "local_epub", contentFilename: "a.epub")
        book.lastOpenedDate = Date(timeIntervalSinceNow: -100)
        book.currentPosition = 0.6
        store.saveReadingBook(book)

        store.markFinished(bookId: book.id)
        let marked = try #require(store.books.first { $0.id == book.id })
        #expect(BookshelfAccessibility.readingStatus(for: marked) == localized("已讀完"))
        #expect(try await continueReading(store).isEmpty)
    }

    @Test("a book never taken out of 繼續閱讀 encodes as it did before the field existed")
    func untouchedBookEncodesWithoutTheField() throws {
        var book = ReadingBook(title: "書", author: "", contentFilename: "a.txt")
        book.lastOpenedDate = Date(timeIntervalSinceReferenceDate: 100)
        let json = String(decoding: try JSONEncoder().encode(book), as: UTF8.self)
        #expect(!json.contains("continueReadingHiddenAt"))

        book.continueReadingHiddenAt = Date(timeIntervalSinceReferenceDate: 200)
        let decoded = try JSONDecoder().decode(ReadingBook.self, from: JSONEncoder().encode(book))
        #expect(decoded.continueReadingHiddenAt == book.continueReadingHiddenAt)
        #expect(!decoded.isInContinueReading)
    }
}
