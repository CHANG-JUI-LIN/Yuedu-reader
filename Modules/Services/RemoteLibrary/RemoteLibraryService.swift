import Combine
import Foundation
import ReadiumShared
import UIKit

@MainActor
protocol RemoteLibraryServing: AnyObject {
    var failurePublisher: AnyPublisher<RemoteLibraryReadFailure, Never> { get }
    func book(for item: RemoteLibraryItem, format: RemoteLibraryFormat, store: BookStore) -> ReadingBook?
    func read(item: RemoteLibraryItem, format: RemoteLibraryFormat, store: BookStore) async throws -> ReadingBook
    func addToShelf(item: RemoteLibraryItem, format: RemoteLibraryFormat, store: BookStore) throws -> ReadingBook
    func downloadOffline(item: RemoteLibraryItem, format: RemoteLibraryFormat, store: BookStore) async throws -> ReadingBook
    func prepare(bookID: UUID, store: BookStore) async throws -> ReadingBook
    func publication(bookID: UUID) -> PublicationSession?
    func hasOfflineCopy(_ book: ReadingBook) -> Bool
    func release(bookID: UUID)
}

@MainActor
final class RemoteLibraryService: RemoteLibraryServing {
    static let shared = RemoteLibraryService()
    private let connections: RemoteLibraryConnectionStore
    let cache: RemoteLibraryCache
    private let transportFactory: ((RemoteLibraryConnection) -> any RemoteLibraryTransport)?
    private var publications: [UUID: PublicationSession] = [:]
    private var preparedBooks: Set<UUID> = []
    private let operations = RemoteLibraryBookOperations()
    private let readFailures = PassthroughSubject<RemoteLibraryReadFailure, Never>()
    var failurePublisher: AnyPublisher<RemoteLibraryReadFailure, Never> { readFailures.eraseToAnyPublisher() }

    func reportReadFailure(_ failure: RemoteLibraryReadFailure) {
        readFailures.send(failure)
    }

    init(connections: RemoteLibraryConnectionStore = .shared,
         cache: RemoteLibraryCache = .shared,
         transportFactory: ((RemoteLibraryConnection) -> any RemoteLibraryTransport)? = nil) {
        self.connections = connections; self.cache = cache; self.transportFactory = transportFactory
    }

    func book(for item: RemoteLibraryItem, format: RemoteLibraryFormat, store: BookStore) -> ReadingBook? {
        store.readingBooks.first { $0.remoteSource?.matches(item: item, format: format) == true }
    }

    private func record(item: RemoteLibraryItem, format: RemoteLibraryFormat, store: BookStore) throws -> ReadingBook {
        guard format.isSupported, item.formats.contains(format) else { throw RemoteLibraryError.unsupportedFormat }
        if var existing = book(for: item, format: format, store: store) {
            // Acquisition URLs may rotate while the catalog's book identity stays stable.
            if existing.remoteSource?.format.url != format.url {
                invalidate(bookID: existing.id)
                existing.remoteSource?.version = nil
                existing.remoteSource?.entityTag = nil
                existing.remoteSource?.lastModified = nil
                existing.remoteSource?.contentLength = nil
                existing.remoteSource?.cachedFilename = nil
            }
            existing.remoteSource?.format = format
            store.saveReadingBook(existing)
            return existing
        }
        var book = ReadingBook(title: item.title, author: item.author ?? localized("未知作者"),
            source: format.fileExtension == "epub" ? "local_epub" : "local",
            contentFilename: UUID().uuidString + "." + format.fileExtension)
        book.isInBookshelf = false
        book.remoteSource = RemoteBookReference(connectionID: item.connectionID, entryID: item.id, format: format)
        book.coverUrl = item.coverURL?.absoluteString
        if format.fileExtension == "pdf" { book.contentPipelineKind = .fixedPage }
        store.saveReadingBook(book)
        return book
    }

    func addToShelf(item: RemoteLibraryItem, format: RemoteLibraryFormat, store: BookStore) throws -> ReadingBook {
        let book = try record(item: item, format: format, store: store)
        guard let saved = store.addReadingBookToShelf(id: book.id) else { throw RemoteLibraryError.missingBook }
        return saved
    }

    func read(item: RemoteLibraryItem, format: RemoteLibraryFormat, store: BookStore) async throws -> ReadingBook {
        try Task.checkCancellation()
        let book = try record(item: item, format: format, store: store)
        return try await prepare(bookID: book.id, store: store)
    }

    func publication(bookID: UUID) -> PublicationSession? { publications[bookID] }

    func release(bookID: UUID) {
        operations.invalidate(bookID: bookID, kind: .preparation)
        releasePreparedResources(bookID: bookID)
    }

    /// A server mutation invalidates content, unlike closing a reader. Keep the
    /// reason visible to pending opens and readers already holding this source.
    func invalidate(bookID: UUID) {
        operations.invalidate(bookID: bookID, error: RemoteLibraryError.contentChanged)
        releasePreparedResources(bookID: bookID)
        reportReadFailure(RemoteLibraryReadFailure(bookID: bookID,
            message: RemoteLibraryError.contentChanged.localizedDescription))
    }

    private func releasePreparedResources(bookID: UUID) {
        publications.removeValue(forKey: bookID)
        if preparedBooks.remove(bookID) != nil { cache.release(bookID) }
    }

    private func markPrepared(_ bookID: UUID) {
        if preparedBooks.insert(bookID).inserted { cache.retain(bookID) }
    }

    func hasOfflineCopy(_ book: ReadingBook) -> Bool {
        guard let filename = book.remoteSource?.offlineFilename else { return false }
        return FileManager.default.fileExists(atPath: StorageLocations.bookFile(filename).path)
    }

    private func localURL(_ filename: String) -> URL {
        let prefix = "__remote_cache__/"
        if filename.hasPrefix(prefix) {
            return cache.root.appendingPathComponent(String(filename.dropFirst(prefix.count)))
        }
        return StorageLocations.bookFile(filename)
    }

    private func transport(for reference: RemoteBookReference) throws -> any RemoteLibraryTransport {
        guard let connection = connections.connection(id: reference.connectionID) else {
            throw RemoteLibraryError.missingConnection
        }
        return transportFactory?(connection) ?? connections.httpClient(for: connection)
    }

    func prepare(bookID: UUID, store: BookStore) async throws -> ReadingBook {
        let operation = try await operations.acquire(bookID: bookID, kind: .preparation)
        defer { operations.finish(operation) }
        return try await prepare(bookID: bookID, store: store, operation: operation)
    }

    private func prepare(bookID: UUID, store: BookStore,
                         operation: RemoteLibraryBookOperations.Lease) async throws -> ReadingBook {
        try operations.validate(operation)
        guard var book = store.readingBook(id: bookID), var reference = book.remoteSource else {
            throw RemoteLibraryError.missingBook
        }
        if preparedBooks.contains(bookID) { return book }
        cache.retain(bookID)
        defer { cache.release(bookID) }
        if let offline = reference.offlineFilename,
           FileManager.default.fileExists(atPath: StorageLocations.bookFile(offline).path) {
            book.contentFilename = offline
            return try await prepareLocal(book: book, store: store, operation: operation)
        }
        let transport = try transport(for: reference)
        let probe: Probe
        do {
            probe = try await Self.probe(reference.format.url, epub: reference.format.fileExtension == "epub", transport: transport)
        } catch {
            // Only an offline/unreachable server may use a previously obtained
            // version. Auth and corrupt responses must remain visible failures.
            // Remove this branch if offline reading of automatic caches is removed.
            guard Self.isOffline(error) else { throw error }
            if let cached = reference.cachedFilename,
               FileManager.default.fileExists(atPath: localURL(cached).path) {
                book.contentFilename = cached
                return try await prepareLocal(book: book, store: store, operation: operation)
            }
            if reference.format.fileExtension == "epub", let length = reference.contentLength,
               let version = reference.version {
                probe = Probe(length: length, supportsRanges: true, entityTag: reference.entityTag,
                              lastModified: reference.lastModified, version: version)
            } else { throw error }
        }
        try operations.validate(operation)
        // Unknown server versions never share resource bytes across online opens.
        let version = probe.version ?? UUID().uuidString
        let directory = try cache.directory(bookID: bookID, version: version)
        if reference.version != version {
            reference.cachedFilename = nil
        }
        reference.version = version
        reference.contentLength = probe.length
        reference.entityTag = probe.entityTag
        reference.lastModified = probe.lastModified
        book.remoteSource = reference

        if reference.format.fileExtension == "epub", probe.supportsRanges, let length = probe.length,
           let url = HTTPURL(url: reference.format.url) {
            let client = RemoteLibraryResourceClient(transport: transport, url: url, length: length,
                entityTag: probe.entityTag, lastModified: probe.lastModified, directory: directory,
                onFailure: { [weak self] error in
                    guard let failure = RemoteLibraryReadFailure(bookID: bookID, error: error) else { return }
                    Task { @MainActor [weak self] in self?.reportReadFailure(failure) }
                })
            let session = try await PublicationSession.open(remoteURL: reference.format.url,
                bookID: bookID, httpClient: client, version: version, cacheDirectory: directory)
            return try commitPreparation(book, session: session, store: store, operation: operation)
        }

        // TXT/Markdown/PDF require a complete file in the existing parsers.
        // EPUB reaches this branch only after a successful probe proved Range
        // or length unavailable, never after a parser/auth/network failure.
        let target = directory.appendingPathComponent("book." + reference.format.fileExtension)
        let createdCache = !FileManager.default.fileExists(atPath: target.path)
        do {
            if createdCache {
                try await download(reference: reference, transport: transport, to: target, operation: operation)
            }
            book.contentFilename = "__remote_cache__/" + bookID.uuidString + "/"
                + directory.lastPathComponent + "/" + target.lastPathComponent
            book.remoteSource?.cachedFilename = book.contentFilename
            return try await prepareLocal(book: book, store: store, operation: operation)
        } catch {
            if createdCache, FileManager.default.fileExists(atPath: target.path) {
                do { try FileManager.default.removeItem(at: target) }
                catch { AppLogger.error("Invalid remote cache cleanup failed", error: error) }
            }
            throw error
        }
    }

    private func prepareLocal(book: ReadingBook, store: BookStore,
                              operation: RemoteLibraryBookOperations.Lease) async throws -> ReadingBook {
        try operations.validate(operation)
        var book = book
        var session: PublicationSession?
        let url = localURL(book.contentFilename)
        switch book.remoteSource?.format.fileExtension {
        case "epub":
            let version = book.remoteSource?.offlineFilename == book.contentFilename
                ? "offline-" + book.contentFilename : book.remoteSource?.version ?? UUID().uuidString
            let directory = try cache.directory(bookID: book.id, version: version)
            session = try await PublicationSession.open(sourceURL: url, cacheDirectory: directory)
        case "pdf":
            let info = try LocalPDFArchive.inspect(url: url)
            book.contentPipelineKind = .fixedPage
            book.onlineChapters = [LocalPDFArchive.chapterRef(for: info, filename: book.contentFilename, bookTitle: book.title)]
        case "txt", "md", "markdown":
            // Reading uses TXTReaderPreparationService / MarkdownAttributedStringBuilder.
            // Validate decodability here without importing or adding a shelf entry.
            _ = try await Task.detached { try TXTMetadataProbe.probe(url: url, fallbackTitle: url.deletingPathExtension().lastPathComponent) }.value
        default: throw RemoteLibraryError.unsupportedFormat
        }
        return try commitPreparation(book, session: session, store: store, operation: operation)
    }

    private func currentBook(matching book: ReadingBook, store: BookStore,
                             operation: RemoteLibraryBookOperations.Lease) throws -> ReadingBook {
        try operations.validate(operation)
        guard let current = store.readingBook(id: book.id) else { throw RemoteLibraryError.missingBook }
        guard let expected = book.remoteSource, let actual = current.remoteSource,
              expected.connectionID == actual.connectionID, expected.entryID == actual.entryID,
              expected.format.id == actual.format.id else { throw RemoteLibraryError.contentChanged }
        return current
    }

    private func commitPreparation(_ prepared: ReadingBook, session: PublicationSession?, store: BookStore,
                                    operation: RemoteLibraryBookOperations.Lease) throws -> ReadingBook {
        var current = try currentBook(matching: prepared, store: store, operation: operation)
        // Awaiting transport/parser work does not grant ownership of reading
        // progress, bookmarks, metadata, shelf membership or an offline copy.
        current.contentFilename = prepared.contentFilename
        current.remoteSource?.version = prepared.remoteSource?.version
        current.remoteSource?.entityTag = prepared.remoteSource?.entityTag
        current.remoteSource?.lastModified = prepared.remoteSource?.lastModified
        current.remoteSource?.contentLength = prepared.remoteSource?.contentLength
        current.remoteSource?.cachedFilename = prepared.remoteSource?.cachedFilename
        if prepared.remoteSource?.format.fileExtension == "pdf" {
            current.contentPipelineKind = prepared.contentPipelineKind
            current.onlineChapters = prepared.onlineChapters
        }
        store.saveReadingBook(current)
        if let session { publications[current.id] = session }
        markPrepared(current.id)
        return current
    }

    func downloadOffline(item: RemoteLibraryItem, format: RemoteLibraryFormat, store: BookStore) async throws -> ReadingBook {
        try Task.checkCancellation()
        let recorded = try record(item: item, format: format, store: store)
        let operation = try await operations.acquire(bookID: recorded.id, kind: .offlineDownload)
        defer { operations.finish(operation) }
        var book = try currentBook(matching: recorded, store: store, operation: operation)
        guard let reference = book.remoteSource else { throw RemoteLibraryError.missingBook }
        let filename = "remote_" + book.id.uuidString + "." + format.fileExtension
        let target = StorageLocations.bookFile(filename)
        if let offline = reference.offlineFilename,
           FileManager.default.fileExists(atPath: StorageLocations.bookFile(offline).path) { return book }
        let transport = try transport(for: reference)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + format.fileExtension)
        defer { do { if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) } }
            catch { AppLogger.error("Remote staging cleanup failed", error: error) } }
        try await download(reference: reference, transport: transport, to: staging, operation: operation)
        // Validate the requested format before marking the offline copy complete.
        switch format.fileExtension {
        case "epub": _ = try await PublicationSession.open(sourceURL: staging)
        case "pdf": _ = try LocalPDFArchive.inspect(url: staging)
        default: _ = try await Task.detached { try TXTMetadataProbe.probe(url: staging, fallbackTitle: staging.deletingPathExtension().lastPathComponent) }.value
        }
        book = try currentBook(matching: book, store: store, operation: operation)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.moveItem(at: staging, to: target)
        book.remoteSource?.offlineFilename = filename
        // Do not change the live source underneath an active reader.
        if !preparedBooks.contains(book.id) { book.contentFilename = filename }
        store.saveReadingBook(book)
        return book
    }

    private func download(reference: RemoteBookReference, transport: any RemoteLibraryTransport, to target: URL,
                          operation: RemoteLibraryBookOperations.Lease) async throws {
        var request = URLRequest(url: reference.format.url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let etag = reference.entityTag, !etag.hasPrefix("W/") { request.setValue(etag, forHTTPHeaderField: "If-Match") }
        else if let modified = reference.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Unmodified-Since") }
        let (temporary, response) = try await transport.download(for: request)
        defer { if FileManager.default.fileExists(atPath: temporary.path) {
            do { try FileManager.default.removeItem(at: temporary) }
            catch { AppLogger.error("Remote download cleanup failed", error: error) }
        } }
        try RemoteLibraryHTTPClient.validate(response)
        guard response.statusCode != 204, response.mimeType != "text/html" else { throw RemoteLibraryError.invalidResponse }
        if let expected = reference.entityTag, let actual = response.value(forHTTPHeaderField: "ETag"), expected != actual {
            throw RemoteLibraryError.contentChanged
        }
        if let expected = reference.lastModified,
           let actual = response.value(forHTTPHeaderField: "Last-Modified"), expected != actual {
            throw RemoteLibraryError.contentChanged
        }
        try operations.validate(operation)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temporary, to: target)
    }

    struct Probe {
        let length: Int64?
        let supportsRanges: Bool
        let entityTag: String?
        let lastModified: String?
        let version: String?
    }

    static func probe(_ url: URL, epub: Bool, transport: any RemoteLibraryTransport) async throws -> Probe {
        guard let httpURL = HTTPURL(url: url) else { throw RemoteLibraryError.invalidResponse }
        var headRequest = URLRequest(url: url)
        headRequest.httpMethod = "HEAD"
        headRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (_, head) = try await transport.data(for: headRequest)
        if head.statusCode != 405 && head.statusCode != 501 { try RemoteLibraryHTTPClient.validate(head) }
        let usableHead = (200...299).contains(head.statusCode)
        var length = usableHead ? head.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init) : nil
        var entityTag = usableHead ? head.value(forHTTPHeaderField: "ETag") : nil
        var modified = usableHead ? head.value(forHTTPHeaderField: "Last-Modified") : nil
        var supportsRanges = false
        if epub {
            let result = await transport.fetch(HTTPRequest(url: httpURL, headers: ["Range": "bytes=0-0", "Accept-Encoding": "identity"]))
            switch result {
            case .success(let response):
                if let total = response.valueForHeader("Content-Range")?.split(separator: "/").last,
                   let actualLength = Int64(total), actualLength > 0 {
                    length = actualLength
                    supportsRanges = response.status.rawValue == 206
                }
                entityTag = response.valueForHeader("ETag") ?? entityTag
                modified = response.valueForHeader("Last-Modified") ?? modified
            case .failure(.rangeNotSupported): break
            case .failure(let error): throw error
            }
        }
        if let value = length, value <= 0 { length = nil }
        // A weak ETag describes semantic equivalence, not identical ZIP bytes.
        // Only strong validators may reuse byte ranges across online sessions.
        let strongTag = entityTag.flatMap { $0.hasPrefix("W/") ? nil : $0 }
        let version = strongTag.map { "etag:" + $0 }
            ?? modified.map { "modified:" + $0 + ":" + String(length ?? -1) }
        return Probe(length: length, supportsRanges: supportsRanges && length != nil,
                     entityTag: entityTag, lastModified: modified, version: version)
    }

    private static func isOffline(_ error: Error) -> Bool {
        if let error = error as? URLError {
            return [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost].contains(error.code)
        }
        if let error = error as? HTTPError {
            switch error { case .offline, .unreachable: return true; default: break }
        }
        return false
    }
}
