import Foundation
import Testing
@testable import yuedu_app

/// Unified library 5c-2: what a home card and a row header say (settled decision 11 — the
/// title, the author, and one Emby line of status or progress; the header names its source).
@MainActor
@Suite("Explore home cards and rows", .serialized)
struct HomeCardTests {
    private func row(_ binding: HomeSectionBinding, title: String = "", source: SourceInstanceKey = .localLibrary,
                     name: String = "來源") -> HomeModel.Row {
        let section = HomeSection(layout: .row, title: title, binding: binding)
        return HomeModel.Row(id: HomeModel.rowID(section: section.id, source: source), section: section, source: source,
                             sourceName: name, policy: .local, state: .idle)
    }

    @Test("a row header is the reader's title, else its binding's, with the source under it")
    func rowTitles() {
        let continueReading = row(.continueReading)
        #expect(continueReading.title == localized("繼續閱讀"))
        #expect(continueReading.subtitle == nil)

        let latest = row(.latest(excluded: []), name: "NAS")
        #expect(latest.title == String(format: localized("%@・最新"), "NAS"))
        #expect(latest.subtitle == nil)

        let collection = PublicLibraryCollection.all[0]
        let featured = row(.gutenbergCollection(id: collection.id), name: "Project Gutenberg")
        #expect(featured.title == localized(collection.titleKey))
        #expect(featured.subtitle == "Project Gutenberg")

        let authors = row(.aozoraIndex(kind: AozoraBrowseMode.authors.rawValue), name: "青空文庫")
        #expect(authors.title == localized(AozoraBrowseMode.authors.titleKey))

        // A feed's title is its source; the source is not said twice.
        let feed = row(.opdsFeed(connectionID: "c", url: "https://opds.test/new"), name: "Calibre")
        #expect(feed.title == "Calibre")
        #expect(feed.subtitle == nil)

        #expect(row(.continueReading, title: "我的").title == "我的")
    }

    @Test("a shelf copy shows how far it is read, and a bar only while it is part read")
    func shelfCopyProgress() throws {
        func card(at position: Double) throws -> HomeCardContent {
            var book = ReadingBook(title: "宿命之環", author: "愛潛水的烏賊", contentFilename: "a.txt")
            book.currentPosition = position
            let record = SourceRecord.derived(from: book, context: SourceRecordContext(bookSourceURL: { _ in nil },
                                                                                        connectionKind: { _ in nil },
                                                                                        webDAVRoot: { _ in nil }))
            let entry = CollectionEntry.item(record, WorkSummary(title: book.title, authors: [book.author], cover: nil,
                                                                 blurb: nil, language: nil, contentKind: .text),
                                             .copy(book.id))
            return try #require(HomeCardContent(entry, sourceName: "書架", status: { _ in nil },
                                                shelfBooks: [book.id: book]))
        }
        let reading = try card(at: 0.32)
        #expect(reading.detail == String(format: localized("已讀 %d%%"), 32))
        #expect(reading.progress == 0.32)
        if case .shelf = reading.cover {} else { Issue.record("a copy is drawn as the shelf draws it") }

        let finished = try card(at: 1)
        #expect(finished.detail == localized("已讀完"))
        #expect(finished.progress == nil)
        // Never opened: the shelf's 新增, not 「已讀 0%」.
        let new = try card(at: 0)
        #expect(new.detail == localized("新增"))
        #expect(new.progress == nil)
        #expect(new.detail == BookshelfAccessibility.readingStatus(for: ReadingBook(title: "x", contentFilename: "x.txt")))
    }

    @Test("a library item says its copy's status, and VoiceOver reads author, source and status")
    func libraryItemStatus() throws {
        let book = GutenbergBook(id: 24264, title: "紅樓夢", author: "曹雪芹")
        let entry = CollectionEntry.item(SourceRecord.derived(from: book),
                                         WorkSummary(title: book.title, authors: [book.author],
                                                     cover: .generated(seed: book.title), blurb: nil, language: nil,
                                                     contentKind: .text),
                                         .gutenberg(book))
        let onShelf = try #require(HomeCardContent(entry, sourceName: "Project Gutenberg", status: { _ in .onShelf },
                                                   shelfBooks: [:]))
        #expect(onShelf.detail == localized("已加入書架"))
        #expect(onShelf.progress == nil)
        #expect(onShelf.accessibilityLabel == "紅樓夢")
        #expect(onShelf.accessibilityValue == "曹雪芹, Project Gutenberg, \(localized("已加入書架"))")
        #expect(onShelf.publicLibraryBookID == PublicLibraryBook.gutenberg(book).id)

        let none = try #require(HomeCardContent(entry, sourceName: "Project Gutenberg", status: { _ in nil }, shelfBooks: [:]))
        #expect(none.detail == nil)
        #expect(none.accessibilityValue == "曹雪芹, Project Gutenberg")
    }

    @Test("a row's places become chips and its items cards, each in order")
    func rowContentSplitsLocations() {
        let book = GutenbergBook(id: 23962, title: "西遊記", author: "吳承恩")
        let item = CollectionEntry.item(SourceRecord.derived(from: book),
                                        WorkSummary(title: book.title, authors: [book.author], cover: nil, blurb: nil,
                                                    language: nil, contentKind: .text),
                                        .gutenberg(book))
        let places = [CollectionLocation(id: "a", title: "太宰 治"), CollectionLocation(id: "b", title: "夏目 漱石")]
        let content = HomeRowContent(entries: [.location(places[0]), item, .location(places[1])], sourceName: "x",
                                     status: { _ in nil }, shelfBooks: [:])
        #expect(content.locations == places)
        #expect(content.cards.map(\.title) == ["西遊記"])
        #expect(!content.isEmpty)
        #expect(HomeRowContent(entries: [], sourceName: "x", status: { _ in nil }, shelfBooks: [:]).isEmpty)
    }

    @Test("a shelf copy's cover file is named by its absolute path, read through the cover pipeline")
    func shelfCoverIsAbsolute() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HomeCard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json"))
        defer { store.waitForQueuedWrites() }
        var book = ReadingBook(title: "有封面", author: "", source: "local_epub", contentFilename: "a.epub")
        book.coverImagePath = "a_cover.jpg"
        let entries = ShelfProvider(store: store).items([book])
        guard case .item(_, let summary, _) = try #require(entries.first) else {
            Issue.record("a book is an item")
            return
        }
        #expect(summary.cover == .copyFile(StorageLocations.coverFileLocation("a_cover.jpg").path))
    }
}
