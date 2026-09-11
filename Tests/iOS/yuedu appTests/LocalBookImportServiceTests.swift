import Foundation
import Testing
@testable import yuedu_app

@Suite("Local book import service", .serialized)
@MainActor
struct LocalBookImportServiceTests {
    @Test("Shared TXT and Markdown imports keep original bytes, metadata and shelf membership")
    func importsTXTAndMarkdown() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalBookImportServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BookStore(metadataFileURL: root.appendingPathComponent("books.json"))
        defer { for book in store.books { store.delete(bookId: book.id) } }
        for ext in ["txt", "md", "markdown"] {
            let url = root.appendingPathComponent("source.\(ext)")
            let data = Data("# 第一章\r\n原始文字 **Markdown** 😀\r\n".utf8)
            try data.write(to: url)
            let book = try await LocalBookImportService.importBook(at: url, title: "Imported \(ext)", author: "Calibre Author", store: store)
            #expect(book.isInBookshelf)
            #expect(book.remoteSource == nil)
            #expect(book.title == "Imported \(ext)")
            #expect(book.author == "Calibre Author")
            #expect(try Data(contentsOf: StorageLocations.bookFile(book.contentFilename)) == data)
            #expect(store.books.contains { $0.id == book.id })
        }
        #expect(store.books.count == 3)
    }

    @Test("A cancelled shared import never inserts a book")
    func cancellationBeforeImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalBookImportCancelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BookStore(metadataFileURL: root.appendingPathComponent("books.json"))
        let file = root.appendingPathComponent("source.txt")
        try Data("第一章\n文字".utf8).write(to: file)
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LocalBookImportService.importBook(at: file, store: store)
        }
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        #expect(store.books.isEmpty)
    }

    @Test("An invalid EPUB is rejected and its imported copy is removed")
    func invalidEPUBLeavesNoShelfOrCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalBookImportInvalidTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BookStore(metadataFileURL: root.appendingPathComponent("books.json"))
        let invalid = root.appendingPathComponent("invalid.epub")
        try Data("This is not an EPUB archive".utf8).write(to: invalid)
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: StorageLocations.documents.path))
        await #expect(throws: (any Error).self) {
            _ = try await LocalBookImportService.importBook(at: invalid, title: "Invalid", store: store)
        }
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: StorageLocations.documents.path))
        #expect(after.subtracting(before).isEmpty)
        #expect(store.books.isEmpty)
    }
}
