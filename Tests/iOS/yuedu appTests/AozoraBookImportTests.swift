import Foundation
import ReadiumZIPFoundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("Aozora book import", .serialized)
@MainActor
struct AozoraBookImportTests {
    private static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/TXTEncodings/aozora-neko-jijo.txt")

    /// An Aozora text with a figure; the 底本 line makes the detector accept it.
    private static let illustrated = "題\n著者\n\n本文\n［＃挿絵１（fig1.png、横10×縦10）入る］\n\n底本：「題」架空書房\n"

    // MARK: Import

    @Test("an Aozora .txt becomes an EPUB book, titled from its header, with its bytes kept beside it")
    func textImport() async throws {
        let (store, root) = try Self.store()
        defer { Self.clean(store, root) }
        let url = root.appendingPathComponent("neko.txt")
        try FileManager.default.copyItem(at: Self.fixture, to: url)

        let book = try await LocalBookImportService.importBook(at: url, store: store)

        #expect(book.source == "local_epub")
        #expect(book.resolvedPipelineKind == .epub)
        #expect(book.title == "『吾輩は猫である』中篇自序")
        #expect(book.author == "夏目漱石")
        let aozora = try #require(book.aozora)
        #expect(aozora.originalFilename == (book.contentFilename as NSString).deletingPathExtension + ".aozora.txt")
        #expect(aozora.sourceEncoding == String.Encoding.shiftJIS.rawValue)
        #expect(try Data(contentsOf: StorageLocations.bookFile(aozora.originalFilename)) == (try Data(contentsOf: Self.fixture)))
        let session = try await PublicationSession.open(sourceURL: StorageLocations.bookFile(book.contentFilename))
        #expect(session.language == "ja")
        #expect(store.readingBook(id: book.id)?.aozora == aozora)
    }

    @Test("an official zip with a figure: the figure goes into the EPUB and the zip is kept")
    func zipImport() async throws {
        let (store, root) = try Self.store()
        defer { Self.clean(store, root) }
        let zip = try await Self.zip(at: root.appendingPathComponent("illustrated.zip"), entries: [
            "illustrated/illustrated.txt": Data(Self.illustrated.utf8),
            "illustrated/fig1.png": try Self.png(),
        ])

        let book = try await LocalBookImportService.importBook(at: zip, store: store)

        #expect(book.resolvedPipelineKind == .epub)
        let aozora = try #require(book.aozora)
        #expect(aozora.originalFilename.hasSuffix(".aozora.zip"))
        #expect(try Data(contentsOf: StorageLocations.bookFile(aozora.originalFilename)) == (try Data(contentsOf: zip)))
        let archive = try await Archive(url: StorageLocations.bookFile(book.contentFilename), accessMode: .read)
        let paths = try await archive.entries().map(\.path)
        #expect(paths.contains("OPS/images/1-fig1.png"))
    }

    @Test("a plain .txt still imports as a TXT book")
    func plainText() async throws {
        let (store, root) = try Self.store()
        defer { Self.clean(store, root) }
        let url = root.appendingPathComponent("plain.txt")
        try Data("第一章\n普通的文字《不是注音》。\n".utf8).write(to: url)

        let book = try await LocalBookImportService.importBook(at: url, store: store)

        #expect(book.resolvedPipelineKind == .txt)
        #expect(book.aozora == nil)
    }

    // MARK: Encoding

    @Test("a book without an Aozora original encodes as before, and one with it round-trips")
    func encoding() throws {
        var book = ReadingBook(title: "題", contentFilename: "book.epub")
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(book)) as? [String: Any]
        #expect(plain?["aozora"] == nil)
        book.aozora = AozoraBookSource(originalFilename: "book.aozora.zip", sourceEncoding: String.Encoding.shiftJIS.rawValue)
        let decoded = try JSONDecoder().decode(ReadingBook.self, from: JSONEncoder().encode(book))
        #expect(decoded.aozora == book.aozora)
    }

    // MARK: Sync and delete

    @Test("iCloud syncs an Aozora book's EPUB, its original and its cover")
    func syncedFiles() {
        var book = ReadingBook(title: "題", source: "local_epub", contentFilename: "book.epub")
        book.coverImagePath = "book_cover.jpg"
        book.aozora = AozoraBookSource(originalFilename: "book.aozora.txt", sourceEncoding: String.Encoding.shiftJIS.rawValue)
        let files = ICloudSyncManager.syncableFiles(for: book)
        #expect(files.map(\.name) == ["book.epub", "book.aozora.txt", "book_cover.jpg"])
        #expect(files.map(\.url) == [StorageLocations.bookFile("book.epub"), StorageLocations.bookFile("book.aozora.txt"),
                                     StorageLocations.coverFile("book_cover.jpg")])
        book.isInBookshelf = false
        #expect(ICloudSyncManager.syncableFiles(for: book).map(\.name) == ["book_cover.jpg"])
    }

    @Test("deleting the book deletes its original too")
    func delete() async throws {
        let (store, root) = try Self.store()
        defer { Self.clean(store, root) }
        let url = root.appendingPathComponent("neko.txt")
        try FileManager.default.copyItem(at: Self.fixture, to: url)
        let book = try await LocalBookImportService.importBook(at: url, store: store)
        let original = try #require(book.aozora?.originalFilename)

        store.delete(bookId: book.id)

        #expect(!FileManager.default.fileExists(atPath: StorageLocations.bookFile(book.contentFilename).path))
        #expect(!FileManager.default.fileExists(atPath: StorageLocations.bookFile(original).path))
    }

    // MARK: Helpers

    private static func store() throws -> (BookStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AozoraBookImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (BookStore(metadataFileURL: root.appendingPathComponent("books.json")), root)
    }

    private static func clean(_ store: BookStore, _ root: URL) {
        for book in store.books { store.delete(bookId: book.id) }
        try? FileManager.default.removeItem(at: root)
    }

    private static func zip(at url: URL, entries: [String: Data]) async throws -> URL {
        let staging = url.deletingLastPathComponent().appendingPathComponent("zip-source", isDirectory: true)
        let archive = try await Archive(url: url, accessMode: .create)
        for (path, data) in entries.sorted(by: { $0.key < $1.key }) {
            let file = staging.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
            try await archive.addEntry(with: path, fileURL: file)
        }
        return url
    }

    private static func png() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        return try #require(image.pngData())
    }
}
