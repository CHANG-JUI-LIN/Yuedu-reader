import Foundation

struct RemoteLibraryWriteCapabilities: Equatable, Sendable {
    var canUpload = false
    var canEditMetadata = false
    var canCreateFolder = false
    var canMove = false
    var unsupportedReasonKey: String?
    /// Feature availability is not a claim that the server account can write.
    /// Calibre exposes no read-only permission probe; the mutation enforces it.
    var permissionRequiresServerCheck = true
}

struct RemoteLibraryWriteResult: Equatable, Sendable {
    var bookID: Int?
    var resourceURL: URL?
}

enum RemoteLibraryWriteError: LocalizedError, Equatable {
    case unsupported, permissionDenied, alreadyExists, duplicateBook
    case invalidName, invalidDestination, redirectRejected, invalidResponse
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .unsupported: return localized("此伺服器未提供支援的書庫寫入介面")
        case .permissionDenied: return localized("此帳號沒有遠端書庫寫入權限")
        case .alreadyExists: return localized("目的地已有同名檔案或資料夾")
        case .duplicateBook: return localized("遠端書庫已有相同書籍，未重複加入")
        case .invalidName: return localized("請輸入有效的名稱")
        case .invalidDestination: return localized("目的地必須位於目前連線的書庫內")
        case .redirectRejected: return localized("寫入網址發生重新導向，請確認伺服器網址")
        case .invalidResponse: return localized("無法確認遠端操作結果，請重新整理書庫")
        case .http(let status): return String(format: localized("遠端書庫操作失敗（HTTP %d）"), status)
        }
    }

    static func validate(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200...299: break
        case 401: throw OPDSError.authenticationFailed
        case 403: throw Self.permissionDenied
        case 412: throw Self.alreadyExists
        case 300...399: throw Self.redirectRejected
        default: throw Self.http(response.statusCode)
        }
        if ["text/html", "application/xhtml+xml"].contains(response.mimeType?.lowercased() ?? "") {
            throw OPDSError.loginPage
        }
    }
}

extension Notification.Name {
    static let remoteLibraryDidChange = Notification.Name("remoteLibraryDidChange")
}

@MainActor
protocol RemoteLibraryWriting: AnyObject {
    func capabilities(connectionID: String, directoryURL: URL?) async throws -> RemoteLibraryWriteCapabilities
    func upload(fileURL: URL, connectionID: String, directoryURL: URL?) async throws -> RemoteLibraryWriteResult
    func updateMetadata(item: RemoteLibraryItem, title: String, authors: [String], readingStore: BookStore?) async throws
    func createFolder(name: String, connectionID: String, directoryURL: URL) async throws -> URL
    func move(item: RemoteLibraryItem, toName: String, readingStore: BookStore?) async throws -> URL
}

@MainActor
final class RemoteLibraryWritingService: RemoteLibraryWriting {
    private let store: OPDSCatalogStore
    private let transportFactory: ((OPDSCatalog) -> any RemoteLibraryTransport)?
    private let invalidateReadingResources: ((UUID) -> Void)?

    init(store: OPDSCatalogStore = .shared,
         transportFactory: ((OPDSCatalog) -> any RemoteLibraryTransport)? = nil,
         invalidateReadingResources: ((UUID) -> Void)? = nil) {
        self.store = store
        self.transportFactory = transportFactory
        self.invalidateReadingResources = invalidateReadingResources
    }

    func capabilities(connectionID: String, directoryURL: URL? = nil) async throws -> RemoteLibraryWriteCapabilities {
        let connection = try connection(connectionID)
        switch connection.kind {
        case .opds:
            return RemoteLibraryWriteCapabilities(unsupportedReasonKey: "此伺服器未提供支援的書庫寫入介面")
        case .webDAV:
            try validateDAVURL(directoryURL ?? connectionURL(connection), connection: connection, allowRoot: true)
            return RemoteLibraryWriteCapabilities(canUpload: true, canCreateFolder: true, canMove: true)
        case .calibre:
            do {
                _ = try await calibreAPI(connection).selectedLibrary(connectionURL: connection.url, directoryURL: directoryURL)
                return RemoteLibraryWriteCapabilities(canUpload: true, canEditMetadata: true)
            } catch RemoteLibraryWriteError.unsupported {
                return RemoteLibraryWriteCapabilities(unsupportedReasonKey: "此伺服器未提供支援的書庫寫入介面")
            }
        }
    }

    func upload(fileURL: URL, connectionID: String, directoryURL: URL? = nil) async throws -> RemoteLibraryWriteResult {
        let connection = try connection(connectionID)
        guard fileURL.isFileURL else { throw RemoteLibraryWriteError.invalidDestination }
        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { throw RemoteLibraryWriteError.invalidName }
        let filename = try validName(fileURL.lastPathComponent)
        let ext = fileURL.pathExtension.lowercased()
        guard ["epub", "pdf", "txt", "md", "markdown"].contains(ext) else { throw RemoteLibraryError.unsupportedFormat }
        var request: URLRequest
        var libraryID: String?
        switch connection.kind {
        case .opds: throw RemoteLibraryWriteError.unsupported
        case .calibre:
            let api = try calibreAPI(connection)
            let selected = try await api.selectedLibrary(connectionURL: connection.url, directoryURL: directoryURL)
            libraryID = selected
            // job_id only correlates the response; it is NOT an idempotency key.
            // Never retry an uncertain upload. "n" explicitly disables duplicates.
            request = URLRequest(url: try api.address.endpoint(["cdb", "add-book", UUID().uuidString, "n", filename, selected]))
            request.httpMethod = "POST"
        case .webDAV:
            let directory = try directoryURL ?? connectionURL(connection)
            try validateDAVURL(directory, connection: connection, allowRoot: true)
            let destination = directory.appendingPathComponent(filename, isDirectory: false)
            try validateDAVURL(destination, connection: connection)
            request = URLRequest(url: destination)
            request.httpMethod = "PUT"
            request.setValue("*", forHTTPHeaderField: "If-None-Match")
        }
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(String(values.fileSize ?? 0), forHTTPHeaderField: "Content-Length")
        request.timeoutInterval = 300
        let (data, response) = try await transport(connection).upload(for: request, fromFile: fileURL)
        try RemoteLibraryWriteError.validate(response)
        let result: RemoteLibraryWriteResult
        if let libraryID {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw RemoteLibraryWriteError.invalidResponse
            }
            if json["duplicates"] != nil { throw RemoteLibraryWriteError.duplicateBook }
            guard let id = json["book_id"] as? Int, id > 0 else { throw RemoteLibraryWriteError.invalidResponse }
            let url = try calibreAPI(connection).address.endpoint(["get", ext.uppercased(), String(id), libraryID])
            result = RemoteLibraryWriteResult(bookID: id, resourceURL: url)
        } else {
            // RFC 4918: PUT that creates a resource returns 201. Do not report an
            // unexpected multi-status or an overwritten resource as a new upload.
            guard response.statusCode == 201 else { throw RemoteLibraryWriteError.invalidResponse }
            result = RemoteLibraryWriteResult(resourceURL: request.url)
        }
        didChange(connectionID)
        return result
    }

    func updateMetadata(item: RemoteLibraryItem, title: String, authors: [String], readingStore: BookStore? = nil) async throws {
        let connection = try connection(item.connectionID)
        guard connection.kind == .calibre else { throw RemoteLibraryWriteError.unsupported }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let authors = authors.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !title.isEmpty, !authors.isEmpty else { throw RemoteLibraryWriteError.invalidName }
        let locator = try CalibreBookLocator(item: item, connection: connection)
        let info = try await calibreAPI(connection).libraryInfo()
        guard info.libraryMap[locator.libraryID] != nil else { throw RemoteLibraryWriteError.invalidDestination }
        var request = URLRequest(url: try locator.address.endpoint(["cdb", "set-fields", String(locator.bookID), locator.libraryID]))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "changes": ["title": title, "authors": authors],
            "loaded_book_ids": [locator.bookID], "all_dirtied": false
        ])
        let (data, response) = try await transport(connection).data(for: request)
        try RemoteLibraryWriteError.validate(response)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let updated = json[String(locator.bookID)] as? [String: Any],
              let savedTitle = updated["title"] as? String, let savedAuthors = updated["authors"] as? [String] else {
            throw RemoteLibraryWriteError.invalidResponse
        }
        for var book in readingStore?.readingBooks ?? [] where book.remoteSource?.connectionID == item.connectionID {
            guard let reference = book.remoteSource,
                  let other = try? CalibreBookLocator(reference: reference, connection: connection),
                  other.libraryID == locator.libraryID, other.bookID == locator.bookID else { continue }
            // Calibre rewrites served EPUB/PDF metadata after this change, so
            // release open resources and let the normal version probe refresh.
            invalidateReadingResources?(book.id)
            book.title = savedTitle
            book.author = savedAuthors.joined(separator: ", ")
            readingStore?.saveReadingBook(book)
        }
        didChange(item.connectionID)
    }

    func createFolder(name: String, connectionID: String, directoryURL: URL) async throws -> URL {
        let connection = try connection(connectionID)
        guard connection.kind == .webDAV else { throw RemoteLibraryWriteError.unsupported }
        try validateDAVURL(directoryURL, connection: connection, allowRoot: true)
        let destination = directoryURL.appendingPathComponent(try validName(name), isDirectory: true)
        try validateDAVURL(destination, connection: connection)
        var request = URLRequest(url: destination)
        request.httpMethod = "MKCOL"
        let (_, response) = try await transport(connection).data(for: request)
        if response.statusCode == 405 { throw RemoteLibraryWriteError.alreadyExists }
        try RemoteLibraryWriteError.validate(response)
        guard response.statusCode == 201 else { throw RemoteLibraryWriteError.invalidResponse }
        didChange(connectionID)
        return destination
    }

    func move(item: RemoteLibraryItem, toName: String, readingStore: BookStore? = nil) async throws -> URL {
        guard let source = item.formats.first?.url else { throw RemoteLibraryWriteError.invalidDestination }
        let name = try validName(toName)
        // A rename must retain the file format used by its reader and bookmarks.
        guard (name as NSString).pathExtension.caseInsensitiveCompare(source.pathExtension) == .orderedSame else {
            throw RemoteLibraryWriteError.invalidName
        }
        let destination = source.deletingLastPathComponent().appendingPathComponent(name)
        try await performMove(itemURL: source, to: destination, connectionID: item.connectionID)
        reconcileMove(source: source, destination: destination, connectionID: item.connectionID, readingStore: readingStore)
        didChange(item.connectionID)
        return destination
    }

    private func reconcileMove(source: URL, destination: URL, connectionID: String, readingStore: BookStore?) {
        for var book in readingStore?.readingBooks ?? [] {
            guard let old = book.remoteSource, old.connectionID == connectionID, old.format.url == source else { continue }
            invalidateReadingResources?(book.id)
            let format = RemoteLibraryFormat(url: destination, fileExtension: old.format.fileExtension,
                                            mimeType: old.format.mimeType, size: old.format.size)
            book.remoteSource = RemoteBookReference(connectionID: old.connectionID, entryID: destination.absoluteString,
                format: format, version: old.version, contentLength: old.contentLength,
                entityTag: old.entityTag, lastModified: old.lastModified, cachedFilename: old.cachedFilename,
                offlineFilename: old.offlineFilename)
            book.title = destination.deletingPathExtension().lastPathComponent
            readingStore?.saveReadingBook(book)
        }
    }

    func move(itemURL: URL, to destinationURL: URL, connectionID: String, readingStore: BookStore? = nil) async throws {
        try await performMove(itemURL: itemURL, to: destinationURL, connectionID: connectionID)
        reconcileMove(source: itemURL, destination: destinationURL, connectionID: connectionID, readingStore: readingStore)
        didChange(connectionID)
    }

    private func performMove(itemURL: URL, to destinationURL: URL, connectionID: String) async throws {
        let connection = try connection(connectionID)
        guard connection.kind == .webDAV else { throw RemoteLibraryWriteError.unsupported }
        try validateDAVURL(itemURL, connection: connection)
        try validateDAVURL(destinationURL, connection: connection)
        // This first version moves book files, not whole folder trees. Keep the
        // same format so existing reader positions still identify the same book.
        guard !itemURL.hasDirectoryPath, !destinationURL.hasDirectoryPath, !itemURL.pathExtension.isEmpty,
              itemURL.pathExtension.caseInsensitiveCompare(destinationURL.pathExtension) == .orderedSame else {
            throw RemoteLibraryWriteError.invalidName
        }
        guard itemURL != destinationURL else { throw RemoteLibraryWriteError.alreadyExists }
        var request = URLRequest(url: itemURL)
        request.httpMethod = "MOVE"
        request.setValue(destinationURL.absoluteString, forHTTPHeaderField: "Destination")
        request.setValue("F", forHTTPHeaderField: "Overwrite")
        let (_, response) = try await transport(connection).data(for: request)
        try RemoteLibraryWriteError.validate(response)
        // 207 can contain failed member moves, and 204 means replacement; neither
        // is a confirmed creation under the requested Overwrite:F contract.
        guard response.statusCode == 201 else { throw RemoteLibraryWriteError.invalidResponse }
    }

    private func connection(_ id: String) throws -> OPDSCatalog {
        guard let value = store.connection(id: id) else { throw RemoteLibraryError.missingConnection }
        return value
    }

    private func connectionURL(_ connection: OPDSCatalog) throws -> URL {
        guard let url = OPDSClient.url(from: connection.url) else { throw RemoteLibraryWriteError.invalidDestination }
        return url
    }

    private func transport(_ connection: OPDSCatalog) -> any RemoteLibraryTransport {
        transportFactory?(connection) ?? store.httpClient(for: connection)
    }

    private func calibreAPI(_ connection: OPDSCatalog) throws -> CalibreServerAPI {
        CalibreServerAPI(address: try CalibreServerAddress(connectionURL: connection.url), transport: transport(connection))
    }

    private func validName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              name.rangeOfCharacter(from: .controlCharacters) == nil else { throw RemoteLibraryWriteError.invalidName }
        return name
    }

    private func validateDAVURL(_ url: URL, connection: OPDSCatalog, allowRoot: Bool = false) throws {
        let base = try connectionURL(connection)
        guard RemoteLibraryHTTPClient.sameOrigin(url, base), url.user == nil, url.password == nil,
              url.fragment == nil else { throw RemoteLibraryWriteError.invalidDestination }
        func safePath(_ url: URL) throws -> [String] {
            guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else { throw RemoteLibraryWriteError.invalidDestination }
            let path = parts.percentEncodedPath.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
            guard !path.contains(where: { $0 == "." || $0 == ".." || $0.contains("/") || $0.contains("\\") || $0.rangeOfCharacter(from: .controlCharacters) != nil }) else {
                throw RemoteLibraryWriteError.invalidDestination
            }
            return path
        }
        let root = try safePath(base), target = try safePath(url)
        guard target.starts(with: root), allowRoot || target.count > root.count else { throw RemoteLibraryWriteError.invalidDestination }
    }

    private func didChange(_ connectionID: String) {
        NotificationCenter.default.post(name: .remoteLibraryDidChange, object: nil, userInfo: ["connectionID": connectionID])
    }
}
