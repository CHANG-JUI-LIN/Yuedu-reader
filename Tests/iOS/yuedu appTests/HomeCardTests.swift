import Foundation
import Testing
@testable import yuedu_app

/// Unified library 5c-2: what a home card and a section header say (settled decision 11 — the
/// title, the author, and one Emby line of status or progress). Since 5d-3b the home names no
/// source (decision 19).
@MainActor
@Suite("Explore home cards and rows", .serialized)
struct HomeCardTests {
    private func row(_ binding: HomeSectionBinding, title: String = "", source: SourceInstanceKey = .localLibrary,
                     name: String = "來源") -> HomeModel.Row {
        let section = HomeSection(layout: .row, title: title, binding: binding)
        return HomeModel.Row(id: HomeModel.rowID(section: section.id, source: source), section: section, source: source,
                             sourceName: name, policy: .local, state: .idle)
    }

    @Test("a section header is the reader's title, else its binding's, and never names a source beside it")
    func rowTitles() {
        func title(_ binding: HomeSectionBinding, title: String = "", name: String = "來源", rows: Int = 1) -> String {
            let rowList = (0..<rows).map { index in
                row(binding, title: title, source: SourceInstanceKey(type: .opds, id: "\(index)"), name: name)
            }
            let section = rowList[0].section
            let sameSection = rowList.map { HomeModel.Row(id: HomeModel.rowID(section: section.id, source: $0.source),
                                                          section: section, source: $0.source, sourceName: $0.sourceName,
                                                          policy: .local, state: .idle) }
            return HomeScopeFilter.groups(sameSection, in: nil)[0].title
        }
        #expect(title(.continueReading) == localized("繼續閱讀"))
        // 最新 is one section whatever the sources (decision 19).
        #expect(title(.latest, name: "NAS", rows: 2) == localized("最新"))
        #expect(title(.latest, name: "NAS") == localized("最新"))

        let collection = PublicLibraryCollection.all[0]
        #expect(title(.gutenbergCollection(id: collection.id), name: "Project Gutenberg") == localized(collection.titleKey))
        #expect(title(.aozoraIndex(kind: AozoraBrowseMode.authors.rawValue), name: "青空文庫")
            == localized(AozoraBrowseMode.authors.titleKey))
        // A feed is titled by its source, having no title of its own.
        #expect(title(.opdsFeed(connectionID: "c", url: "https://opds.test/new"), name: "Calibre") == "Calibre")
        #expect(title(.continueReading, title: "我的") == "我的")
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
            return try #require(HomeCardContent(entry, status: { _ in nil },
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

    @Test("a library item says its copy's status, and VoiceOver reads author and status, not the source")
    func libraryItemStatus() throws {
        let book = GutenbergBook(id: 24264, title: "紅樓夢", author: "曹雪芹")
        let entry = CollectionEntry.item(SourceRecord.derived(from: book),
                                         WorkSummary(title: book.title, authors: [book.author],
                                                     cover: .generated(seed: book.title), blurb: nil, language: nil,
                                                     contentKind: .text),
                                         .gutenberg(book))
        let onShelf = try #require(HomeCardContent(entry, status: { _ in .onShelf },
                                                   shelfBooks: [:]))
        #expect(onShelf.detail == localized("已加入書架"))
        #expect(onShelf.progress == nil)
        #expect(onShelf.accessibilityLabel == "紅樓夢")
        #expect(onShelf.accessibilityValue == "曹雪芹, \(localized("已加入書架"))")
        #expect(onShelf.publicLibraryBookID == PublicLibraryBook.gutenberg(book).id)

        let none = try #require(HomeCardContent(entry, status: { _ in nil }, shelfBooks: [:]))
        #expect(none.detail == nil)
        #expect(none.accessibilityValue == "曹雪芹")
    }

    @Test("a 趨勢 series is named under the author: beside the status on a poster card, and to VoiceOver")
    func seriesLine() throws {
        let record = SourceRecord(key: SourceItemKey(instance: ModuleProvider.instanceKey(moduleID: "trends"), item: "m"),
                                  title: "Mistborn: The Final Empire", authors: ["Brandon Sanderson"], language: "en",
                                  contentKind: .text, identifiers: [], copyID: nil, acquisitions: [.viewOnly])
        func card(series: String?, status: CopyLookup.Status?) throws -> HomeCardContent {
            let summary = WorkSummary(title: record.title, authors: record.authors, cover: nil, blurb: nil, language: "en",
                                      contentKind: .text, series: series)
            return try #require(HomeCardContent(.item(record, summary, .bibliographic), status: { _ in status }, shelfBooks: [:]))
        }
        let series = try card(series: "Mistborn", status: nil)
        #expect(series.series == "Mistborn")
        #expect(series.seriesAndDetail == "Mistborn")
        #expect(series.accessibilityValue == "Brandon Sanderson, Mistborn")
        let onShelf = try card(series: "Mistborn", status: .onShelf)
        #expect(onShelf.seriesAndDetail == "Mistborn・\(localized("已加入書架"))")
        #expect(onShelf.accessibilityValue == "Brandon Sanderson, Mistborn, \(localized("已加入書架"))")
        #expect(onShelf.kindAndDetail == "\(localized("書籍"))・Mistborn・\(localized("已加入書架"))")

        let single = try card(series: "  ", status: nil)
        #expect(single.series == nil, "a blank series is none")
        #expect(single.seriesAndDetail == nil)
    }

    @Test("a row's places become chips and its items cards, each in order")
    func rowContentSplitsLocations() {
        let book = GutenbergBook(id: 23962, title: "西遊記", author: "吳承恩")
        let item = CollectionEntry.item(SourceRecord.derived(from: book),
                                        WorkSummary(title: book.title, authors: [book.author], cover: nil, blurb: nil,
                                                    language: nil, contentKind: .text),
                                        .gutenberg(book))
        let places = [CollectionLocation(id: "a", title: "太宰 治"), CollectionLocation(id: "b", title: "夏目 漱石")]
        let content = HomeRowContent(entries: [.location(places[0]), item, .location(places[1])],
                                     status: { _ in nil }, shelfBooks: [:])
        #expect(content.locations == places)
        #expect(content.cards.map(\.title) == ["西遊記"])
        #expect(!content.isEmpty)
        #expect(HomeRowContent(entries: [], status: { _ in nil }, shelfBooks: [:]).isEmpty)
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
