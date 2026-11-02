import Foundation
import ReadiumZIPFoundation
import Testing
@testable import yuedu_app

/// A MOBI or AZW3 file on the shelf (MOBI plan, step 4): converted into an EPUB at import
/// with its original kept beside it, as an Aozora text is, and brought up to this build's
/// converter by the regenerator both formats share.
@Suite("MOBI book import", .serialized)
@MainActor
struct MOBIBookImportTests {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/MOBI")

    // MARK: Import

    @Test("a Kindle file becomes an EPUB book that keeps its original and names its own format",
          arguments: [
            ("features.azw3", "features.azw3", MOBIFile.Kind.kf8, "AZW3"),
            ("features.mobi", "features.mobi", .mobi6, "MOBI"),
            // A combination file reads as its KF8 part.
            ("features-combo.mobi", "features-combo.mobi", .kf8, "AZW3"),
            ("features.mobi", "features.prc", .mobi6, "MOBI"),
          ] as [(String, String, MOBIFile.Kind, String)])
    func localImport(fixture: String, name: String, kind: MOBIFile.Kind, label: String) async throws {
        try await withStore { store, root in
            let url = root.appendingPathComponent(name)
            try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent(fixture), to: url)

            let book = try await LocalBookImportService.importBook(at: url, store: store)

            #expect(book.source == "local_epub")
            #expect(book.resolvedPipelineKind == .epub)
            #expect(book.displayFormatLabel == label)
            let mobi = try #require(book.mobi)
            #expect(mobi.kind == kind)
            let ext = (name as NSString).pathExtension
            #expect(mobi.originalFilename == (book.contentFilename as NSString).deletingPathExtension + ".mobi." + ext)
            #expect(book.convertedOriginalFilename == mobi.originalFilename)
            let original = StorageLocations.bookFile(try #require(mobi.originalFilename))
            #expect(try Data(contentsOf: original) == (try Data(contentsOf: url)))
            #expect(store.readingBook(id: book.id)?.mobi == mobi)
            let session = try await PublicationSession.open(sourceURL: StorageLocations.bookFile(book.contentFilename))
            #expect(!session.chapters.isEmpty)
        }
    }

    @Test("a file that is not a MOBI is refused and leaves nothing behind")
    func refused() async throws {
        try await withStore { store, root in
            let url = root.appendingPathComponent("broken.azw3")
            try Data("not a Kindle book".utf8).write(to: url)
            await #expect(throws: MOBIError.notMOBI) {
                _ = try await LocalBookImportService.importBook(at: url, store: store)
            }
            #expect(store.books.isEmpty)
        }
    }

    // MARK: Record, sync and delete

    @Test("a book without a MOBI source encodes as before, and one with it round-trips")
    func encoding() throws {
        var book = ReadingBook(title: "題", contentFilename: "book.epub")
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(book)) as? [String: Any]
        #expect(plain?["mobi"] == nil)
        book.mobi = MOBIBookSource(originalFilename: "book.mobi.azw3", kind: .kf8)
        let decoded = try JSONDecoder().decode(ReadingBook.self, from: JSONEncoder().encode(book))
        #expect(decoded.mobi == book.mobi)
        // A remote library's copy has no local original: the remote file is the original.
        book.mobi = MOBIBookSource(originalFilename: nil, kind: .mobi6)
        #expect(try JSONDecoder().decode(ReadingBook.self, from: JSONEncoder().encode(book)).mobi == book.mobi)
        #expect(!book.isConvertedAtImport)
    }

    @Test("iCloud syncs a MOBI book's EPUB, its original and its cover")
    func syncedFiles() {
        var book = ReadingBook(title: "題", source: "local_epub", contentFilename: "book.epub")
        book.coverImagePath = "book_cover.jpg"
        book.mobi = MOBIBookSource(originalFilename: "book.mobi.azw3", kind: .kf8)
        #expect(ICloudSyncManager.syncableFiles(for: book).map(\.name) == ["book.epub", "book.mobi.azw3", "book_cover.jpg"])
    }

    @Test("deleting the book deletes its original too")
    func delete() async throws {
        try await withStore { store, root in
            let book = try await Self.importFixture("features.azw3", into: store, root: root)
            let original = try #require(book.mobi?.originalFilename)

            store.delete(bookId: book.id)

            #expect(!FileManager.default.fileExists(atPath: StorageLocations.bookFile(book.contentFilename).path))
            #expect(!FileManager.default.fileExists(atPath: StorageLocations.bookFile(original).path))
        }
    }

    // MARK: Regeneration

    @Test("an EPUB from this converter is left alone")
    func current() async throws {
        try await withStore { store, root in
            let book = try await Self.importFixture("features.azw3", into: store, root: root)
            let before = try Data(contentsOf: Self.epubURL(book))
            ConvertedTextVersions.shared.set(nil, for: book.id.uuidString)
            #expect(try await ConvertedBookRegenerator.prepare(book: book, store: store) == .current)
            #expect(try Data(contentsOf: Self.epubURL(book)) == before)
            // Before the reader exists, which stages its restore as it appears.
            #expect(ConvertedTextVersions.shared.version(for: book.id.uuidString) == MOBIEPUBWriter.textVersion)
        }
    }

    @Test("an older converter with the same text is replaced, and its spine cache goes")
    func olderConverterSameText() async throws {
        try await withStore { store, root in
            let book = try await Self.importFixture("features.mobi", into: store, root: root)
            try await Self.rewriteManifest(of: book) { $0["converterVersion"] = 0 }
            let cache = Self.spineCache(book)
            try Data("{}".utf8).write(to: cache)

            ConvertedTextVersions.shared.set(nil, for: book.id.uuidString)
            #expect(try await ConvertedBookRegenerator.prepare(book: book, store: store) == .regenerated)
            #expect(ConvertedTextVersions.shared.version(for: book.id.uuidString) == MOBIEPUBWriter.textVersion)

            let manifest = try #require(await ConvertedBookRegenerator.manifest(
                MOBIEPUBManifest.self, at: MOBIEPUBWriter.manifestPath, in: Self.epubURL(book), name: "MOBI"))
            #expect(manifest.converterVersion == MOBIEPUBWriter.converterVersion)
            #expect(!FileManager.default.fileExists(atPath: cache.path))
            _ = try await PublicationSession.open(sourceURL: Self.epubURL(book))
        }
    }

    @Test("an older converter whose text would change is left alone")
    func olderConverterChangedText() async throws {
        try await withStore { store, root in
            let book = try await Self.importFixture("features.azw3", into: store, root: root)
            try await Self.rewriteManifest(of: book) { json in
                json["converterVersion"] = 0
                var chapters = json["chapters"] as? [[String: Any]] ?? []
                chapters[0]["sha256"] = String(repeating: "0", count: 64)
                json["chapters"] = chapters
            }
            let before = try Data(contentsOf: Self.epubURL(book))
            #expect(try await ConvertedBookRegenerator.prepare(book: book, store: store) == .textChanged)
            #expect(try Data(contentsOf: Self.epubURL(book)) == before)
        }
    }

    // MARK: Helpers

    private func withStore(_ body: (BookStore, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MOBIBookImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = BookStore(metadataFileURL: root.appendingPathComponent("books.json"))
        defer {
            for book in store.books { store.delete(bookId: book.id) }
            try? FileManager.default.removeItem(at: root)
        }
        try await body(store, root)
    }

    private static func importFixture(_ name: String, into store: BookStore, root: URL) async throws -> ReadingBook {
        let url = root.appendingPathComponent(name)
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent(name), to: url)
        return try await LocalBookImportService.importBook(at: url, store: store)
    }

    private static func epubURL(_ book: ReadingBook) -> URL { StorageLocations.bookFile(book.contentFilename) }

    private static func spineCache(_ book: ReadingBook) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let name = book.contentFilename.replacingOccurrences(of: ".epub", with: "")
        return caches.appendingPathComponent("spine_cache_\(name).json")
    }

    /// Rebuilds the EPUB with its `yuedu-mobi.json` changed.
    private static func rewriteManifest(of book: ReadingBook, _ change: (inout [String: Any]) -> Void) async throws {
        let source = epubURL(book)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("rewrite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let old = try await Archive(url: source, accessMode: .read)
        let rebuilt = work.appendingPathComponent("rebuilt.epub")
        let new = try await Archive(url: rebuilt, accessMode: .create)
        for entry in try await old.entries() where entry.type == .file {
            let file = work.appendingPathComponent("entries").appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try await old.extract(entry, to: file)
            if entry.path == MOBIEPUBWriter.manifestPath {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
                var json = try #require(object as? [String: Any])
                change(&json)
                try JSONSerialization.data(withJSONObject: json).write(to: file)
            }
            try await new.addEntry(with: entry.path, fileURL: file,
                                   compressionMethod: entry.path == "mimetype" ? .none : .deflate)
        }
        _ = try FileManager.default.replaceItemAt(source, withItemAt: rebuilt)
    }
}
