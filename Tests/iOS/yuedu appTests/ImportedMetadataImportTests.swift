import Foundation
import Testing
@testable import yuedu_app

/// Unified library 1b: importing an EPUB leaves a sidecar and leaves `ReadingBook` exactly as
/// it was. iCloud detects edits by `stableHash(strippedForSync())`; a changed encoding would
/// make every book look edited "now" and overwrite newer copies elsewhere (design D1).
@MainActor
@Suite("Imported metadata at import", .serialized)
struct ImportedMetadataImportTests {
    /// `ReadingBook.CodingKeys` as of `main` at 346327dd. A new key in an imported book's
    /// encoding means a field was added to every book's sync record.
    private static let goldenKeys: Set<String> = [
        "id", "title", "author", "source", "contentFilename", "contentPipelineKind", "currentPosition", "addedDate",
        "isOnline", "bookSourceId", "bookInfoURL", "tocURL", "runtimeVariables", "coverUrl", "hasNewChapterUpdate", "bookmarks",
        "totalChapterNum", "latestChapterTitle",
        "coverImagePath", "customCoverUrl", "originalCoverImagePath",
        "rendererPreference", "compatibilityState",
        "offlineDownloadState", "downloadedChapterCount", "offlineDownloadTask", "group", "lastOpenedDate",
        "isInBookshelf", "remoteSource",
        "mangaChapterIndex", "mangaPage",
        "audioChapterIndex", "audioTimeSeconds",
        "audioPlayMode", "audioOpenCreditsSeconds", "audioCloseCreditsSeconds",
        "aozora",
    ]

    @Test("an imported EPUB keeps its encoding and hash, and its OPF goes to the sidecar")
    func importKeepsTheBookAndWritesTheSidecar() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shelf = directory.appendingPathComponent("books_meta.json")
        let store = BookStore(metadataFileURL: shelf)
        let epub = try await makeEPUB()

        let book = try await store.importEpub(url: epub)
        defer { store.delete(bookId: book.id) }
        store.flushPendingMetadataSave()
        store.waitForQueuedWrites()
        store.importedMetadata.waitForPendingWritesForTesting()

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(book)) as? [String: Any]
        let keys = Set(encoded?.keys.map { $0 } ?? [])
        #expect(keys.isSubset(of: Self.goldenKeys), "new keys: \(keys.subtracting(Self.goldenKeys))")

        let reloaded = try #require(BookStore(metadataFileURL: shelf).readingBooks.first { $0.id == book.id })
        #expect(hash(reloaded) == hash(book))

        let sidecar = try #require(store.importedMetadata.read(copyID: book.id))
        #expect(sidecar.sourceItem == .copy(book.id))
        #expect(Set(sidecar.identifiers) == [
            .normalized(.isbn13, "9787536692930")!,
            .normalized(.epubUniqueIdentifier, "1b-fixture")!,
        ])
        #expect(sidecar.values.contains { $0.field == .language && $0.value == .texts(["zh-Hans"]) })
        #expect(sidecar.values.contains { $0.field == .intro && $0.value == .text("地球往事") })
        #expect(sidecar.values.contains { $0.field == .tags && $0.value == .texts(["科幻"]) })
        // 系列下一本 (5d-6b): the series and the book's number in it.
        #expect(sidecar.values.contains { $0.field == .series && $0.value == .text("地球往事") })
        #expect(sidecar.values.contains { $0.field == .seriesIndex && $0.value == .number(1) })
    }

    @Test("deleting a copy removes its sidecar")
    func deleteRemovesTheSidecar() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))
        let book = try await store.importEpub(url: try await makeEPUB())
        store.importedMetadata.waitForPendingWritesForTesting()
        #expect(store.importedMetadata.read(copyID: book.id) != nil)

        store.delete(bookId: book.id)
        store.importedMetadata.waitForPendingWritesForTesting()

        #expect(store.importedMetadata.read(copyID: book.id) == nil)
    }

    @Test("a complete load removes sidecars of copies that no longer exist")
    func completeLoadRemovesOrphans() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shelf = directory.appendingPathComponent("books_meta.json")
        let orphan = UUID()
        let orphanStore = ImportedMetadataStore(besideShelfFile: shelf)
        let key = SourceItemKey.copy(orphan)
        orphanStore.write(ImportedMetadata(copyID: orphan, sourceItem: key, identifiers: [.normalized(.isbn13, "9787536692930")!], values: []))
        orphanStore.waitForPendingWritesForTesting()

        let store = BookStore(metadataFileURL: shelf)
        store.importedMetadata.waitForPendingWritesForTesting()

        #expect(store.importedMetadata.read(copyID: orphan) == nil)
    }

    @Test("a shelf file that does not decode removes no sidecar")
    func undecodableShelfKeepsSidecars() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shelf = directory.appendingPathComponent("books_meta.json")
        try Data("{ not a shelf".utf8).write(to: shelf)
        let copy = UUID()
        let sidecars = ImportedMetadataStore(besideShelfFile: shelf)
        sidecars.write(ImportedMetadata(copyID: copy, sourceItem: .copy(copy), identifiers: [.normalized(.isbn13, "9787536692930")!], values: []))
        sidecars.waitForPendingWritesForTesting()

        let store = BookStore(metadataFileURL: shelf)
        store.importedMetadata.waitForPendingWritesForTesting()

        #expect(store.readingBooks.isEmpty)
        #expect(store.importedMetadata.read(copyID: copy) != nil, "an empty shelf that failed to load is not a shelf without books")
    }

    @Test("an existing EPUB copy gets its sidecar only when asked")
    func captureIfMissing() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))
        let book = try await store.importEpub(url: try await makeEPUB())
        defer { store.delete(bookId: book.id) }
        store.importedMetadata.waitForPendingWritesForTesting()
        store.importedMetadata.remove(copyID: book.id)
        store.importedMetadata.waitForPendingWritesForTesting()
        #expect(store.importedMetadata.read(copyID: book.id) == nil, "as if imported before 1b")

        await ImportedMetadataCapture.captureIfMissing(copy: book, store: store)
        store.importedMetadata.waitForPendingWritesForTesting()

        #expect(store.importedMetadata.read(copyID: book.id)?.identifiers.contains(.normalized(.isbn13, "9787536692930")!) == true)
    }

    /// Unified library 5d-6b (decision 25): a copy imported before series were read gets its
    /// series and number from one pass over the shelf, which runs once.
    @Test("the series pass reads a copy's number into its sidecar, keeps the rest, and runs once")
    func seriesPassRunsOnce() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))
        let book = try await store.importEpub(url: try await makeEPUB())
        defer { store.delete(bookId: book.id) }
        store.importedMetadata.waitForPendingWritesForTesting()
        // As imported before 5d-6b: the same sidecar without the series.
        let imported = try #require(store.importedMetadata.read(copyID: book.id))
        store.importedMetadata.remove(copyID: book.id)
        var old = imported
        old.values.removeAll { $0.field == .series || $0.field == .seriesIndex }
        old.values.append(MetadataValue(field: .publisher, value: .text("另一處"), provider: SourceInstanceKey(type: .calibre, id: "c"),
                                        sourceItem: nil, fetchedAt: Date()))
        store.importedMetadata.write(old)
        store.importedMetadata.waitForPendingWritesForTesting()

        let works = directory.appendingPathComponent("Works", isDirectory: true)
        let pass = SeriesNumberBackfill(store: store, worksDirectory: works)
        #expect(!pass.isDone)
        await pass.runOnce()
        store.importedMetadata.waitForPendingWritesForTesting()
        #expect(pass.isDone)
        let sidecar = try #require(store.importedMetadata.read(copyID: book.id))
        #expect(sidecar.values.contains { $0.field == .series && $0.value == .text("地球往事") })
        #expect(sidecar.values.contains { $0.field == .seriesIndex && $0.value == .number(1) })
        #expect(sidecar.values.contains { $0.field == .publisher && $0.value == .text("另一處") }, "another place's values stay")

        var reread = 0
        let again = SeriesNumberBackfill(store: store, worksDirectory: works) { _ in reread += 1; return true }
        await again.runOnce()
        #expect(reread == 0, "done is kept beside the shelf")
    }

    @Test("a Calibre EPUB 2's calibre:series and series_index are read")
    func calibreSeries() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))
        let book = try await store.importEpub(url: try await makeEPUB(version: "2.0", series: """
            <meta name="calibre:series" content="基地"/>
            <meta name="calibre:series_index" content="2.5"/>
            """))
        defer { store.delete(bookId: book.id) }
        store.importedMetadata.waitForPendingWritesForTesting()
        let sidecar = try #require(store.importedMetadata.read(copyID: book.id))
        #expect(sidecar.values.contains { $0.field == .series && $0.value == .text("基地") })
        #expect(sidecar.values.contains { $0.field == .seriesIndex && $0.value == .number(2.5) })
    }

    /// A sidecar does not sync: a local EPUB that came from another device is read when its file
    /// arrives (`ICloudSyncManager.readArrivedPackages`).
    @Test("the copies read after an iCloud download are the local EPUBs whose file arrived")
    func arrivedCopies() {
        let epub = ReadingBook(title: "三體", author: "劉慈欣", source: "local_epub", contentFilename: "\(UUID()).epub")
        let other = ReadingBook(title: "黑暗森林", author: "劉慈欣", source: "local_epub", contentFilename: "\(UUID()).epub")
        let text = ReadingBook(title: "文字", author: "某", source: "local_txt", contentFilename: "\(UUID()).txt")
        let fetched = [epub, text].map { StorageLocations.bookFile($0.contentFilename) }
            + [StorageLocations.coverFile("cover.jpg")]
        #expect(ICloudSyncManager.localEPUBs(arrivedAt: fetched, of: [epub, other, text]).map(\.id) == [epub.id])
    }

    @Test("callers during the pass wait for it; it reads only local EPUB copies, and a failed one does not stop it")
    func seriesPassSingleFlight() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))
        defer { store.waitForQueuedWrites() }
        let local = [UUID(), UUID()].map {
            ReadingBook(title: "書\($0)", author: "某", source: "local_epub", contentFilename: "\($0).epub")
        }
        let text = ReadingBook(title: "文字", author: "某", source: "local_txt", contentFilename: "\(UUID()).txt")
        (local + [text]).forEach { store.saveReadingBook($0) }
        var read: [UUID] = []
        let pass = SeriesNumberBackfill(store: store, worksDirectory: directory.appendingPathComponent("Works")) { copy in
            read.append(copy.id)
            return copy.id != local[0].id
        }
        async let first: Void = pass.runOnce()
        async let second: Void = pass.runOnce()
        _ = await (first, second)
        #expect(Set(read) == Set(local.map(\.id)))
        #expect(read.count == 2, "one pass for both callers")
        #expect(pass.isDone)
    }

    // MARK: - Helpers

    private func hash(_ book: ReadingBook) -> String {
        ICloudSyncManager.stableHash(book.strippedForSync())
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("imported-1b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeEPUB(version: String = "3.0", series: String = """
        <meta property="belongs-to-collection" id="series">地球往事</meta>
        <meta refines="#series" property="collection-type">series</meta>
        <meta refines="#series" property="group-position">1</meta>
        """) async throws -> URL {
        try await EPUBTestFixtures.makeArchive(entries: [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """.utf8),
            "OPS/package.opf": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <package version="\(version)" unique-identifier="bookid" xmlns="http://www.idpf.org/2007/opf">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="bookid">urn:uuid:1B-FIXTURE</dc:identifier>
                <dc:identifier>urn:isbn:978-7-5366-9293-0</dc:identifier>
                <dc:title>三體</dc:title>
                <dc:creator>劉慈欣</dc:creator>
                <dc:language>zh-Hans</dc:language>
                <dc:description>地球往事</dc:description>
                <dc:subject>科幻</dc:subject>
                \(series)
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="ch1"/></spine>
            </package>
            """.utf8),
            "OPS/nav.xhtml": Data(EPUBTestFixtures.xhtml(
                title: "Nav", body: #"<nav epub:type="toc"><ol><li><a href="chapter1.xhtml">Start</a></li></ol></nav>"#
            ).utf8),
            "OPS/chapter1.xhtml": Data(EPUBTestFixtures.xhtml(title: "三體", body: "<p>正文</p>").utf8),
        ])
    }
}
