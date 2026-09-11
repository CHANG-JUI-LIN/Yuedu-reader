import Combine
import Foundation
import ReadiumShared
import Testing
import UIKit
@testable import yuedu_app

@Suite("Remote library reading use cases", .serialized)
@MainActor
struct RemoteLibraryServiceTests {
    @Test("adding a remote reference to the shelf performs no network request")
    func addToShelfDoesNotFetch() throws {
        let context = try Context(extension: "txt", data: Data("第一章\n正文。".utf8))
        defer { context.cleanup() }
        let added = try context.service.addToShelf(item: context.item, format: context.format, store: context.store)
        #expect(context.transport.requestCount == 0)
        #expect(context.store.books.map(\.id) == [added.id])
        #expect(added.remoteSource?.cachedFilename == nil)
        #expect(added.remoteSource?.offlineFilename == nil)
        #expect(added.lastOpenedDate == nil)
        #expect(!FileManager.default.fileExists(atPath: StorageLocations.bookFile(added.contentFilename).path))
    }

    @Test("reading TXT uses automatic cache while keeping shelf and offline download independent")
    func readingTXTDoesNotAddOrDownloadOffline() async throws {
        let text = "第一章 測試\n遠端書庫線上閱讀正文。\n第二章\n繼續閱讀。"
        let context = try Context(extension: "txt", data: Data(text.utf8))
        defer { context.cleanup() }
        let read = try await context.service.read(item: context.item, format: context.format, store: context.store)
        #expect(context.store.books.isEmpty)
        #expect(!read.isInBookshelf)
        #expect(read.remoteSource?.offlineFilename == nil)
        let cached = try #require(read.remoteSource?.cachedFilename)
        #expect(try String(contentsOf: StorageLocations.bookFile(cached), encoding: .utf8) == text)
        #expect(context.transport.downloadCount == 1)
        #expect(context.service.publication(bookID: read.id) == nil)
    }

    @Test("reopening and adding to the shelf keep one identity, position and bookmarks")
    func readThenReopenThenAddPreservesProgress() async throws {
        let context = try Context(extension: "txt", data: Data("第一章\n遠端閱讀正文。".utf8))
        defer { context.cleanup() }
        let first = try await context.service.read(item: context.item, format: context.format, store: context.store)
        let bookmark = Bookmark(chapterIndex: 0, chapterTitle: "第一章",
            position: CoreTextReadingPosition(spineIndex: 0, charOffset: 8),
            note: "Keep", excerpt: "正文", date: Date(timeIntervalSinceReferenceDate: 100))
        context.store.addBookmark(bookId: first.id, bookmark: bookmark)
        context.store.updatePosition(bookId: first.id, position: 0.375, forceSave: true)
        context.service.release(bookID: first.id)
        let restarted = BookStore(metadataFileURL: context.metadataURL)
        let resumed = try await context.service.read(item: context.item, format: context.format, store: restarted)
        #expect(resumed.id == first.id)
        #expect(resumed.currentPosition == 0.375)
        #expect(resumed.bookmarks == [bookmark])
        #expect(restarted.books.isEmpty)
        #expect(context.transport.downloadCount == 1)
        let shelved = try context.service.addToShelf(item: context.item, format: context.format, store: restarted)
        #expect(shelved.id == first.id)
        #expect(shelved.currentPosition == resumed.currentPosition)
        #expect(shelved.bookmarks == resumed.bookmarks)
        #expect(restarted.readingBooks.count == 1)
        #expect(restarted.books.map(\.id) == [first.id])
    }

    @Test("offline download does not join the shelf or mark the book as opened")
    func offlineDownloadIsIndependent() async throws {
        let bytes = Data("第一章\n完整離線正文。".utf8)
        let context = try Context(extension: "txt", data: bytes)
        defer { context.cleanup() }
        let downloaded = try await context.service.downloadOffline(item: context.item, format: context.format, store: context.store)
        #expect(context.store.books.isEmpty)
        #expect(downloaded.lastOpenedDate == nil)
        #expect(downloaded.remoteSource?.cachedFilename == nil)
        let filename = try #require(downloaded.remoteSource?.offlineFilename)
        #expect(try Data(contentsOf: StorageLocations.bookFile(filename)) == bytes)
        #expect(context.transport.downloadCount == 1)
        let again = try await context.service.downloadOffline(item: context.item, format: context.format, store: context.store)
        #expect(again.id == downloaded.id)
        #expect(context.transport.downloadCount == 1)
    }

    @Test("failed or cancelled offline downloads leave no completed copy and clean temporary files")
    func failedAndCancelledDownloadDoesNotPublish() async throws {
        for cancelled in [false, true] {
            let context = try Context(extension: "txt", data: Data("第一章\n正文。".utf8))
            defer { context.cleanup() }
            context.transport.downloadStatus = cancelled ? 200 : 401
            context.transport.cancelAfterDownload = cancelled
            let task = Task { try await context.service.downloadOffline(item: context.item,
                format: context.format, store: context.store) }
            do {
                _ = try await task.value
                Issue.record("Expected the offline download to fail")
            } catch {
                let record = try #require(context.service.book(for: context.item, format: context.format, store: context.store))
                #expect(record.remoteSource?.offlineFilename == nil)
                #expect(record.lastOpenedDate == nil)
                #expect(context.store.books.isEmpty)
                #expect(context.transport.temporaryFiles.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            }
        }
    }

    @Test("Markdown and PDF use the existing format pipelines without adding a shelf entry", arguments: ["md", "markdown", "pdf"])
    func fileFormatsUseExistingReaders(_ ext: String) async throws {
        let data: Data
        if ext == "pdf" {
            data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400)).pdfData { context in
                context.beginPage()
                "Remote PDF".draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 16)])
            }
        } else { data = Data("# 遠端 Markdown\n\n這是**正文**。".utf8) }
        let context = try Context(extension: ext, data: data)
        defer { context.cleanup() }
        let book = try await context.service.read(item: context.item, format: context.format, store: context.store)
        #expect(context.store.books.isEmpty)
        #expect(book.remoteSource?.offlineFilename == nil)
        #expect(book.resolvedPipelineKind == (ext == "pdf" ? .fixedPage : .txt))
        #expect(try Data(contentsOf: StorageLocations.bookFile(book.contentFilename)) == data)
        if ext == "pdf" { #expect(book.onlineChapters?.count == 1) }
    }

    @Test("uppercase extensions still select the EPUB reader")
    func uppercaseEPUBUsesEPUBPipeline() async throws {
        let source = try await EPUBTestFixtures.makeArchive(entries: EPUBTestFixtures.proseSmoke().entries)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let context = try Context(extension: "EPUB", data: try Data(contentsOf: source))
        defer { context.cleanup() }
        let book = try await context.service.read(item: context.item, format: context.format, store: context.store)
        #expect(book.resolvedPipelineKind == .epub)
        #expect(book.remoteSource?.format.fileExtension == "epub")
        #expect(context.service.publication(bookID: book.id) != nil)
        #expect(context.store.books.isEmpty)
    }

    @Test("weak ETags never identify reusable ZIP bytes across opens")
    func weakValidatorsDoNotReuseRanges() async throws {
        let context = try Context(extension: "epub", data: Data("bytes".utf8))
        defer { context.cleanup() }
        context.transport.entityTag = "W/\"semantic-only\""
        let probe = try await RemoteLibraryService.probe(context.format.url, epub: true, transport: context.transport)
        #expect(probe.supportsRanges)
        #expect(probe.version == nil)
        #expect(probe.entityTag == context.transport.entityTag)
    }

    @Test("an explicit offline copy reopens without an available connection")
    func offlineCopyOpensDisconnected() async throws {
        let context = try Context(extension: "txt", data: Data("第一章\n離線正文。".utf8))
        defer { context.cleanup() }
        let downloaded = try await context.service.downloadOffline(item: context.item, format: context.format, store: context.store)
        let before = context.transport.requestCount
        context.transport.headError = URLError(.notConnectedToInternet)
        let read = try await context.service.prepare(bookID: downloaded.id, store: context.store)
        #expect(context.transport.requestCount == before)
        #expect(read.id == downloaded.id)
        #expect(read.contentFilename == downloaded.remoteSource?.offlineFilename)
        #expect(context.store.books.isEmpty)
    }

    @Test("a server explicitly refusing Range opens a valid EPUB through automatic file cache")
    func noRangeEPUBUsesAutomaticFileCache() async throws {
        let source = try await EPUBTestFixtures.makeArchive(entries: EPUBTestFixtures.proseSmoke().entries)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let context = try Context(extension: "epub", data: try Data(contentsOf: source))
        defer { context.cleanup() }
        context.transport.supportsRanges = false
        let read = try await context.service.read(item: context.item, format: context.format, store: context.store)
        #expect(context.store.books.isEmpty)
        #expect(read.remoteSource?.offlineFilename == nil)
        #expect(read.remoteSource?.cachedFilename != nil)
        #expect(context.transport.downloadCount == 1)
        let publication = try #require(context.service.publication(bookID: read.id))
        let text = try await publication.chapterHTML(at: 0)
        #expect(text.contains("Simple prose paragraph."))
    }

    @Test("separate EPUB full-file caches named book.epub never share spine metadata")
    func fullFileCacheKeepsBookMetadataIsolated() async throws {
        for title in ["First remote EPUB", "Second remote EPUB"] {
            var entries = EPUBTestFixtures.proseSmoke().entries
            let opf = try #require(entries["OPS/package.opf"].flatMap { String(data: $0, encoding: .utf8) })
            entries["OPS/package.opf"] = Data(opf.replacingOccurrences(of: "<dc:title>Prose</dc:title>",
                with: "<dc:title>\(title)</dc:title>").utf8)
            let source = try await EPUBTestFixtures.makeArchive(entries: entries)
            defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
            let context = try Context(extension: "epub", data: try Data(contentsOf: source))
            defer { context.cleanup() }
            context.transport.supportsRanges = false
            let book = try await context.service.read(item: context.item, format: context.format, store: context.store)
            #expect(context.service.publication(bookID: book.id)?.bookTitle == title)
        }
    }

    @Test("authentication, timeout and malformed range-backed EPUB errors never trigger full download")
    func primaryFailuresNeverDownloadWholeEPUB() async throws {
        for failure in ["auth", "timeout", "invalid"] {
            let context = try Context(extension: "epub", data: Data("This is not an EPUB package.".utf8))
            defer { context.cleanup() }
            if failure == "auth" { context.transport.headStatus = 401 }
            if failure == "timeout" { context.transport.headError = URLError(.timedOut) }
            do {
                _ = try await context.service.read(item: context.item, format: context.format, store: context.store)
                Issue.record("Invalid primary response must fail")
            } catch {
                #expect(context.transport.downloadCount == 0)
                #expect(context.store.books.isEmpty)
                let record = try #require(context.service.book(for: context.item, format: context.format, store: context.store))
                #expect(record.remoteSource?.offlineFilename == nil)
                #expect(record.remoteSource?.cachedFilename == nil)
                #expect(context.service.publication(bookID: record.id) == nil)
            }
        }
    }

    @Test("overlapping requests for one book share completed preparation or offline output", arguments: [false, true])
    func overlappingRequestsFetchOnce(offline: Bool) async throws {
        let context = try Context(extension: "txt", data: Data("第一章\n並行閱讀正文。".utf8))
        defer { context.cleanup() }
        let started = ServiceTestEvent(), finish = ServiceTestEvent(), secondStarted = ServiceTestEvent()
        context.transport.beforeDownload = { started.signal(); await finish.wait() }
        let first = Task { try await context.open(offline: offline) }
        await started.wait()
        let second = Task {
            secondStarted.signal()
            return try await context.open(offline: offline)
        }
        await secondStarted.wait()
        finish.signal()
        let firstResult = await first.result
        let secondResult = await second.result
        #expect(context.transport.downloadCount == 1)
        let firstBook = try firstResult.get()
        let secondBook = try secondResult.get()
        #expect(firstBook.id == secondBook.id)
        #expect(context.store.readingBooks.count == 1)
        #expect(context.store.books.isEmpty)
        #expect(context.service.hasOfflineCopy(firstBook) == offline)
    }

    @Test("preparation commits resource fields without overwriting shelf membership or reading changes")
    func preparationPreservesConcurrentReadingChanges() async throws {
        let context = try Context(extension: "txt", data: Data("第一章\n保留閱讀紀錄。".utf8))
        defer { context.cleanup() }
        let started = ServiceTestEvent(), finish = ServiceTestEvent()
        context.transport.beforeDownload = { started.signal(); await finish.wait() }
        let task = Task { try await context.open(offline: false) }
        await started.wait()
        let shelved = try context.service.addToShelf(item: context.item, format: context.format, store: context.store)
        let bookmark = Bookmark(chapterIndex: 0, chapterTitle: "第一章",
            position: CoreTextReadingPosition(spineIndex: 0, charOffset: 8),
            note: "Keep", excerpt: "正文", date: Date(timeIntervalSinceReferenceDate: 100))
        context.store.addBookmark(bookId: shelved.id, bookmark: bookmark)
        context.store.updatePosition(bookId: shelved.id, position: 0.625, forceSave: true)
        context.store.updateLastOpened(bookId: shelved.id)
        finish.signal()
        let prepared = try await task.value
        #expect(prepared.isInBookshelf)
        #expect(prepared.currentPosition == 0.625)
        #expect(prepared.bookmarks == [bookmark])
        #expect(prepared.lastOpenedDate != nil)
        #expect(prepared.remoteSource?.cachedFilename != nil)
        let restarted = BookStore(metadataFileURL: context.metadataURL)
        #expect(restarted.books.first?.id == prepared.id)
        #expect(restarted.readingBook(id: prepared.id)?.bookmarks == [bookmark])
        #expect(restarted.readingBook(id: prepared.id)?.currentPosition == 0.625)
    }

    @Test("reader release invalidates pending preparation but leaves an explicit download independent", arguments: [false, true])
    func releaseInvalidatesPendingOperation(offline: Bool) async throws {
        let context = try Context(extension: "txt", data: Data("第一章\n作廢的回應。".utf8))
        defer { context.cleanup() }
        let started = ServiceTestEvent(), finish = ServiceTestEvent()
        context.transport.beforeDownload = { started.signal(); await finish.wait() }
        let task = Task { try await context.open(offline: offline) }
        await started.wait()
        let pending = try #require(context.service.book(for: context.item, format: context.format, store: context.store))
        context.service.release(bookID: pending.id)
        finish.signal()
        do {
            let result = try await task.value
            #expect(offline)
            #expect(context.service.hasOfflineCopy(result))
        } catch is CancellationError {
            #expect(!offline)
        } catch { Issue.record(error) }
        let saved = try #require(context.store.readingBook(id: pending.id))
        #expect(saved.remoteSource?.cachedFilename == nil)
        #expect((saved.remoteSource?.offlineFilename != nil) == offline)
        #expect(context.service.publication(bookID: pending.id) == nil)
        #expect(context.transport.temporaryFiles.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test("cancelling a queued caller completes promptly without cancelling another reader")
    func cancellingQueuedCallerLeavesOwnerRunning() async throws {
        let context = try Context(extension: "txt", data: Data("第一章\n保留另一個讀者。".utf8))
        defer { context.cleanup() }
        let started = ServiceTestEvent(), finish = ServiceTestEvent(), queuedStarted = ServiceTestEvent()
        context.transport.beforeDownload = { started.signal(); await finish.wait() }
        let owner = Task { try await context.open(offline: false) }
        await started.wait()
        let queued = Task { queuedStarted.signal(); return try await context.open(offline: false) }
        await queuedStarted.wait()
        queued.cancel()
        do { _ = try await queued.value; Issue.record("Queued caller should be cancelled") }
        catch is CancellationError {} catch { Issue.record(error) }
        #expect(context.transport.downloadCount == 1)
        finish.signal()
        let result = try await owner.value
        #expect(result.remoteSource?.cachedFilename != nil)
        #expect(context.store.books.isEmpty)
    }

    @Test("an explicit queued read may proceed after its predecessor is cancelled")
    func cancelledOwnerHandsOffAfterCleanup() async throws {
        let context = try Context(extension: "txt", data: Data("第一章\n下一個讀者。".utf8))
        defer { context.cleanup() }
        let started = ServiceTestEvent(), finish = ServiceTestEvent(), queuedStarted = ServiceTestEvent()
        context.transport.beforeDownload = { started.signal(); await finish.wait() }
        let owner = Task { try await context.open(offline: false) }
        await started.wait()
        let queued = Task { queuedStarted.signal(); return try await context.open(offline: false) }
        await queuedStarted.wait()
        owner.cancel()
        finish.signal()
        do { _ = try await owner.value; Issue.record("Owner should be cancelled") }
        catch is CancellationError {} catch { Issue.record(error) }
        let result = try await queued.value
        #expect(context.transport.downloadCount == 2)
        #expect(result.remoteSource?.cachedFilename != nil)
        #expect(context.store.books.isEmpty)
    }

    @Test("different books remain independent while another book is being fetched")
    func anotherBookDoesNotWait() async throws {
        let context = try Context(extension: "txt", data: Data("第一章\n各自獨立。".utf8))
        defer { context.cleanup() }
        let started = ServiceTestEvent(), finish = ServiceTestEvent()
        var heldFirst = false
        context.transport.beforeDownload = {
            if !heldFirst { heldFirst = true; started.signal(); await finish.wait() }
        }
        let first = Task { try await context.open(offline: false) }
        await started.wait()
        let otherItem = RemoteLibraryItem(id: UUID().uuidString, connectionID: context.item.connectionID,
            title: "Another book", formats: [context.format])
        let other = try await context.service.read(item: otherItem, format: context.format, store: context.store)
        finish.signal()
        let original = try await first.value
        #expect(original.id != other.id)
        #expect(context.transport.downloadCount == 2)
    }

    @Test("downloading an offline copy keeps an active TXT reader on its current resource")
    func offlineDownloadPreservesActiveTXTSource() async throws {
        let context = try Context(extension: "txt", data: Data("第一章\n不中斷閱讀。".utf8))
        defer { context.cleanup() }
        let reading = try await context.open(offline: false)
        let downloaded = try await context.open(offline: true)
        #expect(downloaded.contentFilename == reading.contentFilename)
        #expect(context.service.hasOfflineCopy(downloaded))
        context.service.release(bookID: reading.id)
        let reopened = try await context.open(offline: false)
        #expect(reopened.contentFilename == downloaded.remoteSource?.offlineFilename)
    }

    @Test("an updated resource address invalidates pending work with a visible error", arguments: [false, true])
    func rotatedAddressDiscardsOldDownload(offline: Bool) async throws {
        let context = try Context(extension: "txt", data: Data("第一章\n新的資源網址。".utf8))
        defer { context.cleanup() }
        let started = ServiceTestEvent(), finish = ServiceTestEvent()
        context.transport.beforeDownload = { started.signal(); await finish.wait() }
        let old = Task { try await context.open(offline: offline) }
        await started.wait()
        let oldBook = try #require(context.service.book(for: context.item, format: context.format, store: context.store))
        let format = RemoteLibraryFormat(url: URL(string: "https://library.example/updated.txt")!,
            fileExtension: "txt", mimeType: "text/plain")
        let item = RemoteLibraryItem(id: context.item.id, connectionID: context.item.connectionID,
            title: context.item.title, formats: [format])
        let added = try context.service.addToShelf(item: item, format: format, store: context.store)
        finish.signal()
        do { _ = try await old.value; Issue.record("Old address must not publish its file") }
        catch RemoteLibraryError.contentChanged {} catch { Issue.record(error) }
        #expect(added.id == oldBook.id)
        #expect(context.store.readingBook(id: oldBook.id)?.remoteSource?.offlineFilename == nil)
        let current = try await context.service.read(item: item, format: format, store: context.store)
        #expect(current.id == oldBook.id)
        #expect(current.remoteSource?.format.url == format.url)
        #expect(current.isInBookshelf)
    }

    @Test("server mutations notify an active reader without deleting its reading position")
    func invalidationReportsChangedContent() async throws {
        let context = try Context(extension: "txt", data: Data("第一章\n來源已變更。".utf8))
        defer { context.cleanup() }
        let book = try await context.open(offline: false)
        context.store.updatePosition(bookId: book.id, position: 0.5, forceSave: true)
        var failures: [RemoteLibraryReadFailure] = []
        let subscription = context.service.failurePublisher.sink { failures.append($0) }
        defer { subscription.cancel() }
        context.service.invalidate(bookID: book.id)
        #expect(failures.map(\.bookID) == [book.id])
        #expect(failures.first?.message == RemoteLibraryError.contentChanged.localizedDescription)
        #expect(context.store.readingBook(id: book.id)?.currentPosition == 0.5)
        #expect(context.store.books.isEmpty)
    }

    @MainActor
    private final class Context {
        let root: URL
        let metadataURL: URL
        let store: BookStore
        let service: RemoteLibraryService
        let transport: ServiceFixtureTransport
        let item: RemoteLibraryItem
        let format: RemoteLibraryFormat

        init(extension ext: String, data: Data) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteLibraryServiceTests-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            metadataURL = root.appendingPathComponent("books_meta.json")
            try Data("[]".utf8).write(to: metadataURL)
            store = BookStore(metadataFileURL: metadataURL)
            let connections = RemoteLibraryConnectionStore(storageDirectory: root, importLegacyWebDAV: false)
            let connection = connections.add(name: "Fixture library", url: "https://library.example/",
                username: nil, password: nil, kind: .webDAV)
            let fixtureTransport = ServiceFixtureTransport(data: data,
                mimeType: ext == "epub" ? "application/epub+zip" : "text/plain")
            transport = fixtureTransport
            service = RemoteLibraryService(connections: connections,
                cache: RemoteLibraryCache(root: StorageLocations.remoteLibraryCache),
                transportFactory: { _ in fixtureTransport })
            format = RemoteLibraryFormat(url: URL(string: "https://library.example/book." + ext)!,
                fileExtension: ext, mimeType: ext == "epub" ? "application/epub+zip" : "text/plain")
            item = RemoteLibraryItem(id: "remote-entry-" + UUID().uuidString, connectionID: connection.id,
                title: "Remote test book", formats: [format])
        }

        func open(offline: Bool) async throws -> ReadingBook {
            if offline { return try await service.downloadOffline(item: item, format: format, store: store) }
            return try await service.read(item: item, format: format, store: store)
        }

        func cleanup() {
            for book in store.readingBooks {
                service.release(bookID: book.id)
                try? FileManager.default.removeItem(at: StorageLocations.remoteLibraryCache.appendingPathComponent(book.id.uuidString))
                if let offline = book.remoteSource?.offlineFilename {
                    try? FileManager.default.removeItem(at: StorageLocations.bookFile(offline))
                }
            }
            for file in transport.temporaryFiles { try? FileManager.default.removeItem(at: file) }
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private final class ServiceFixtureTransport: RemoteLibraryTransport {
    let data: Data
    let mimeType: String
    var supportsRanges = true
    var headStatus = 200
    var downloadStatus = 200
    var headError: Error?
    var cancelAfterDownload = false
    var entityTag = "\"service-fixture\""
    var beforeDownload: (@MainActor () async throws -> Void)?
    private(set) var requestCount = 0
    private(set) var downloadCount = 0
    private(set) var temporaryFiles: [URL] = []

    init(data: Data, mimeType: String) { self.data = data; self.mimeType = mimeType }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        try Task.checkCancellation()
        if let headError { throw headError }
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: headStatus,
            httpVersion: "HTTP/1.1", headerFields: headers(length: data.count))!)
    }

    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        requestCount += 1
        downloadCount += 1
        try Task.checkCancellation()
        try await beforeDownload?()
        try Task.checkCancellation()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: file)
        temporaryFiles.append(file)
        if cancelAfterDownload { withUnsafeCurrentTask { $0?.cancel() } }
        return (file, HTTPURLResponse(url: request.url!, statusCode: downloadStatus,
            httpVersion: "HTTP/1.1", headerFields: headers(length: data.count))!)
    }

    func stream(request convertible: any HTTPRequestConvertible,
                consume: @escaping (Data, Double?) -> HTTPResult<Void>) async -> HTTPResult<HTTPResponse> {
        requestCount += 1
        if Task.isCancelled { return .failure(.cancelled) }
        if !supportsRanges { return .failure(.rangeNotSupported) }
        let request: HTTPRequest
        switch convertible.httpRequest() {
        case .failure(let error): return .failure(error)
        case .success(let value): request = value
        }
        guard let range = request.headers.first(where: { $0.key.lowercased() == "range" })?.value,
              range.hasPrefix("bytes=") else { return .failure(.malformedRequest(url: request.url.string)) }
        let parts = range.dropFirst(6).split(separator: "-")
        guard parts.count == 2, let lower = Int(parts[0]), let inclusiveUpper = Int(parts[1]),
              lower >= 0, lower < data.count else { return .failure(.malformedResponse(nil)) }
        let upper = min(data.count, inclusiveUpper + 1)
        let body = data.subdata(in: lower..<upper)
        if case .failure(let error) = consume(body, 1) { return .failure(error) }
        var responseHeaders = headers(length: body.count)
        responseHeaders["Content-Range"] = "bytes \(lower)-\(upper - 1)/\(data.count)"
        return .success(HTTPResponse(request: request, url: request.url, status: .partialContent,
            headers: responseHeaders, mediaType: MediaType(mimeType), body: nil))
    }

    private func headers(length: Int) -> [String: String] {
        ["Content-Length": String(length), "Content-Type": mimeType, "ETag": entityTag, "Accept-Ranges": "bytes"]
    }
}

/// Explicit start/finish signals keep overlap tests independent of clock timing.
@MainActor
private final class ServiceTestEvent {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        signalled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
