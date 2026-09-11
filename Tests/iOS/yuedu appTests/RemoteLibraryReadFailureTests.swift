import Combine
import Foundation
import ReadiumShared
import Testing
@testable import yuedu_app

@Suite("Remote reader resource failure presentation", .serialized)
@MainActor
struct RemoteLibraryReadFailureTests {
    @Test("Resource failure events retain the book identity and are published on the main actor")
    func servicePublishesFailureSnapshot() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let connections = RemoteLibraryConnectionStore(storageDirectory: root, importLegacyWebDAV: false)
        let service = RemoteLibraryService(connections: connections, cache: RemoteLibraryCache(root: root))
        let failure = RemoteLibraryReadFailure(bookID: UUID(), message: "A failed resource")
        var received: [RemoteLibraryReadFailure] = []
        var deliveredOnMainThread = false
        let subscription = service.failurePublisher.sink {
            received.append($0)
            deliveredOnMainThread = Thread.isMainThread
        }
        defer { subscription.cancel() }

        service.reportReadFailure(failure)

        #expect(received == [failure])
        #expect(deliveredOnMainThread)
    }

    @Test("Opening errors and a different book's resource errors do not interrupt the current reader")
    func onlyCurrentReadyReaderAcceptsFailures() {
        let currentID = UUID()
        let otherFailure = RemoteLibraryReadFailure(bookID: UUID(), message: "Other book")
        let currentFailure = RemoteLibraryReadFailure(bookID: currentID, message: "Current book")
        var state = RemoteReaderFailureAlertState()

        let acceptedOtherBook = state.receive(otherFailure, bookID: currentID, isReady: true)

        #expect(!acceptedOtherBook)
        let acceptedDuringOpening = state.receive(currentFailure, bookID: currentID, isReady: false)
        #expect(!acceptedDuringOpening)
        #expect(state.failure == nil)
        let acceptedCurrentBook = state.receive(currentFailure, bookID: currentID, isReady: true)
        #expect(acceptedCurrentBook)
        #expect(state.failure == currentFailure)
    }

    @Test("Cancelling an alert keeps repeated prefetch failures from immediately reopening it")
    func dismissedFailureIsNotRepeated() {
        let currentID = UUID()
        let failure = RemoteLibraryReadFailure(bookID: currentID, message: "Offline")
        var state = RemoteReaderFailureAlertState()
        let acceptedInitialFailure = state.receive(failure, bookID: currentID, isReady: true)
        #expect(acceptedInitialFailure)
        let acceptedVisibleDuplicate = state.receive(failure, bookID: currentID, isReady: true)
        #expect(!acceptedVisibleDuplicate)
        state.dismiss()

        #expect(state.failure == nil)
        let acceptedDismissedDuplicate = state.receive(failure, bookID: currentID, isReady: true)
        #expect(!acceptedDismissedDuplicate)
        #expect(state.failure == nil)
        let changed = RemoteLibraryReadFailure(bookID: currentID, message: "Remote file changed")
        let acceptedDifferentFailure = state.receive(changed, bookID: currentID, isReady: true)
        #expect(acceptedDifferentFailure)
        #expect(state.failure == changed)
    }

    @Test("Concurrent distinct failures do not replace the message being announced")
    func activeAlertKeepsItsMessage() {
        let currentID = UUID()
        let first = RemoteLibraryReadFailure(bookID: currentID, message: "Offline")
        let second = RemoteLibraryReadFailure(bookID: currentID, message: "Authentication failed")
        var state = RemoteReaderFailureAlertState()
        let acceptedFirstFailure = state.receive(first, bookID: currentID, isReady: true)
        #expect(acceptedFirstFailure)
        let replacedActiveFailure = state.receive(second, bookID: currentID, isReady: true)
        #expect(!replacedActiveFailure)
        #expect(state.failure == first)
        state.dismiss()
        let acceptedAfterDismissal = state.receive(second, bookID: currentID, isReady: true)
        #expect(acceptedAfterDismissal)
    }

    @Test("Cancellation is silent and HTTP failures preserve their actionable reason")
    func failuresArePresentedWithoutRawResponseBodies() throws {
        let bookID = UUID()
        #expect(RemoteLibraryReadFailure(bookID: bookID, error: .cancelled) == nil)
        #expect(RemoteLibraryReadFailure(bookID: bookID, error: .timeout(nil))?.message == localized("連線逾時"))
        #expect(RemoteLibraryReadFailure(bookID: bookID, error: .offline(nil))?.message
                == localized("無法連線至書庫，請檢查網路與伺服器。"))
        let url = try #require(HTTPURL(string: "https://example.com/book.epub"))
        for code in [401, 403, 412, 503] {
            let response = HTTPResponse(request: HTTPRequest(url: url), url: url,
                status: HTTPStatus(rawValue: code), headers: [:], mediaType: .html,
                body: Data("<html>Do not display a server login document</html>".utf8))
            let failure = try #require(RemoteLibraryReadFailure(bookID: bookID, error: .errorResponse(response)))
            #expect(failure.bookID == bookID)
            #expect(!failure.message.contains("<html>"))
            switch code {
            case 401, 403: #expect(failure.message == localized("認證失敗，請確認帳號和密碼"))
            case 412: #expect(failure.message == localized("遠端書籍已更新，請返回書籍詳情重新開啟"))
            default: #expect(failure.message.contains("503"))
            }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteLibraryReadFailureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
