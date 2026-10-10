import Combine
import Foundation
import ReadiumShared
import Testing
@testable import yuedu_app

// Unified library 2e: the OPF and cover of indexed WebDAV EPUBs, read over range requests.

enum FillFixtures {
    static let root = URL(string: "https://dav.example/books/")!
    static let cover = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 7, count: 2_000))

    /// An EPUB 3 with an ISBN, a language, a description, subjects, an author, a series and a
    /// cover; `padding` bytes of an extra stored resource make the ZIP large.
    static func epub(isbn: String = "978-7-5366-9293-0", padding: Int = 0) async throws -> Data {
        var entries: [String: Data] = [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """.utf8),
            "OPS/package.opf": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <package version="3.0" unique-identifier="bookid" xmlns="http://www.idpf.org/2007/opf">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="bookid">urn:uuid:2e-fixture</dc:identifier>
                <dc:identifier>urn:isbn:\(isbn)</dc:identifier>
                <dc:title>三體</dc:title>
                <dc:creator>劉慈欣</dc:creator>
                <dc:language>zh-Hans</dc:language>
                <dc:description>地球往事</dc:description>
                <dc:subject>科幻</dc:subject>
                <meta property="belongs-to-collection" id="series">地球往事三部曲</meta>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/>
                <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
                <item id="pad" href="padding.bin" media-type="application/octet-stream"/>
              </manifest>
              <spine><itemref idref="ch1"/></spine>
            </package>
            """.utf8),
            "OPS/nav.xhtml": Data(EPUBTestFixtures.xhtml(
                title: "Nav", body: #"<nav epub:type="toc"><ol><li><a href="chapter1.xhtml">Start</a></li></ol></nav>"#
            ).utf8),
            "OPS/chapter1.xhtml": Data(EPUBTestFixtures.xhtml(title: "三體", body: "<p>正文</p>").utf8),
            "OPS/cover.png": cover,
        ]
        var generator = SystemRandomNumberGenerator()
        entries["OPS/padding.bin"] = Data((0..<padding).map { _ in UInt8.random(in: 0...255, using: &generator) })
        return try Data(contentsOf: try await EPUBTestFixtures.makeArchive(entries: entries))
    }
}

@Suite("Remote EPUB metadata reader", .serialized)
struct RemoteEPUBMetadataReaderTests {
    @Test("the package's metadata, identifiers and cover are read over ranges, without the whole file")
    func reads() async throws {
        let data = try await FillFixtures.epub(padding: 400_000)
        let client = EPUBRangeHTTPClient(data: data)
        let package = try await PublicationSession.remotePackageMetadata(
            remoteURL: FillFixtures.root.appendingPathComponent("三體.epub"), httpClient: client, coverByteLimit: 1_000_000)

        #expect(package.metadata.languages == ["zh-Hans"])
        #expect(package.metadata.authors.map(\.name) == ["劉慈欣"])
        #expect(package.metadata.subjects.map(\.name) == ["科幻"])
        #expect(package.identifiers.contains { $0.value == "urn:isbn:978-7-5366-9293-0" })
        #expect(package.cover == FillFixtures.cover)
        #expect(package.coverMediaType == "image/png")
        #expect(client.getRequests.allSatisfy { $0.headers.keys.contains { $0.lowercased() == "range" } })
        #expect(client.uniqueBytesServed < data.count / 2, "the padding is never read: \(client.uniqueBytesServed) of \(data.count)")
    }

    @Test("a cover over the limit is skipped; a file that is not an EPUB fails")
    func limits() async throws {
        let small = try await PublicationSession.remotePackageMetadata(
            remoteURL: FillFixtures.root.appendingPathComponent("a.epub"),
            httpClient: EPUBRangeHTTPClient(data: try await FillFixtures.epub()), coverByteLimit: 100)
        #expect(small.cover == nil)
        #expect(small.metadata.languages == ["zh-Hans"])

        await #expect(throws: (any Error).self) {
            _ = try await PublicationSession.remotePackageMetadata(
                remoteURL: FillFixtures.root.appendingPathComponent("b.epub"),
                httpClient: EPUBRangeHTTPClient(data: Data(repeating: 1, count: 5_000)), coverByteLimit: 100)
        }
    }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func append(_ url: URL) { lock.withLock { urls.append(url) } }
    var all: [URL] { lock.withLock { urls } }
}

@Suite("WebDAV metadata filler", .serialized)
struct WebDAVMetadataFillerTests {
    private func file(_ name: String, values: [MetadataValue]? = nil) -> IndexedFile {
        let entry = WebDAVBrowseClient.Entry(url: FillFixtures.root.appendingPathComponent(name), name: name, isDirectory: false, size: 10, etag: "\"1\"")
        var file = IndexedFile(record: SourceRecord.derived(from: entry, connectionID: "c", root: FillFixtures.root)!,
                               etag: "\"1\"", lastModified: nil, size: 10)
        file.values = values
        return file
    }

    private func package(isbn: String = "9787536692930") async throws -> PublicationSession.RemotePackageMetadata {
        try await PublicationSession.remotePackageMetadata(
            remoteURL: FillFixtures.root.appendingPathComponent("x.epub"),
            httpClient: EPUBRangeHTTPClient(data: try await FillFixtures.epub(isbn: isbn)), coverByteLimit: 1_000_000)
    }

    private func filler(read: @escaping @Sendable (URL) async throws -> PublicationSession.RemotePackageMetadata,
                        covers: URL, saves: @escaping @Sendable (WebDAVIndexState) -> Void = { _ in }) -> WebDAVMetadataFiller {
        WebDAVMetadataFiller(connectionID: "c", limits: .init(coverByteLimit: 1_000_000, saveEvery: 2), read: read,
                             coverDirectory: covers, save: saves, now: { Date(timeIntervalSinceReferenceDate: 0) })
    }

    @Test("EPUBs are read most incomplete first; identifiers, values and the cover land on the record")
    func fills() async throws {
        let covers = FileManager.default.temporaryDirectory.appendingPathComponent("Covers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: covers) }
        let known = MetadataValue(field: .intro, value: .text("x"), provider: .localLibrary, sourceItem: nil, fetchedAt: .distantPast)
        var state = WebDAVIndexState(connectionID: "c", root: FillFixtures.root)
        state.records = [file("a.epub", values: [known]), file("b.epub"), file("c.pdf")]
        let package = try await package()
        let calls = Calls()
        let result = await filler(read: { calls.append($0); return package }, covers: covers).run(from: state, stopAfterBatch: { false })

        #expect(calls.all.map(\.lastPathComponent) == ["b.epub", "a.epub"], "fewest fields first; the PDF is not read")
        let b = try #require(result.records.first { $0.record.key.item == "b.epub" })
        #expect(b.filled == .read)
        #expect(b.identifiers?.contains(.normalized(.isbn13, "9787536692930")!) == true)
        #expect(b.values?.contains { $0.field == .language && $0.value == .texts(["zh-Hans"]) } == true)
        #expect(b.values?.contains { $0.field == .authors && $0.value == .texts(["劉慈欣"]) } == true)
        let cover = try #require(b.cover)
        #expect(try Data(contentsOf: covers.appendingPathComponent(cover)) == FillFixtures.cover)
        #expect(result.records.first { $0.record.key.item == "c.pdf" }?.filled == nil)
    }

    @Test("a book's own failure is recorded and skipped; a network failure stops and saves")
    func failures() async throws {
        let covers = FileManager.default.temporaryDirectory.appendingPathComponent("Covers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: covers) }
        var state = WebDAVIndexState(connectionID: "c", root: FillFixtures.root)
        state.records = [file("a.epub"), file("b.epub"), file("c.epub")]
        let package = try await package()
        let broken = await filler(read: { url in
            if url.lastPathComponent == "a.epub" { throw OPDSError.invalidFeed }
            return package
        }, covers: covers).run(from: state, stopAfterBatch: { false })
        #expect(broken.records[0].filled == .failed(.parse))
        #expect(broken.records[1].filled == .read && broken.records[2].filled == .read)

        let saves = Calls()
        let offline = await filler(read: { url in
            if url.lastPathComponent == "b.epub" { throw URLError(.notConnectedToInternet) }
            return package
        }, covers: covers, saves: { _ in saves.append(FillFixtures.root) }).run(from: state, stopAfterBatch: { false })
        #expect(offline.records[0].filled == .read)
        #expect(offline.records[1].filled == nil && offline.records[2].filled == nil, "stopped, to retry later")
        #expect(saves.all.count == 1)
    }

    @Test("a recrawl keeps what was read from an unchanged file and drops it for a changed one")
    func carriedAcrossCrawls() async {
        var filled = file("a.epub")
        filled.identifiers = [.normalized(.isbn13, "9787536692930")!]
        filled.filled = .read
        var state = WebDAVIndexState(connectionID: "c", root: FillFixtures.root)
        state.records = [filled, { var f = file("b.epub"); f.filled = .read; return f }()]
        let listing: @Sendable (URL) async throws -> [WebDAVBrowseClient.Entry] = { _ in [
            WebDAVBrowseClient.Entry(url: FillFixtures.root.appendingPathComponent("a.epub"), name: "a.epub", isDirectory: false, size: 10, etag: "\"1\""),
            WebDAVBrowseClient.Entry(url: FillFixtures.root.appendingPathComponent("b.epub"), name: "b.epub", isDirectory: false, size: 10, etag: "\"2\""),
        ] }
        let recrawled = await WebDAVIndexer(connectionID: "c", root: FillFixtures.root, limits: .standard, list: listing,
                                            save: { _ in }, now: { Date() }).run(from: state, stopAfterBatch: { false })
        #expect(recrawled.records.first { $0.record.key.item == "a.epub" }?.identifiers == filled.identifiers)
        #expect(recrawled.records.first { $0.record.key.item == "b.epub" }?.filled == nil, "its ETag changed")
    }
}

@MainActor
@Suite("WebDAV fill in the coordinator and the work index", .serialized)
struct WebDAVFillIntegrationTests {
    @Test("after a crawl completes, its EPUBs are read, and their ISBN joins the same book on the shelf")
    func endToEnd() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FillIntegration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json"))
        let connections = OPDSCatalogStore(storageDirectory: folder, importLegacyWebDAV: false,
                                           defaults: UserDefaults(suiteName: "fill-\(UUID().uuidString)")!)
        let dav = connections.add(name: "DAV", url: FillFixtures.root.absoluteString, username: nil, password: nil, kind: .webDAV)
        let epub = try await FillFixtures.epub()
        let network = FillNetwork()
        let coordinator = WebDAVIndexCoordinator(
            connections: connections, network: network,
            coverDirectory: folder.appendingPathComponent("covers"),
            makeLister: { _, _ in { _ in [WebDAVBrowseClient.Entry(url: FillFixtures.root.appendingPathComponent("三體.epub"),
                                                                    name: "三體.epub", isDirectory: false, size: Int64(epub.count))] } },
            makeReader: { _, _ in { url in
                try await PublicationSession.remotePackageMetadata(remoteURL: url, httpClient: EPUBRangeHTTPClient(data: epub), coverByteLimit: 1_000_000)
            } }
        )
        await coordinator.attach(store: store.remoteRecords)
        coordinator.setActive(true)
        await coordinator.waitForIdleForTesting()
        store.remoteRecords.waitForPendingWritesForTesting()
        let state = try #require(store.remoteRecords.state(connectionID: dav.id))
        #expect(state.records.first?.filled == .read)
        #expect(coordinator.statuses[dav.id] == .indexed(1))

        // A local copy of the same book, with the same ISBN in its sidecar.
        let copy = ReadingBook(title: "三体", author: "刘慈欣", source: "local_epub", contentFilename: "x.epub")
        store.saveReadingBook(copy)
        store.importedMetadata.write(ImportedMetadata(copyID: copy.id, sourceItem: .copy(copy.id),
                                                      identifiers: [.normalized(.isbn13, "9787536692930")!], values: []))
        store.importedMetadata.waitForPendingWritesForTesting()
        let service = WorkIndexService(store: store, directory: folder.appendingPathComponent("Works"), makeContext: { _ in
            SourceRecordContext(bookSourceURL: { _ in nil }, connectionKind: { _ in nil }, webDAVRoot: { _ in nil })
        }, decisions: { [] })
        #expect(await service.refresh())
        let work = try #require(service.index?.work(containing: .copy(copy.id)))
        #expect(work.members.contains(state.records[0].record.key))
        #expect(work.links.contains { $0.evidence == .identifier(.normalized(.isbn13, "9787536692930")!) })
    }
}

@MainActor
private final class FillNetwork: NetworkPathProviding {
    var allowsBackgroundWork: Bool { true }
    var allowsBackgroundWorkPublisher: AnyPublisher<Bool, Never> { Just(true).eraseToAnyPublisher() }
}
