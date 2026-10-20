import Foundation
import Testing
@testable import yuedu_app

/// Unified library 5f: the versions 作品詳情 lists, and which one its main button reads.
@Suite("Work detail versions")
struct WorkDetailVersionsTests {
    private static let dav = SourceInstanceKey(type: .webDAV, id: "dav")

    private func version(_ key: SourceItemKey, copy: UUID? = nil, opening: ItemOpening,
                         acquisitions: [AcquisitionOption] = [.download(format: "epub")]) -> WorkDetailRoute {
        WorkDetailRoute(record: SourceRecord(key: key, title: "三體", authors: ["劉慈欣"], language: nil, contentKind: .text,
                                             identifiers: [], copyID: copy, acquisitions: acquisitions),
                        summary: WorkSummary(title: "三體", authors: ["劉慈欣"], cover: nil, blurb: nil, language: nil,
                                             contentKind: .text),
                        opening: opening)
    }

    private func copy(_ id: UUID = UUID(), of key: SourceItemKey? = nil) -> WorkDetailRoute {
        version(key ?? .copy(id), copy: id, opening: .copy(id), acquisitions: [.openCopy(id)])
    }

    private func file(_ path: String, acquisitions: [AcquisitionOption] = [.download(format: "epub")]) -> WorkDetailRoute {
        let url = URL(string: "https://dav.test/books/\(path)")!
        return version(SourceItemKey(instance: Self.dav, item: path), opening: .webDAVFile(
            WebDAVBrowseClient.Entry(url: url, name: url.lastPathComponent, isDirectory: false, size: 1, etag: nil, lastModified: nil),
            connectionID: Self.dav.id), acquisitions: acquisitions)
    }

    @Test("shelf copies first, the one opened last leading; then the item tapped; then the work's other members, each once")
    func order() {
        let tapped = WorkDetailRoute(.gutenberg(GutenbergBook(id: 24264, title: "三體", author: "劉慈欣")))
        let older = copy(of: tapped.record.key)
        let newer = copy()
        let never = copy()
        let davFile = file("三體.epub")
        let versions = WorkVersions.merge(
            tapped: tapped,
            copies: [(older, Date(timeIntervalSinceReferenceDate: 1)), (never, nil), (newer, Date(timeIntervalSinceReferenceDate: 2))],
            members: [older, davFile, newer, davFile])
        // `older` was taken from the Gutenberg book tapped, which stands in its place.
        #expect(versions.map(\.nodeKey) == [newer.nodeKey, tapped.nodeKey, never.nodeKey, davFile.nodeKey])
        #expect(WorkVersions.primary(in: versions) == newer)
    }

    /// Decision 32: 已知的閱讀來源 are the sources the reader has read from or put on the
    /// shelf; a file the index matched by title and author, never opened, is not one.
    @Test("the work's members are only the sources the reader knows")
    func knownMembers() {
        let shelved = copy()
        let read = file("讀過.epub")
        let unread = file("沒開過.epub")
        let known = WorkVersions.known([shelved, unread, read], readFrom: { $0 == read.record.key })
        #expect(known.map(\.nodeKey) == [shelved.nodeKey, read.nodeKey])
    }

    @Test("a tapped copy of no listed item is listed once, under its own key")
    func tappedCopy() {
        let id = UUID()
        let tapped = copy(id)
        let versions = WorkVersions.merge(tapped: tapped, copies: [(tapped, Date())], members: [tapped, file("三體.epub")])
        #expect(versions.map(\.nodeKey) == [.copy(id), SourceItemKey(instance: Self.dav, item: "三體.epub")])
    }

    /// 2026-10-12: read from 青空文庫, the copy led as 「書架」 and the work's page lost its
    /// 青空文庫 details, author link and 公開日.
    @Test("a copy taken from a listed library item is that item's version, in the copy's place")
    func copyFoldsIntoItsItem() throws {
        let work = AozoraWork(id: "001234", title: "和蘭人形", yomi: "", sortYomi: "", subtitle: "",
                              kanaStyle: "", ndc: "", published: "", updated: "", card: "", text: "",
                              textUpdated: "", credits: [], source: "", sourcePublisher: "")
        let aozora = WorkDetailRoute(record: SourceRecord.derived(from: work), summary: WorkSummary(
            title: work.title, authors: [], cover: nil, blurb: nil, language: "ja", contentKind: .text), opening: .aozora(work))
        let read = copy(of: aozora.record.key)
        let older = copy()
        let versions = WorkVersions.merge(tapped: aozora,
                                          copies: [(older, Date(timeIntervalSinceReferenceDate: 1)),
                                                   (read, Date(timeIntervalSinceReferenceDate: 2))],
                                          members: [read, older])
        #expect(versions.map(\.nodeKey) == [aozora.nodeKey, older.nodeKey])
        #expect(WorkVersions.primary(in: versions) == aozora)

        // A copy of a WebDAV file the work lists, opened from the shelf, is the file's version.
        let id = UUID()
        let davFile = file("三體.epub")
        let tapped = copy(id, of: davFile.record.key)
        #expect(WorkVersions.merge(tapped: tapped, copies: [(tapped, Date())], members: [tapped, davFile])
            .map(\.nodeKey) == [davFile.nodeKey])
    }

    @Test("data only: a file the app cannot read is listed but never read, and with nothing else there is no main version")
    func dataOnly() {
        let unreadable = file("三體.azw3", acquisitions: [])
        #expect(!unreadable.isReadable)
        #expect(WorkVersions.primary(in: [unreadable]) == nil)
        let readable = file("三體.epub")
        #expect(WorkVersions.primary(in: WorkVersions.merge(tapped: unreadable, copies: [], members: [readable])) == readable)
    }

    @Test("a Gutenberg book of a bundled list has no formats until its entry is read, and still counts as readable")
    func bundledGutenberg() {
        let route = WorkDetailRoute(.gutenberg(GutenbergBook(id: 24264, title: "三體", author: "劉慈欣")))
        #expect(route.record.acquisitions.isEmpty)
        #expect(route.isReadable)
    }

    @Test("來源 shows the version picked while it is listed, else the primary one, else the first")
    func selection() {
        let unreadable = file("三體.azw3", acquisitions: [])
        let readable = file("三體.epub")
        let shelf = copy()
        let versions = [unreadable, shelf, readable]
        #expect(WorkVersions.selected(in: versions, chosen: nil) == shelf)
        #expect(WorkVersions.selected(in: versions, chosen: readable.nodeKey) == readable)
        #expect(WorkVersions.selected(in: versions, chosen: unreadable.nodeKey) == unreadable, "a data-only version can be shown")
        #expect(WorkVersions.selected(in: versions, chosen: copy().nodeKey) == shelf, "a version no longer listed")
        #expect(WorkVersions.selected(in: [unreadable], chosen: nil) == unreadable)
        #expect(WorkVersions.selected(in: [], chosen: nil) == nil)
    }

    @Test("a remote list's rows make the routes the home's rows make")
    @MainActor
    func remoteListRoutes() throws {
        let root = URL(string: "https://dav.test/books/")!
        let entry = WebDAVBrowseClient.Entry(url: root.appendingPathComponent("劉慈欣/三體.epub"), name: "三體.epub",
                                             isDirectory: false, size: 1, etag: nil, lastModified: nil)
        let fromList = try #require(WorkDetailRoute(webDAV: entry, connectionID: "dav", root: root))
        #expect(fromList.record.key == SourceItemKey(instance: Self.dav, item: "劉慈欣/三體.epub"))
        #expect(fromList.isReadable)
        let outside = WebDAVBrowseClient.Entry(url: URL(string: "https://elsewhere.test/a.epub")!, name: "a.epub",
                                               isDirectory: false, size: 1, etag: nil, lastModified: nil)
        #expect(WorkDetailRoute(webDAV: outside, connectionID: "dav", root: root) == nil)

        let catalog = OPDSCatalog(name: "Calibre", url: "https://calibre.test/opds", kind: .calibre)
        let provider = OPDSProvider(connection: catalog) { OPDSClient(kind: .calibre) }
        var book = OPDSEntry(id: "urn:calibre:7", title: "三體")
        book.acquisitions = [OPDSAcquisition(url: URL(string: "https://calibre.test/get/epub/7")!, type: "application/epub+zip",
                                             rel: "http://opds-spec.org/acquisition")]
        let opds = try #require(WorkDetailRoute(book, provider: provider))
        #expect(opds.opening == .opdsEntry(book, connectionID: catalog.id))
        #expect(opds.record.key.instance.type == .calibre)
        #expect(WorkDetailRoute(OPDSEntry(id: "urn:calibre:8", title: "沒有格式"), provider: provider) == nil)
    }

    @Test("a store book's route is the item its row makes")
    func storeRoute() {
        let book = GutenbergBook(id: 24264, title: "三體", author: "劉慈欣")
        #expect(WorkDetailRoute(.gutenberg(book)) == WorkDetailRoute(CollectionEntry.bundledGutenberg(book)))
    }

    /// Feedback #24: 換源 on a shelf copy's page rebinds that copy, so the page needs its id; a
    /// version found elsewhere has none, and its 換源 only changes the page.
    @Test("a shelf copy's page rebinds that copy on 換源; a found version's does not")
    func shelfCopySourceSwitchTarget() {
        let id = UUID()
        #expect(copy(id).shelfCopyID == id)
        #expect(file("三體.epub").shelfCopyID == nil)
        #expect(WorkDetailRoute(.gutenberg(GutenbergBook(id: 1, title: "三體", author: "劉慈欣"))).shelfCopyID == nil)
    }
}

/// The versions read from the shelf and the work index (`ShelfProvider.versions(of:)`).
@MainActor
@Suite("Work detail versions on the shelf", .serialized)
struct WorkDetailShelfVersionsTests {
    @Test("a Gutenberg book's copy on the shelf leaves out a WebDAV file never opened")
    func throughCopy() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WorkDetail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json"))
        defer {
            WorkIndexService.waitForPendingSavesForTesting()
            store.waitForQueuedWrites()
        }
        let root = URL(string: "https://dav.test/books/")!
        let instance = SourceInstanceKey(type: .webDAV, id: "dav")
        var state = WebDAVIndexState(connectionID: instance.id, root: root)
        let fileRecord = SourceRecord(key: SourceItemKey(instance: instance, item: "劉慈欣/三體.epub"), title: "三體",
                                      authors: ["劉慈欣"], language: nil, contentKind: .text, identifiers: [], copyID: nil,
                                      acquisitions: [.download(format: "epub")])
        state.records = [IndexedFile(record: fileRecord, etag: "\"1\"", lastModified: nil, size: 1)]
        store.remoteRecords.save(state)
        store.remoteRecords.waitForPendingWritesForTesting()

        let gutenberg = GutenbergBook(id: 24264, title: "三體", author: "劉慈欣")
        var copy = ReadingBook(title: "三體", author: "劉慈欣", source: "local", contentFilename: "\(UUID().uuidString).epub")
        copy.remoteSource = RemoteBookReference(connectionID: PublicLibraryID.gutenberg.rawValue, entryID: gutenberg.id,
            format: RemoteLibraryFormat(url: URL(string: "https://www.gutenberg.org/ebooks/24264.epub3.images")!,
                                        fileExtension: "epub", mimeType: "application/epub+zip"))
        store.saveReadingBook(copy)
        let unrelated = ReadingBook(title: "球狀閃電", author: "劉慈欣", source: "local_epub", contentFilename: "b.epub")
        store.saveReadingBook(unrelated)

        let provider = ShelfProvider(store: store, webDAVRoots: { [instance.id: root] },
                                     candidates: ForYouCandidateStore(directory: folder.appendingPathComponent("ForYou")), sources: { [] })
        let tapped = WorkDetailRoute(.gutenberg(gutenberg))
        let versions = await provider.versions(of: tapped, aozora: nil)
        // The copy was taken from the Gutenberg book, whose page reads it. The WebDAV file the
        // index matched by title and author was never opened, so it is not a known source.
        #expect(versions.map(\.nodeKey) == [tapped.nodeKey])
        #expect(WorkVersions.primary(in: versions) == tapped)

        // Tapped as the shelf shows it, the copy finds the same work, and the Gutenberg book
        // stands for it there too (2026-10-12: opened from 書架, the copy led as 「書架」).
        let fromShelf = try #require(provider.items([copy]).first.flatMap(WorkDetailRoute.init))
        let shelfVersions = await provider.versions(of: fromShelf, aozora: nil)
        #expect(shelfVersions.map(\.nodeKey) == [tapped.nodeKey])
        guard case .gutenberg(let book) = shelfVersions.first?.opening else {
            Issue.record("the Gutenberg book leads: \(shelfVersions)")
            return
        }
        #expect(book.id == gutenberg.id)
    }

    /// 2026-10-12 (maintainer's screenshot): ホノルル opened from 書架 showed only 來源 書架. The
    /// copy's key names its 青空文庫 work, which no work index lists; the catalog has it.
    @Test("a 青空文庫 copy opened from the shelf is shown as its work")
    func aozoraCopyFromShelf() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WorkDetail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json"))
        defer {
            WorkIndexService.waitForPendingSavesForTesting()
            store.waitForQueuedWrites()
        }
        let person = AozoraPerson(id: "001569", name: "中谷 宇吉郎", yomi: "", sortYomi: "", born: "", died: "")
        let work = AozoraWork(id: "061517", title: "ホノルル", yomi: "ホノルル", sortYomi: "ほのるる", subtitle: "", kanaStyle: "",
                              ndc: "", published: "", updated: "", card: "", text: "", textUpdated: "",
                              credits: [.init(person: person.id, role: "著者")], source: "百日物語", sourcePublisher: "文藝春秋新社")
        let index = AozoraCatalogIndex(catalog: AozoraCatalog(schemaVersion: 1, persons: [person], works: [work]))
        var copy = ReadingBook(title: "ホノルル", author: "中谷宇吉郎", source: "local", contentFilename: "\(UUID().uuidString).epub")
        copy.aozora = AozoraBookSource(originalFilename: "61517.zip", sourceEncoding: 0, catalogWorkID: work.id)
        store.saveReadingBook(copy)

        let provider = ShelfProvider(store: store, candidates: ForYouCandidateStore(directory: folder.appendingPathComponent("ForYou")),
                                     sources: { [] })
        let fromShelf = try #require(provider.items([copy]).first.flatMap(WorkDetailRoute.init))
        let versions = await provider.versions(of: fromShelf, aozora: index)
        guard versions.count == 1, case .aozora(let shown) = versions[0].opening else {
            Issue.record("the work stands for its copy: \(versions)")
            return
        }
        #expect(shown.id == work.id)

        // Without the catalog (not read yet, or offline with no cache) the copy is all there is.
        #expect(await provider.versions(of: fromShelf, aozora: nil).map(\.nodeKey) == [.copy(copy.id)])
    }

    /// 7b-1 (maintainer, 2026-10-13): what the reader's sources listed on the home, and
    /// 青空文庫's catalog, join the versions with no request.
    @Test("the work's books in the candidate cache and 青空文庫's catalog join, after the tapped item")
    func offers() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WorkDetail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json"))
        defer {
            WorkIndexService.waitForPendingSavesForTesting()
            store.waitForQueuedWrites()
        }
        let a = BookSource(bookSourceUrl: "https://a.example", bookSourceName: "甲")
        let b = BookSource(bookSourceUrl: "https://b.example", bookSourceName: "乙")
        var off = BookSource(bookSourceUrl: "https://off.example", bookSourceName: "關")
        off.enabled = false
        func book(_ name: String, in source: BookSource) -> OnlineBook {
            OnlineBook(name: name, author: "劉慈欣", intro: "", coverUrl: "", bookUrl: "\(source.bookSourceUrl)/\(name)", tocUrl: "",
                       wordCount: "", lastChapter: "", kind: "", sourceId: UUID(), sourceName: source.bookSourceName)
        }
        let candidates = ForYouCandidateStore(directory: folder.appendingPathComponent("ForYou"))
        for source in [b, off] {
            await candidates.write(ForYouCandidates(sourceURL: source.bookSourceUrl, categoryURL: "\(source.bookSourceUrl)/rank",
                                                    fetchedAt: Date(), books: [book("球狀閃電", in: source), book("三體", in: source)]))
        }
        let provider = ShelfProvider(store: store, candidates: candidates, sources: { [a, b, off] })
        let tapped = try #require(WorkDetailRoute(.onlineBook(book("三體", in: a), source: a)))
        let index = SeriesCardsTests.catalog(titles: ["三體"])
        let versions = await provider.versions(of: tapped, aozora: index)
        let work = try #require(index.worksByID["1"])
        #expect(versions.map(\.nodeKey) == [tapped.nodeKey, SourceRecord.derived(from: work).key,
                                             SourceItemKey(instance: SourceInstanceKey(type: .bookSource, id: b.bookSourceUrl),
                                                           item: OnlineBookURLKey.normalize("https://b.example/三體"))])
        guard case .onlineBook(let offered) = versions.last?.opening else {
            Issue.record("b's book is a book-source version: \(versions)")
            return
        }
        #expect(offered.book.sourceId == b.id, "opens through the installed source")
    }

    /// 7b-1's cost, measured: a full cache (40 categories of 40 books, 20 sources) read and matched.
    @Test("measure: versions with a full candidate cache")
    func offersLargeCache() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WorkDetail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json"))
        defer {
            WorkIndexService.waitForPendingSavesForTesting()
            store.waitForQueuedWrites()
        }
        let sources = (0..<20).map { BookSource(bookSourceUrl: "https://s\($0).example", bookSourceName: "源\($0)") }
        let candidates = ForYouCandidateStore(directory: folder.appendingPathComponent("ForYou"))
        for category in 0..<40 {
            let source = sources[category % sources.count]
            let books = (0..<40).map { n in
                OnlineBook(name: n == 7 ? "三體" : "候選書第\(category)之\(n)本", author: n == 7 ? "劉慈欣" : "作者\(n)", intro: "",
                           coverUrl: "", bookUrl: "\(source.bookSourceUrl)/\(category)/\(n)", tocUrl: "", wordCount: "",
                           lastChapter: "", kind: "", sourceId: UUID(), sourceName: source.bookSourceName)
            }
            await candidates.write(ForYouCandidates(sourceURL: source.bookSourceUrl, categoryURL: "\(source.bookSourceUrl)/\(category)",
                                                    fetchedAt: Date(), books: books))
        }
        let provider = ShelfProvider(store: store, candidates: candidates, sources: { sources })
        let tapped = WorkDetailRoute(.gutenberg(GutenbergBook(id: 1, title: "三體", author: "劉慈欣")))
        var versions: [WorkDetailRoute] = []
        for run in 0..<3 {
            let started = SourcePerfTrace.now
            versions = await provider.versions(of: tapped, aozora: nil)
            print("⏱ works.measure versions(1600 cached) run \(run): \(String(format: "%.1f", (SourcePerfTrace.now - started) * 1000))ms")
        }
        #expect(versions.count == 1 + sources.count, "one per source")
    }
}
