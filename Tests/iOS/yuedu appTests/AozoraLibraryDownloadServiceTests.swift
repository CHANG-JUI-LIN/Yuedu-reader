import Foundation
import ReadiumZIPFoundation
import Testing
@testable import yuedu_app

@Suite("Aozora library downloads", .serialized)
@MainActor
struct AozoraLibraryDownloadServiceTests {
    private func environment() throws -> (BookStore, URL, AozoraWork) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AozoraDownloadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let work = try #require(AozoraCatalog.decode(AozoraCatalogTests.fixture).works.first)
        return (BookStore(metadataFileURL: root.appendingPathComponent("books.json")), root, work)
    }
    private func clean(_ store: BookStore, _ root: URL) {
        for book in store.books { store.delete(bookId: book.id) }
        do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) }
    }
    private func fixtureZip(_ root: URL, plainText: Bool = false) async throws -> URL {
        let text = root.appendingPathComponent("book.txt")
        if plainText { try Data("A plain readme without Aozora notation.".utf8).write(to: text) }
        else {
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/TXTEncodings/aozora-neko-jijo.txt")
            try FileManager.default.copyItem(at: fixture, to: text)
        }
        let zip = root.appendingPathComponent("fixture.zip")
        let archive = try await Archive(url: zip, accessMode: .create)
        try await archive.addEntry(with: "book.txt", fileURL: text)
        return zip
    }

    @Test func realFixtureImportsAndDeduplicates() async throws {
        let (store, root, work) = try environment()
        defer { clean(store, root) }
        let zip = try await fixtureZip(root)
        var downloads = 0
        var temporary: URL?
        let service = AozoraLibraryDownloadService(temporaryDirectory: root, download: { url, destination in
            #expect(url.absoluteString == work.text)
            downloads += 1
            temporary = destination
            try FileManager.default.copyItem(at: zip, to: destination)
        })
        let book = try await service.addToShelf(work: work, store: store)
        #expect(book.aozora?.catalogWorkID == work.id)
        #expect(book.source == "local_epub")
        #expect(book.title == work.title)
        #expect(store.books.count == 1)
        #expect(book.aozora?.sourceEncoding == String.Encoding.shiftJIS.rawValue)
        #expect(try await service.addToShelf(work: work, store: store).id == book.id)
        #expect(downloads == 1)
        #expect(!FileManager.default.fileExists(atPath: try #require(temporary).path))
    }

    @Test func noAozoraTextReportsErrorAndCleansTemporaryFile() async throws {
        let (store, root, work) = try environment()
        defer { clean(store, root) }
        let zip = try await fixtureZip(root, plainText: true)
        var temporary: URL?
        let service = AozoraLibraryDownloadService(temporaryDirectory: root, download: { _, destination in
            temporary = destination
            try FileManager.default.copyItem(at: zip, to: destination)
        })
        await #expect(throws: AozoraLibraryDownloadError.notAozoraText) { try await service.addToShelf(work: work, store: store) }
        #expect(store.books.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: try #require(temporary).path))
    }

    @Test func networkErrorsKeepTheirMeaning() async throws {
        let (store, root, work) = try environment()
        defer { clean(store, root) }
        for code in [URLError.cannotFindHost, .cannotConnectToHost, .notConnectedToInternet] {
            let service = AozoraLibraryDownloadService(temporaryDirectory: root, download: { _, _ in throw URLError(code) })
            await #expect(throws: AozoraLibraryDownloadError.connection) { try await service.addToShelf(work: work, store: store) }
        }
        let service = AozoraLibraryDownloadService(temporaryDirectory: root, download: { _, _ in throw AozoraLibraryDownloadError.http(503) })
        await #expect(throws: AozoraLibraryDownloadError.http(503)) { try await service.addToShelf(work: work, store: store) }
    }

    @Test func cancellationRemovesPartialDownload() async throws {
        let (store, root, work) = try environment()
        defer { clean(store, root) }
        var temporary: URL?
        let service = AozoraLibraryDownloadService(temporaryDirectory: root, download: { _, destination in
            temporary = destination
            try Data("partial".utf8).write(to: destination)
            throw CancellationError()
        })
        await #expect(throws: CancellationError.self) { try await service.addToShelf(work: work, store: store) }
        #expect(!FileManager.default.fileExists(atPath: try #require(temporary).path))
        #expect(store.books.isEmpty)
    }

    @Test func nilCatalogIDPreservesSyncEncoding() throws {
        let legacy = Data(#"{"originalFilename":"book.aozora.zip","sourceEncoding":8}"#.utf8)
        let source = try JSONDecoder().decode(AozoraBookSource.self, from: legacy)
        #expect(source.catalogWorkID == nil)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(source) == legacy)
        var identified = source; identified.catalogWorkID = "1"
        #expect(try JSONDecoder().decode(AozoraBookSource.self, from: encoder.encode(identified)) == identified)
    }
}
