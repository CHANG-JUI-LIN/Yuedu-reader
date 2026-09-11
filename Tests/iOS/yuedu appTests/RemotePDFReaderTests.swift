import Combine
import Foundation
import ReadiumShared
import UIKit
import XCTest
@testable import yuedu_app

final class RemotePDFReaderTests: XCTestCase {
    @MainActor
    func testAutomaticCachePDFUsesDocumentReader() async throws {
        try await checkPDF(data: makePDF(), offline: false)
    }

    @MainActor
    func testOfflinePDFUsesDocumentReader() async throws {
        try await checkPDF(data: makePDF(), offline: true)
    }

    @MainActor
    func testLegacyRemotePDFResumesWithoutReplacingReadingRecord() async throws {
        try await checkPDF(data: makePDF(), offline: false, restoreLegacy: true)
    }

    /// Opt-in acceptance with user-supplied local files. Credentials and private
    /// PDFs never enter the repository or the ordinary regression fixtures.
    @MainActor
    func testDownloadedPDFsUseDocumentReader() async throws {
        guard let value = ProcessInfo.processInfo.environment["YUEDU_PDF_READER_FIXTURES"],
              let paths = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String],
              !paths.isEmpty else { throw XCTSkip("No downloaded PDF fixtures supplied") }
        for path in paths {
            try await checkPDF(data: Data(contentsOf: URL(fileURLWithPath: path)), offline: false)
        }
    }

    @MainActor
    private func makePDF() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400)).pdfData { context in
            for index in 0..<3 {
                context.beginPage()
                "PDF page \(index + 1)".draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
            }
        }
    }

    @MainActor
    private func checkPDF(data: Data, offline: Bool, restoreLegacy: Bool = false) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let metadata = root.appendingPathComponent("books.json")
        let store = BookStore(metadataFileURL: metadata)
        let connections = RemoteLibraryConnectionStore(storageDirectory: root, importLegacyWebDAV: false)
        let connection = connections.add(name: "PDF test", url: "https://library.example/dav/",
            username: nil, password: nil, kind: .webDAV)
        let transport = RemotePDFTransport(data: data)
        let service = RemoteLibraryService(connections: connections, transportFactory: { _ in transport })
        let format = RemoteLibraryFormat(url: URL(string: "https://library.example/dav/中文.pdf")!, fileExtension: "pdf", mimeType: "application/pdf")
        let item = RemoteLibraryItem(id: "pdf-test", connectionID: connection.id, title: "Remote PDF", formats: [format])
        var record: ReadingBook?
        defer {
            if let record {
                service.release(bookID: record.id)
                try? FileManager.default.removeItem(at: service.cache.root.appendingPathComponent(record.id.uuidString))
                if let filename = record.remoteSource?.offlineFilename {
                    try? FileManager.default.removeItem(at: StorageLocations.bookFile(filename))
                }
            }
            connections.remove(connection)
            try? FileManager.default.removeItem(at: root)
        }
        let created: ReadingBook
        if offline {
            created = try await service.downloadOffline(item: item, format: format, store: store)
            record = created
        } else {
            created = try await service.read(item: item, format: format, store: store)
            record = created
        }
        let book: ReadingBook
        let readerStore: BookStore
        if restoreLegacy {
            service.release(bookID: created.id)
            var legacy = created
            legacy.source = "local"
            legacy.mangaPage = 1
            legacy.currentPosition = 0.5
            store.saveReadingBook(legacy)
            let bookmark = Bookmark(chapterIndex: 0, chapterTitle: "PDF",
                position: CoreTextReadingPosition(spineIndex: 0, charOffset: 1),
                note: "Saved PDF position", excerpt: "", date: Date())
            store.addBookmark(bookId: legacy.id, bookmark: bookmark)
            // Complete the pending metadata write before simulating relaunch.
            store.updatePosition(bookId: legacy.id, position: 0.5, forceSave: true)
            readerStore = BookStore(metadataFileURL: metadata)
            book = try await service.prepare(bookID: legacy.id, store: readerStore)
            XCTAssertEqual(book.id, legacy.id)
            XCTAssertEqual(book.currentPosition, 0.5)
            XCTAssertEqual(book.mangaPage, 1)
            XCTAssertTrue(readerStore.readingBook(id: legacy.id)?.bookmarks.contains(where: { $0.id == bookmark.id }) == true)
        } else {
            readerStore = store
            book = try await service.prepare(bookID: created.id, store: store)
        }
        record = book
        XCTAssertEqual(book.source, "local_pdf")
        XCTAssertEqual(book.resolvedPipelineKind, .fixedPage)
        XCTAssertFalse(book.isOnline)
        XCTAssertTrue(readerStore.books.isEmpty)
        let file = StorageLocations.bookFile(book.contentFilename)
        let pageCount = try LocalPDFArchive.inspect(url: file).pageCount
        let state = FixedPageReaderState()
        let loaded = expectation(description: "PDF document reader finishes loading")
        let subscription = state.$isLoading.dropFirst().filter { !$0 }.prefix(1).sink { _ in loaded.fulfill() }
        defer { subscription.cancel() }
        let controller = FixedPageReaderViewController(book: book, store: readerStore, state: state,
            chapterFetcher: MockChapterFetcher())
        controller.loadViewIfNeeded()
        await fulfillment(of: [loaded], timeout: 10)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.totalPages, pageCount)
        if restoreLegacy { XCTAssertEqual(state.currentPage, 1) }
        let page = FixedPage(id: 0, imageURL: file.absoluteString, headers: [:], localURL: nil,
            renderSource: .pdf(sourceFilename: book.contentFilename, pageIndex: 0))
        let image = await FixedPageImageLoader.loadImage(for: page, targetWidth: 320, renderScale: 1)
        XCTAssertNotNil(image)
        if let image {
            let attachment = XCTAttachment(image: image)
            attachment.name = "remote-pdf-first-page"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        print("[RemotePDFReader] bytes=\(data.count) pages=\(pageCount) readerPages=\(state.totalPages) offline=\(offline) legacy=\(restoreLegacy)")
        controller.view.removeFromSuperview()
    }
}

/// Nutstore successfully answers HEAD with Content-Length: 0 and no MIME type;
/// its GET contains the actual PDF. The reader must work with this response too.
private final class RemotePDFTransport: RemoteLibraryTransport {
    let data: Data
    init(data: Data) { self.data = data }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "0"])!)
    }

    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return (url, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/pdf", "Content-Length": String(data.count)])!)
    }

    func stream(request: any HTTPRequestConvertible,
                consume: @escaping (Data, Double?) -> HTTPResult<Void>) async -> HTTPResult<HTTPResponse> {
        XCTFail("PDF preparation should not enter EPUB range loading")
        return .failure(.malformedRequest(url: "https://library.example/dav/"))
    }
}
