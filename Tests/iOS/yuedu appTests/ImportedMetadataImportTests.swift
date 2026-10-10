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

    // MARK: - Helpers

    private func hash(_ book: ReadingBook) -> String {
        ICloudSyncManager.stableHash(book.strippedForSync())
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("imported-1b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeEPUB() async throws -> URL {
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
            <package version="3.0" unique-identifier="bookid" xmlns="http://www.idpf.org/2007/opf">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="bookid">urn:uuid:1B-FIXTURE</dc:identifier>
                <dc:identifier>urn:isbn:978-7-5366-9293-0</dc:identifier>
                <dc:title>三體</dc:title>
                <dc:creator>劉慈欣</dc:creator>
                <dc:language>zh-Hans</dc:language>
                <dc:description>地球往事</dc:description>
                <dc:subject>科幻</dc:subject>
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
