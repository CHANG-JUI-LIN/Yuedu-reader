import Combine
import Foundation
import Testing
@testable import yuedu_app

/// 開始閱讀 on a library item's detail page opens the reader at once; the reader downloads and
/// prepares the copy under its own 載入中… (`BookReaderView`). Until 2026-10-12 the page
/// waited on that preparation itself, showing 正在開啟書籍 and 取消 under the hero.
@MainActor
@Suite("Remote library read action", .serialized)
struct RemoteLibraryActionModelTests {
    private struct Unreachable: Error {}

    /// A service whose preparation never finishes: a page that waits on it never opens.
    private final class Service: RemoteLibraryServing {
        var prepared = 0
        var recordFails = false
        let copy: ReadingBook

        init() {
            var book = ReadingBook(title: "Remote", author: "Author", source: "local_epub", contentFilename: "remote.epub")
            book.isInBookshelf = false
            copy = book
        }

        var failurePublisher: AnyPublisher<RemoteLibraryReadFailure, Never> { Empty().eraseToAnyPublisher() }
        func book(for item: RemoteLibraryItem, format: RemoteLibraryFormat, store: BookStore) -> ReadingBook? { nil }
        func readingCopy(item: RemoteLibraryItem, format: RemoteLibraryFormat, store: BookStore) throws -> ReadingBook {
            if recordFails { throw Unreachable() }
            return copy
        }
        func addToShelf(item: RemoteLibraryItem, format: RemoteLibraryFormat, store: BookStore) throws -> ReadingBook { copy }
        func downloadOffline(item: RemoteLibraryItem, format: RemoteLibraryFormat, store: BookStore) async throws -> ReadingBook { copy }
        func prepare(bookID: UUID, store: BookStore) async throws -> ReadingBook {
            prepared += 1
            try await Task.sleep(for: .seconds(3600))
            return copy
        }
        func publication(bookID: UUID) -> PublicationSession? { nil }
        func hasOfflineCopy(_ book: ReadingBook) -> Bool { false }
        func release(bookID: UUID) {}
    }

    private let format = RemoteLibraryFormat(url: URL(string: "https://library.example/book.epub")!,
                                             fileExtension: "epub", mimeType: "application/epub+zip")
    private var item: RemoteLibraryItem {
        RemoteLibraryItem(id: "1", connectionID: "library", title: "Remote", formats: [format])
    }

    @Test("開始閱讀 hands the copy to the reader at once, without preparing it on the page")
    func readOpensTheReaderAtOnce() {
        let service = Service()
        let model = RemoteLibraryActionModel()
        var opened: [UUID] = []
        model.begin(.read, item: item, format: format, service: service, store: BookStore()) { opened.append($0) }
        #expect(opened == [service.copy.id])
        #expect(model.action == nil, "The page shows no 正在開啟書籍 of its own")
        #expect(service.prepared == 0, "The reader prepares the copy")
    }

    @Test("a copy that cannot be recorded says why on the page and opens nothing")
    func readFailureStaysOnThePage() {
        let service = Service()
        service.recordFails = true
        let model = RemoteLibraryActionModel()
        var opened: [UUID] = []
        model.begin(.read, item: item, format: format, service: service, store: BookStore()) { opened.append($0) }
        #expect(opened.isEmpty)
        #expect(model.failed)
        #expect(model.message != nil)
        #expect(model.action == nil)
    }
}
