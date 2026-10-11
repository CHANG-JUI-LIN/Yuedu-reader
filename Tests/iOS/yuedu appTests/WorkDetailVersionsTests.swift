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
        #expect(versions.map(\.nodeKey) == [newer.nodeKey, older.nodeKey, never.nodeKey, tapped.nodeKey, davFile.nodeKey])
        #expect(WorkVersions.primary(in: versions) == newer)
    }

    @Test("a tapped copy is listed once, under its own key")
    func tappedCopy() {
        let id = UUID()
        let tapped = copy(id, of: SourceItemKey(instance: Self.dav, item: "三體.epub"))
        let versions = WorkVersions.merge(tapped: tapped, copies: [(tapped, Date())], members: [tapped, file("三體.epub")])
        #expect(versions.map(\.nodeKey) == [.copy(id), SourceItemKey(instance: Self.dav, item: "三體.epub")])
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
}

/// The versions read from the shelf and the work index (`ShelfProvider.versions(of:)`).
@MainActor
@Suite("Work detail versions on the shelf", .serialized)
struct WorkDetailShelfVersionsTests {
    @Test("a Gutenberg book reaches its WebDAV file through its copy on the shelf")
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

        let provider = ShelfProvider(store: store, webDAVRoots: { [instance.id: root] })
        let tapped = WorkDetailRoute(.gutenberg(gutenberg))
        let versions = await provider.versions(of: tapped)
        #expect(versions.map(\.nodeKey) == [.copy(copy.id), tapped.nodeKey, fileRecord.key])
        guard case .copy(let opened) = WorkVersions.primary(in: versions)?.opening else {
            Issue.record("the copy on the shelf is read first")
            return
        }
        #expect(opened == copy.id)

        // Tapped as the shelf shows it, the copy finds the same work.
        let fromShelf = try #require(provider.items([copy]).first.flatMap(WorkDetailRoute.init))
        #expect(await provider.versions(of: fromShelf).map(\.nodeKey) == [.copy(copy.id), fileRecord.key])
    }
}
