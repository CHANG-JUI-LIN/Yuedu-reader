import Foundation
import ReadiumZIPFoundation
import Testing
@testable import yuedu_app

@Suite("Aozora book regenerator", .serialized)
@MainActor
struct AozoraBookRegeneratorTests {
    private static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/TXTEncodings/aozora-neko-jijo.txt")

    @Test("an EPUB from this converter is left alone")
    func current() async throws {
        try await withBook { store, book in
            let before = try epubData(book)
            #expect(try await AozoraBookRegenerator.prepare(book: book, store: store) == .current)
            #expect(try epubData(book) == before)
        }
    }

    @Test("an older converter with the same text is replaced, and its spine cache goes")
    func olderConverterSameText() async throws {
        try await withBook { store, book in
            try await rewriteManifest(of: book) { $0.converterVersion = 0 }
            let cache = spineCache(book)
            try Data("{}".utf8).write(to: cache)
            #expect(try await AozoraBookRegenerator.prepare(book: book, store: store) == .regenerated)
            let manifest = try #require(await AozoraBookRegenerator.recordedManifest(in: epubURL(book)))
            #expect(manifest.converterVersion == AozoraEPUBWriter.converterVersion)
            #expect(!FileManager.default.fileExists(atPath: cache.path))
            _ = try await PublicationSession.open(sourceURL: epubURL(book))
        }
    }

    @Test("an older converter whose text would change is left alone")
    func olderConverterChangedText() async throws {
        try await withBook { store, book in
            try await rewriteManifest(of: book) {
                $0.converterVersion = 0
                $0.chapters[0].sha256 = String(repeating: "0", count: 64)
            }
            let before = try epubData(book)
            #expect(try await AozoraBookRegenerator.prepare(book: book, store: store) == .textChanged)
            #expect(try epubData(book) == before)
        }
    }

    @Test("an older text version is left alone")
    func olderTextVersion() async throws {
        try await withBook { store, book in
            try await rewriteManifest(of: book) {
                $0.converterVersion = 0
                $0.textVersion = 0
            }
            let before = try epubData(book)
            #expect(try await AozoraBookRegenerator.prepare(book: book, store: store) == .olderTextVersion)
            #expect(try epubData(book) == before)
        }
    }

    @Test("a missing or unreadable manifest is regenerated, like version 0")
    func missingManifest() async throws {
        for broken in [nil, Data("not json".utf8)] {
            try await withBook { store, book in
                try await rewriteManifest(of: book, replacingWith: broken)
                #expect(try await AozoraBookRegenerator.prepare(book: book, store: store) == .regenerated)
                #expect(await AozoraBookRegenerator.recordedManifest(in: epubURL(book)) != nil)
            }
        }
    }

    @Test("an EPUB from a newer converter is never downgraded")
    func newer() async throws {
        try await withBook { store, book in
            try await rewriteManifest(of: book) { $0.converterVersion = AozoraEPUBWriter.converterVersion + 1 }
            let before = try epubData(book)
            #expect(try await AozoraBookRegenerator.prepare(book: book, store: store) == .newer)
            #expect(try epubData(book) == before)
        }
    }

    @Test("without the original on this device, nothing changes until a later open")
    func originalMissing() async throws {
        try await withBook { store, book in
            try await rewriteManifest(of: book) { $0.converterVersion = 0 }
            try FileManager.default.removeItem(at: StorageLocations.bookFile(try #require(book.aozora).originalFilename))
            let before = try epubData(book)
            #expect(try await AozoraBookRegenerator.prepare(book: book, store: store) == .originalMissing)
            #expect(try epubData(book) == before)
        }
    }

    @Test("a book open in another reader is left alone until it closes")
    func inUse() async throws {
        try await withBook { store, book in
            try await rewriteManifest(of: book) { $0.converterVersion = 0 }
            let other = UUID()
            let mine = UUID()
            ReadingResourceUsage.shared.retain(bookID: book.id, ownerID: other)
            ReadingResourceUsage.shared.retain(bookID: book.id, ownerID: mine)
            #expect(try await AozoraBookRegenerator.prepare(book: book, store: store, readerID: mine) == .inUse)
            ReadingResourceUsage.shared.release(bookID: book.id, ownerID: other)
            #expect(try await AozoraBookRegenerator.prepare(book: book, store: store, readerID: mine) == .regenerated)
            ReadingResourceUsage.shared.release(bookID: book.id, ownerID: mine)
        }
    }

    // MARK: Helpers

    private func withBook(_ body: (BookStore, ReadingBook) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AozoraRegeneratorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = BookStore(metadataFileURL: root.appendingPathComponent("books.json"))
        defer {
            for book in store.books { store.delete(bookId: book.id) }
            try? FileManager.default.removeItem(at: root)
        }
        let url = root.appendingPathComponent("neko.txt")
        try FileManager.default.copyItem(at: Self.fixture, to: url)
        let book = try await LocalBookImportService.importBook(at: url, store: store)
        try await body(store, book)
    }

    private func epubURL(_ book: ReadingBook) -> URL { StorageLocations.bookFile(book.contentFilename) }

    private func epubData(_ book: ReadingBook) throws -> Data { try Data(contentsOf: epubURL(book)) }

    private func spineCache(_ book: ReadingBook) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let name = book.contentFilename.replacingOccurrences(of: ".epub", with: "")
        return caches.appendingPathComponent("spine_cache_\(name).json")
    }

    private func rewriteManifest(of book: ReadingBook, _ change: (inout AozoraEPUBManifest) -> Void) async throws {
        var manifest = try #require(await AozoraBookRegenerator.recordedManifest(in: epubURL(book)))
        change(&manifest)
        try await rewriteManifest(of: book, replacingWith: try JSONEncoder().encode(manifest))
    }

    /// Rebuilds the EPUB with its manifest replaced, or left out when `data` is nil.
    private func rewriteManifest(of book: ReadingBook, replacingWith data: Data?) async throws {
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
            if entry.path == AozoraEPUBWriter.manifestPath {
                guard let data else { continue }
                try data.write(to: file)
            } else {
                _ = try await old.extract(entry, to: file)
            }
            try await new.addEntry(with: entry.path, fileURL: file,
                                   compressionMethod: entry.path == "mimetype" ? .none : .deflate)
        }
        _ = try FileManager.default.replaceItemAt(source, withItemAt: rebuilt)
    }
}
