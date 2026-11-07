import Foundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("Cache management service", .serialized)
struct CacheManagementServiceTests {
    @Test("snapshot counts regular files in every managed cache root")
    @MainActor
    func snapshotCountsFiles() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }

        try Data(repeating: 1, count: 3).write(
            to: fixture.roots.chapters.appendingPathComponent("chapter.txt")
        )
        try Data(repeating: 2, count: 5).write(
            to: fixture.roots.ttsAudio.appendingPathComponent("chunk.audio")
        )
        try Data(repeating: 3, count: 7).write(
            to: fixture.roots.mangaImages.appendingPathComponent("page.jpg")
        )
        try Data(repeating: 4, count: 11).write(
            to: fixture.roots.covers.appendingPathComponent("cover.jpg")
        )

        let snapshot = await service(fixture).snapshot()

        #expect(snapshot.chapters == 3)
        #expect(snapshot.ttsAudio == 5)
        #expect(snapshot.mangaImages == 7)
        #expect(snapshot.covers == 11)
        #expect(snapshot.total == 26)
    }

    @Test("clearing one category leaves the other cache roots intact")
    @MainActor
    func clearOneCategory() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }

        let chapter = fixture.roots.chapters.appendingPathComponent("chapter.txt")
        let cover = fixture.roots.covers.appendingPathComponent("cover.jpg")
        try Data("chapter".utf8).write(to: chapter)
        try Data("cover".utf8).write(to: cover)

        try await service(fixture).clear(.chapters)

        #expect(!FileManager.default.fileExists(atPath: chapter.path))
        #expect(FileManager.default.fileExists(atPath: cover.path))
        #expect(FileManager.default.fileExists(atPath: fixture.roots.chapters.path))
    }

    @Test("clearing all caches removes files but preserves cache roots")
    @MainActor
    func clearAllCaches() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }

        for (index, category) in CacheCategory.allCases.enumerated() {
            let file = fixture.roots[category].appendingPathComponent("(index).cache")
            try Data(repeating: UInt8(index), count: index + 1).write(to: file)
        }

        try await service(fixture).clearAll()
        let snapshot = await service(fixture).snapshot()

        #expect(snapshot.total == 0)
        for category in CacheCategory.allCases {
            #expect(FileManager.default.fileExists(atPath: fixture.roots[category].path))
        }
    }

    @Test("探索首頁快取 counts and clears both the book-source pages and the feed rows")
    @MainActor
    func exploreHomeCoversBothStores() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let page = fixture.roots.exploreHome.appendingPathComponent("page.json")
        let row = fixture.roots.homeFeeds.appendingPathComponent("row.json")
        let chapter = fixture.roots.chapters.appendingPathComponent("chapter.txt")
        try Data(repeating: 1, count: 3).write(to: page)
        try Data(repeating: 2, count: 5).write(to: row)
        try Data(repeating: 3, count: 7).write(to: chapter)
        let caches = service(fixture)

        #expect(await caches.snapshot().exploreHome == 8)
        try await caches.clear(.exploreHome)

        #expect(!FileManager.default.fileExists(atPath: page.path))
        #expect(!FileManager.default.fileExists(atPath: row.path))
        #expect(FileManager.default.fileExists(atPath: chapter.path))
        #expect(await caches.snapshot().exploreHome == 0)
    }

    @Test("remote cleanup preserves active books, explicit offline files and reading metadata")
    @MainActor
    func remoteCleanupKeepsActiveReading() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let cache = RemoteLibraryCache(root: fixture.roots.remoteBooks)
        let activeID = UUID()
        let inactiveID = UUID()
        let active = try cache.directory(bookID: activeID, version: "v1").appendingPathComponent("chapter.range")
        let inactive = try cache.directory(bookID: inactiveID, version: "v1").appendingPathComponent("chapter.range")
        let offline = fixture.container.appendingPathComponent("saved.epub")
        let progress = fixture.container.appendingPathComponent("books_meta.reading.json")
        try Data(repeating: 1, count: 13).write(to: active)
        try Data(repeating: 2, count: 17).write(to: inactive)
        try Data("owned book".utf8).write(to: offline)
        try Data("reading progress".utf8).write(to: progress)
        cache.retain(activeID)
        let service = CacheManagementService(
            coverOwner: SavedCoverOwnerStub(),
            roots: fixture.roots,
            diagnosticLog: nil,
            remoteLibraryCache: cache
        )
        #expect(await service.snapshot().remoteBooks == 30)
        try await service.clear(.remoteBooks)
        #expect(FileManager.default.fileExists(atPath: active.path))
        #expect(!FileManager.default.fileExists(atPath: inactive.path))
        #expect(await service.snapshot().remoteBooks == 13)
        #expect(FileManager.default.fileExists(atPath: offline.path))
        #expect(FileManager.default.fileExists(atPath: progress.path))
        cache.release(activeID)
        try await service.clear(.remoteBooks)
        #expect(await service.snapshot().remoteBooks == 0)
        #expect(FileManager.default.fileExists(atPath: offline.path))
        #expect(FileManager.default.fileExists(atPath: progress.path))
    }

    // MARK: - Covers (feedback #116)

    @Test("clearing covers keeps the ones no download brings back, then tells the books")
    @MainActor
    func clearingCoversKeepsIrreplaceableOnes() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let covers = fixture.roots.covers
        let imported = covers.appendingPathComponent("imported_cover.jpg")
        let original = covers.appendingPathComponent("original_cover.jpg")
        let downloaded = covers.appendingPathComponent("downloaded_cover.jpg")
        let orphan = covers.appendingPathComponent("orphan_cover.jpg")
        let network = fixture.roots.networkCovers.appendingPathComponent("network.cover")
        for (file, size) in [(imported, 2), (original, 3), (downloaded, 5), (orphan, 7), (network, 11)] {
            try Data(repeating: 1, count: size).write(to: file)
        }
        let owner = SavedCoverOwnerStub(
            irreplaceable: ["imported_cover.jpg", "original_cover.jpg"],
            watching: covers
        )
        let service = CacheManagementService(coverOwner: owner, roots: fixture.roots, diagnosticLog: nil)

        // Only what clearing frees: a size that stays after 清除 reads as a broken button.
        #expect(await service.snapshot().covers == 5 + 7 + 11)
        try await service.clear(.covers)

        #expect(FileManager.default.fileExists(atPath: imported.path))
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(!FileManager.default.fileExists(atPath: downloaded.path))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(!FileManager.default.fileExists(atPath: network.path))
        // Told once, after the files went: a cover it fetches back must not be deleted after.
        #expect(owner.coversLeftWhenTold == [["imported_cover.jpg", "original_cover.jpg"]])
        #expect(await service.snapshot().covers == 0)
    }

    @Test("covers stay while the books are not all known")
    @MainActor
    func coversStayWhileBooksAreUnknown() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let cover = fixture.roots.covers.appendingPathComponent("unknown_cover.jpg")
        let network = fixture.roots.networkCovers.appendingPathComponent("network.cover")
        try Data(repeating: 1, count: 5).write(to: cover)
        try Data(repeating: 2, count: 11).write(to: network)
        let owner = SavedCoverOwnerStub(irreplaceable: nil, watching: fixture.roots.covers)
        let service = CacheManagementService(coverOwner: owner, roots: fixture.roots, diagnosticLog: nil)

        #expect(await service.snapshot().covers == 11)
        try await service.clear(.covers)

        #expect(FileManager.default.fileExists(atPath: cover.path))
        #expect(!FileManager.default.fileExists(atPath: network.path))
        #expect(owner.coversLeftWhenTold == [["unknown_cover.jpg"]])
    }

    @Test("only an online book's downloaded cover is one a download brings back")
    @MainActor
    func bookStoreKeepsCoversNoDownloadBringsBack() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))

        var online = ReadingBook(title: "線上書", author: "作者", source: "https://example.com/book", contentFilename: "")
        online.isOnline = true
        online.coverUrl = "https://example.com/cover.jpg"
        online.coverImagePath = "online_cover.jpg"
        var imported = ReadingBook(title: "匯入書", author: "作者", contentFilename: "book.epub")
        imported.coverImagePath = "epub_cover.jpg"
        var customized = ReadingBook(title: "換過封面的匯入書", author: "作者", contentFilename: "other.epub")
        customized.coverImagePath = "x\(StorageLocations.customCoverFilenameMarker)1.jpg"
        customized.customCoverUrl = ReadingBook.localCustomCoverMarker
        customized.originalCoverImagePath = "other_epub_cover.jpg"
        // A remote-library copy has an address, but it is not an online book.
        var catalog = ReadingBook(title: "書庫書", author: "作者", contentFilename: "remote.epub")
        catalog.coverUrl = "https://library.example/cover.jpg"
        catalog.coverImagePath = "catalog_cover.jpg"
        for book in [online, imported, customized, catalog] { store.saveReadingBook(book) }

        let kept = try #require(store.irreplaceableCoverFilenames())

        #expect(kept.isSuperset(of: ["epub_cover.jpg", "other_epub_cover.jpg", "catalog_cover.jpg"]))
        #expect(!kept.contains("online_cover.jpg"))
    }

    @Test("a downloaded cover whose file is gone is fetched back under its own name")
    @MainActor
    func goneDownloadedCoverIsFetchedBack() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))
        var book = ReadingBook(title: "線上書", author: "作者", source: "https://example.com/book", contentFilename: "")
        book.isOnline = true
        book.coverUrl = try Self.pngDataURL()
        // What 清除封面快取 left in 3.0.0 (143): the name, without its file.
        let filename = "\(book.id.uuidString)_cover.jpg"
        book.coverImagePath = filename
        store.saveReadingBook(book)
        let cover = StorageLocations.coverFileLocation(filename)
        defer { try? FileManager.default.removeItem(at: cover) }
        #expect(!FileManager.default.fileExists(atPath: cover.path))

        await store.restoreMissingCovers()

        #expect(FileManager.default.fileExists(atPath: cover.path))
        #expect(store.readingBook(id: book.id)?.coverImagePath == filename)
        #expect(BookCoverLoader.localImage(filename: filename) != nil)
    }

    @Test("a picked cover whose file is gone is not replaced by the source's")
    @MainActor
    func gonePickedCoverIsNotReplaced() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))
        var book = ReadingBook(title: "線上書", author: "作者", source: "https://example.com/book", contentFilename: "")
        book.isOnline = true
        book.coverUrl = try Self.pngDataURL()
        let picked = "\(book.id.uuidString)\(StorageLocations.customCoverFilenameMarker)1.jpg"
        book.coverImagePath = picked
        book.customCoverUrl = ReadingBook.localCustomCoverMarker
        store.saveReadingBook(book)
        let download = StorageLocations.coverFileLocation("\(book.id.uuidString)_cover.jpg")
        defer { try? FileManager.default.removeItem(at: download) }

        await store.restoreMissingCovers()

        #expect(store.readingBook(id: book.id)?.coverImagePath == picked)
        #expect(!FileManager.default.fileExists(atPath: download.path))
    }

    enum ImportedFormat: String, CaseIterable, Sendable {
        case epub, pdf, comic
    }

    @Test("an imported book's cover whose file is gone is read again from the book's file",
          arguments: ImportedFormat.allCases)
    @MainActor
    func goneImportedCoverIsReadAgain(format: ImportedFormat) async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))
        let source = try await Self.importable(format, in: directory)
        let book = switch format {
        case .epub: try await store.importEpub(url: source)
        case .pdf: try await store.importLocalPDF(url: source)
        case .comic: try await store.importLocalManga(url: source)
        }
        let content = StorageLocations.bookFile(book.contentFilename)
        let filename = try #require(book.coverImagePath)
        let cover = StorageLocations.coverFileLocation(filename)
        defer {
            try? FileManager.default.removeItem(at: content)
            try? FileManager.default.removeItem(at: cover)
        }
        // What 清除封面快取 did to every imported book in 3.0.0 (143).
        try FileManager.default.removeItem(at: cover)

        await store.restoreMissingCovers()

        #expect(FileManager.default.fileExists(atPath: cover.path))
        #expect(BookCoverLoader.localImage(filename: filename) != nil)
        #expect(store.readingBook(id: book.id)?.coverImagePath == filename)
    }

    /// A file of `format` whose import saves a cover.
    @MainActor
    private static func importable(_ format: ImportedFormat, in directory: URL) async throws -> URL {
        let jpeg = EPUBTestFixtures.makeJPEG(width: 200, height: 300)
        switch format {
        case .epub:
            return try await EPUBTestFixtures.makeArchive(entries: [
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
                    <dc:identifier id="bookid">urn:uuid:\(UUID().uuidString)</dc:identifier>
                    <dc:title>封面書</dc:title>
                    <dc:language>zh</dc:language>
                  </metadata>
                  <manifest>
                    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                    <item id="cover" href="cover.jpg" media-type="image/jpeg" properties="cover-image"/>
                    <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
                  </manifest>
                  <spine><itemref idref="ch1"/></spine>
                </package>
                """.utf8),
                "OPS/nav.xhtml": Data(EPUBTestFixtures.xhtml(
                    title: "Nav",
                    body: #"<nav epub:type="toc"><ol><li><a href="chapter1.xhtml">一</a></li></ol></nav>"#
                ).utf8),
                "OPS/chapter1.xhtml": Data(EPUBTestFixtures.xhtml(title: "一", body: "<p>正文</p>").utf8),
                "OPS/cover.jpg": jpeg
            ])
        case .pdf:
            let url = directory.appendingPathComponent("封面書.pdf")
            try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 300)).pdfData { context in
                context.beginPage()
                UIColor.systemTeal.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
            }.write(to: url)
            return url
        case .comic:
            let archive = try await EPUBTestFixtures.makeArchive(entries: ["001.jpg": jpeg, "002.jpg": jpeg])
            let url = directory.appendingPathComponent("封面書.cbz")
            try FileManager.default.moveItem(at: archive, to: url)
            return url
        }
    }

    @MainActor
    private func service(_ fixture: (container: URL, roots: CacheStorageRoots)) -> CacheManagementService {
        CacheManagementService(coverOwner: SavedCoverOwnerStub(), roots: fixture.roots, diagnosticLog: nil)
    }

    /// An image `BookCoverLoader` decodes without the network.
    private static func pngDataURL() throws -> String {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 3)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 3))
        }
        let png = try #require(image.pngData())
        return "data:image/png;base64," + png.base64EncodedString()
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CacheManagementServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeFixture() throws -> (container: URL, roots: CacheStorageRoots) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("CacheManagementServiceTests-(UUID().uuidString)")
        let roots = CacheStorageRoots(
            chapters: container.appendingPathComponent("chapters", isDirectory: true),
            ttsAudio: container.appendingPathComponent("tts", isDirectory: true),
            mangaImages: container.appendingPathComponent("manga", isDirectory: true),
            covers: container.appendingPathComponent("covers", isDirectory: true),
            diagnostics: container.appendingPathComponent("diagnostics", isDirectory: true)
        )
        for directory in CacheCategory.allCases.map({ roots[$0] }) + [roots.networkCovers, roots.homeFeeds] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        return (container, roots)
    }
}

/// Stands in for the books (`BookStore`) behind the cover directory.
@MainActor
final class SavedCoverOwnerStub: SavedCoverOwner {
    var irreplaceable: Set<String>?
    private let covers: URL?
    /// The names left in `covers` each time the service said it had cleared them.
    private(set) var coversLeftWhenTold: [Set<String>] = []

    init(irreplaceable: Set<String>? = [], watching covers: URL? = nil) {
        self.irreplaceable = irreplaceable
        self.covers = covers
    }

    func irreplaceableCoverFilenames() -> Set<String>? { irreplaceable }

    func downloadedCoversRemoved() {
        let names = covers.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) } ?? []
        coversLeftWhenTold.append(Set(names))
    }
}
