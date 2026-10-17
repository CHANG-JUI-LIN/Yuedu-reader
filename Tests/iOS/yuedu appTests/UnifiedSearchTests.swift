import Foundation
import SwiftUI
import Testing
@testable import yuedu_app

/// Unified search 4c-3: 搜索's tab root as one list of works, built from every part's finds,
/// each row opening 作品詳情 with all its members as versions.
@MainActor
@Suite("Unified search list", .serialized)
struct UnifiedSearchTests {
    @Test("§16: shelf, Open Library and a source's 三体 are one row on the shelf; 三體II its own")
    func oneList() async throws {
        let (store, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = book("三體", "劉慈欣")
        store.saveReadingBook(copy)
        let shelf = try shelfMatch(copy, store: store, identifiers: [isbn("9780765382030")])
        let openLibrary = try openLibraryMatch("OL17267881W", title: "The Three-Body Problem", author: "Liu Cixin",
                                               isbn: "9780765382030", store: store)
        let source = sourceRow("三体", "刘慈欣", origins: 2)
        let sequel = sourceRow("三體II：黑暗森林", "劉慈欣", origins: 1)
        let model = UnifiedSearchModel(sourceURL: { _ in nil })

        await model.update(UnifiedSearchParts(shelf: [shelf], libraries: [openLibrary], sources: [source, sequel]),
                           query: "三體")

        #expect(model.rows.count == 2)
        let work = try #require(model.rows.first)
        #expect(work.work.availability == .onShelf)
        #expect(work.members.count == 3, "the shelf copy, the source row and Open Library (by its ISBN)")
        guard case .shelf(let lead) = work.lead else {
            Issue.record("the shelf copy leads its work")
            return
        }
        #expect(lead.book.id == copy.id)
        #expect(work.content.title == "三體")
        #expect(work.content.author == "劉慈欣")
        #expect(work.content.detail == [localized("在書架上"), String(format: localized("%d 源"), 2)].joined(separator: " · "),
                "Open Library is data, not a place to read from")
        #expect(model.rows[1].content.detail == [localized("可閱讀"), String(format: localized("%d 源"), 1)].joined(separator: " · "))
    }

    @Test("VoiceOver reads one label: title, author, how many sources, on the shelf or not")
    func voiceOverLabel() async throws {
        let model = UnifiedSearchModel(sourceURL: { _ in nil })
        await model.update(UnifiedSearchParts(sources: [sourceRow("球狀閃電", "劉慈欣", origins: 3)]), query: "球狀閃電")
        let row = try #require(model.rows.first)
        let label = row.content.accessibilityLabel
        #expect(label == ["球狀閃電", "劉慈欣", localized("可閱讀"), String(format: localized("%d 源"), 3)].joined(separator: "，"))
        #expect(!label.contains("·"), "the middle dot is for the eye; VoiceOver hears pauses")
    }

    @Test("data only: no source count, just 只有資料")
    func dataOnlyRow() async throws {
        let (store, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = UnifiedSearchModel(sourceURL: { _ in nil })
        await model.update(UnifiedSearchParts(libraries: [try openLibraryMatch("OL2W", title: "球狀閃電", author: "劉慈欣", store: store)]),
                           query: "球狀閃電")
        #expect(model.rows.first?.content.detail == localized("只有資料"))
    }

    @Test("a row keeps its id while its work grows, and a new query gives new ids")
    func stableRowIDs() async throws {
        let model = UnifiedSearchModel(sourceURL: { _ in nil })
        let first = sourceRow("三體", "劉慈欣", origins: 1)
        await model.update(UnifiedSearchParts(sources: [first]), query: "三體")
        let id = try #require(model.rows.first?.id)
        await model.update(UnifiedSearchParts(sources: [first, sourceRow("三體II", "劉慈欣", origins: 1)]), query: "三體")
        #expect(model.rows.first?.id == id)
        await model.update(UnifiedSearchParts(sources: [first]), query: "三")
        #expect(model.rows.first?.id != id)
        model.clear()
        #expect(model.rows.isEmpty)
    }

    @Test("the route opens the lead with every other member as a version, each book-source member with its origins")
    func routeCarriesMembers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UnifiedSearch-\(UUID().uuidString)")
        let (store, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        var a = BookSource()
        a.bookSourceUrl = "https://a.test"
        a.bookSourceName = "A"
        let sources = BookSourceStore(directory: directory)
        sources.replaceSourcesFromSync([a])
        let copy = book("三體", "劉慈欣")
        store.saveReadingBook(copy)
        let shelf = try shelfMatch(copy, store: store)
        let result = SearchBook(name: "三体", author: "刘慈欣", origins: [
            BookOrigin(sourceId: a.id, sourceName: "A", bookUrl: "/book/1", tocUrl: "", coverUrl: "", intro: "",
                       lastChapter: "", wordCount: "", kind: "", runtimeVariables: nil),
        ])
        let model = UnifiedSearchModel(sourceURL: { sources.source(id: $0)?.bookSourceUrl })
        await model.update(UnifiedSearchParts(shelf: [shelf], sources: [result]), query: "三體")
        let row = try #require(model.rows.first)
        #expect(model.rows.count == 1)

        let parts = try #require(row.selection.destination(sources: sources))
        #expect(parts.route.opening == .copy(copy.id))
        #expect(parts.versions.count == 1)
        let version = try #require(parts.versions.first)
        #expect(version.record.key.instance == SourceInstanceKey(type: .bookSource, id: "https://a.test"))
        #expect(parts.searchResults[version.nodeKey] === result, "換源 on that version's page keeps the row's origins")
    }

    @Test("a lead whose source is gone gives way to the next member")
    func goneSourceLead() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UnifiedSearch-\(UUID().uuidString)")
        let (store, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sources = BookSourceStore(directory: directory)
        let gone = sourceRow("球狀閃電", "劉慈欣", origins: 1)
        let data = try openLibraryMatch("OL5W", title: "球狀閃電", author: "劉慈欣", store: store)
        let selection = UnifiedSearchSelection(lead: .bookSource(gone), others: [.library(data)])
        let parts = try #require(selection.destination(sources: sources))
        #expect(parts.route.opening == .bibliographic)
        #expect(parts.versions.isEmpty)
        #expect(UnifiedSearchSelection(lead: .bookSource(gone), others: []).destination(sources: sources) == nil)
    }

    @Test("作品詳情 lists the extra members once, through the shelf's one versions path")
    func versionsTakeExtras() async throws {
        let (store, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = book("三體", "劉慈欣")
        store.saveReadingBook(copy)
        let tapped = try shelfMatch(copy, store: store).route
        let data = try openLibraryMatch("OL9W", title: "三體", author: "劉慈欣", store: store).route
        let versions = await ShelfProvider(store: store).versions(of: tapped, aozora: nil, also: [data, tapped, data])
        #expect(versions.map(\.nodeKey) == [tapped.nodeKey, data.nodeKey])
    }

    @Test("a shelf match carries the identifiers its sidecar holds, so Open Library meets it")
    func shelfMatchIdentifiers() async throws {
        let (store, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = book("三體", "劉慈欣")
        store.saveReadingBook(copy)
        let work = isbn("9780765382030")
        let record = SourceRecord.derived(from: copy, context: WorkIndexService.liveContext(for: [copy]))
        store.importedMetadata.write(ImportedMetadata(copyID: copy.id, sourceItem: record.key, identifiers: [work], values: []))
        store.importedMetadata.waitForPendingWritesForTesting()
        let model = ShelfSearchModel()
        await model.search("三體", in: store)
        let match = try #require(model.matches.first)
        #expect(match.identifiers.contains(work))
    }

    @Test("Search with no source: the others answer instead of an alert")
    func submitPlan() {
        #expect(SearchSubmitPlan.decide(hasSources: true, sourcesLoaded: true, othersAnswer: true) == .sources)
        #expect(SearchSubmitPlan.decide(hasSources: false, sourcesLoaded: true, othersAnswer: true) == .othersOnly)
        #expect(SearchSubmitPlan.decide(hasSources: false, sourcesLoaded: true, othersAnswer: false) == .sources,
                "nothing at all: the search says there is no source")
        #expect(SearchSubmitPlan.decide(hasSources: false, sourcesLoaded: false, othersAnswer: true) == .waitForSources)
    }

    @Test("status lines: one empty state once every part has answered; failures at the end")
    func statusLines() {
        let failure = LibrarySearchFailure(id: "c", name: "Calibre", reason: "離線")
        let searching = UnifiedSearchStatus(hasRows: false, isSearching: true, isPaused: false, othersSearching: false,
                                            submittedQuery: "三體", failures: [failure])
        #expect(searching.leading == localized("搜索中…"))
        #expect(searching.trailing == [failure.line])
        let none = UnifiedSearchStatus(hasRows: false, isSearching: false, isPaused: false, othersSearching: false,
                                       submittedQuery: "三體", failures: [])
        #expect(none.leading == String(format: localized("沒有找到「%@」"), "三體"))
        let typing = UnifiedSearchStatus(hasRows: false, isSearching: false, isPaused: false, othersSearching: false,
                                         submittedQuery: nil, failures: [])
        #expect(typing.leading == nil)
        let found = UnifiedSearchStatus(hasRows: true, isSearching: true, isPaused: false, othersSearching: true,
                                        submittedQuery: "三體", failures: [])
        #expect(found.leading == nil)
        #expect(found.trailing == [localized("搜索中…")], "the libraries still asking, under the rows")
    }

    @Test("the iOS 17 table reloads when the works change and keeps each row's cover request")
    func iOS17Content() async throws {
        let (store, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = book("三體", "劉慈欣")
        store.saveReadingBook(copy)
        let model = UnifiedSearchModel(sourceURL: { _ in nil })
        await model.update(UnifiedSearchParts(shelf: [try shelfMatch(copy, store: store)]), query: "三體")
        let row = try #require(model.rows.first)
        let tableRow = IOS17SearchResultTableRow(unified: row, colorScheme: .light, filledCover: { _ in "/covers/ol-1.jpg" })
        #expect(tableRow.id == row.id)
        #expect(tableRow.content == row.content)
        #expect(tableRow.shelfCover?.own == .indexedCover(path: "/covers/ol-1.jpg"))

        let empty = IOS17SearchResultTableContent(rows: [],
                                                  works: IOS17SearchWorksSection(groups: [], status: .init()))
        let filled = IOS17SearchResultTableContent(rows: [],
                                                   works: IOS17SearchWorksSection(groups: [IOS17SearchWorkGroup(kind: .text, title: "書籍", rows: [tableRow])],
                                                                                    status: .init()))
        #expect(filled.requiresReload(comparedTo: empty))
        #expect(!filled.requiresReload(comparedTo: filled))
    }

    /// Search 9c: groups by kind, as Emby's search lists 人物, 電影 and 電視劇.
    @Test("groups: 書籍, 漫畫, 有聲書 in that order, each in the resolver's order, empty ones left out")
    func groups() {
        let rows: [(String, ContentKind)] = [("聽", .audio), ("一", .text), ("畫", .comic), ("二", .text)]
        let all = UnifiedSearchGroup.groups(of: rows, kind: \.1, filter: nil)
        #expect(all.map(\.kind) == [.text, .comic, .audio])
        #expect(all.first?.rows.map(\.0) == ["一", "二"])
        let books = UnifiedSearchGroup.groups(of: rows.filter { $0.1 != .comic }, kind: \.1, filter: nil)
        #expect(books.map(\.kind) == [.text, .audio], "no 漫畫 header without a comic")
        let comics = UnifiedSearchGroup.groups(of: rows, kind: \.1, filter: .comic)
        #expect(comics.map(\.kind) == [.comic], "類型 keeps its kind's group alone")
        #expect(ContentKind.text.searchGroupTitle == localized("搜尋分組：書籍"))
    }

    @Test("類型 that leaves nothing says so instead of a blank page")
    func filteredOut() async {
        let model = UnifiedSearchModel(sourceURL: { _ in nil })
        await model.update(UnifiedSearchParts(sources: [sourceRow("三體", "劉慈欣", origins: 1)]), query: "三體")
        #expect(model.groups.map(\.kind) == [.text])
        model.kindFilter = .comic
        #expect(model.groups.isEmpty)
        #expect(model.isFilteredOut)
        let status = UnifiedSearchStatus(hasRows: !model.groups.isEmpty, isSearching: false, isPaused: false,
                                         othersSearching: false, submittedQuery: "三體", failures: [],
                                         filteredOut: model.isFilteredOut)
        #expect(status.leading == localized("沒有這個類型的作品"))
        let stillSearching = UnifiedSearchStatus(hasRows: false, isSearching: true, isPaused: false, othersSearching: false,
                                                 submittedQuery: "三體", failures: [], filteredOut: true)
        #expect(stillSearching.leading == localized("搜索中…"), "a comic may yet come")
        model.kindFilter = .text
        #expect(!model.isFilteredOut)
        model.clear()
        #expect(model.kindFilter == .text, "the choice outlasts the query")
        #expect(!model.isFilteredOut, "nothing found is not filtered out")
    }

    @Test("search navigation: a work route freezes the tapped selection")
    func workRouteFreezes() async throws {
        let model = UnifiedSearchModel(sourceURL: { _ in nil })
        await model.update(UnifiedSearchParts(sources: [sourceRow("三體", "劉慈欣", origins: 1)]), query: "三體")
        let row = try #require(model.rows.first)
        let route = UnifiedSearchResultRoute(id: row.id, snapshot: row.selection)
        await model.update(UnifiedSearchParts(sources: [sourceRow("三體", "劉慈欣", origins: 2)]), query: "三體")
        guard case .bookSource(let frozen) = route.snapshot.lead else {
            Issue.record("the source row leads")
            return
        }
        #expect(frozen.origins.count == 1, "a later publication does not reach the pushed page")
    }

    // MARK: - Helpers

    private func makeStore() throws -> (BookStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("UnifiedSearch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json")), folder)
    }

    private func book(_ title: String, _ author: String) -> ReadingBook {
        ReadingBook(title: title, author: author, source: "local", contentFilename: "\(UUID().uuidString).txt")
    }

    private func shelfMatch(_ copy: ReadingBook, store: BookStore,
                            identifiers: Set<ExternalIdentifier> = []) throws -> ShelfSearchMatch {
        let entry = try #require(ShelfProvider(store: store).items([copy]).first)
        return ShelfSearchMatch(book: copy, route: try #require(WorkDetailRoute(entry)), identifiers: identifiers)
    }

    /// A row of the Open Library module's search, as `ModuleSearch` answers it.
    private func openLibraryMatch(_ work: String, title: String, author: String, isbn: String? = nil,
                                  store: BookStore) throws -> LibrarySearchMatch {
        let files = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Assets", isDirectory: true)
        let loaded = OfficialRuleModules.load(OfficialRuleModules.files(in: files), appVersion: RuleModuleVersion.app)
        let module = try #require(loaded.first { $0.module.id == OfficialRuleModules.openLibraryID }).module
        let item = RuleListItem(name: title, author: author, bookUrl: "https://openlibrary.org/works/\(work)", coverUrl: "",
                                intro: "", wordCount: "", lastChapter: "", kind: "", isbn: isbn)
        let entry = try #require(ModuleProvider(module: module).searchEntry(item))
        let model = LibrarySearchModel(searches: [])
        model.receiveForPreview(LibrarySearchAnswer(connectionID: "module:\(module.id)", name: "Open Library",
                                                    outcome: .results, entries: [entry]), store: store)
        return try #require(model.matches.first)
    }

    private func sourceRow(_ title: String, _ author: String, origins: Int) -> SearchBook {
        SearchBook(name: title, author: author,
                   origins: (0..<origins).map { i in
                       BookOrigin(sourceId: UUID(), sourceName: "S\(i)", bookUrl: "/\(title)/\(i)", tocUrl: "", coverUrl: "",
                                  intro: "", lastChapter: "", wordCount: "", kind: "", runtimeVariables: nil)
                   })
    }

    private func isbn(_ value: String) -> ExternalIdentifier {
        ExternalIdentifier.normalized(.isbn13, value)!
    }
}
