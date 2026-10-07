import Foundation

@MainActor
protocol AozoraLibraryDownloading {
    func addToShelf(work: AozoraWork, store: BookStore) async throws -> ReadingBook
}

enum AozoraLibraryDownloadError: LocalizedError, Equatable {
    case connection, http(Int), notAozoraText, invalidURL
    var errorDescription: String? {
        switch self {
        case .connection: localized("無法連線到青空文庫網站")
        case .http(let status): String(format: localized("連線失敗（HTTP %d）"), status)
        case .notAozoraText: localized("這個檔案不是青空文庫的文字")
        case .invalidURL: localized("青空文庫下載網址無效")
        }
    }
}

/// One use case owns the temporary download, conversion and shelf identity.
/// It deliberately has no subscription dependency and never contacts a mirror.
@MainActor
final class AozoraLibraryDownloadService: AozoraLibraryDownloading {
    private let temporaryDirectory: URL
    private let download: (URL, URL) async throws -> Void
    private var operations: [String: Task<ReadingBook, any Error>] = [:]

    init(temporaryDirectory: URL = FileManager.default.temporaryDirectory,
         download: @escaping (URL, URL) async throws -> Void = AozoraLibraryDownloadService.downloadOfficialFile) {
        self.temporaryDirectory = temporaryDirectory
        self.download = download
    }

    func addToShelf(work: AozoraWork, store: BookStore) async throws -> ReadingBook {
        if let book = store.books.first(where: { $0.aozora?.catalogWorkID == work.id }) { return book }
        if let operation = operations[work.id] { return try await operation.value }
        let operation = Task { try await importWork(work, store: store) }
        operations[work.id] = operation
        defer { operations.removeValue(forKey: work.id) }
        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    private func importWork(_ work: AozoraWork, store: BookStore) async throws -> ReadingBook {
        let folder = temporaryDirectory.appendingPathComponent("AozoraLibrary-\(UUID().uuidString)", isDirectory: true)
        defer {
            if FileManager.default.fileExists(atPath: folder.path) {
                do { try FileManager.default.removeItem(at: folder) }
                catch { AppLogger.error("Aozora temporary download cleanup failed", error: error, context: ["workID": work.id]) }
            }
        }
        do {
            guard let url = URL(string: work.text), url.scheme == "https", url.host == "www.aozora.gr.jp",
                  url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
                  url.pathExtension == "zip" else { throw AozoraLibraryDownloadError.invalidURL }
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("work.zip")
            try await download(url, file)
            try Task.checkCancellation()
            guard var book = try await AozoraBookImporter.importBook(at: file, title: work.title, store: store) else {
                throw AozoraLibraryDownloadError.notAozoraText
            }
            // The EPUB importer treats its title argument as a metadata fallback.
            // Keep the catalog edition title the reader explicitly selected.
            book.title = work.title
            book.aozora?.catalogWorkID = work.id
            store.saveReadingBook(book)
            return book
        } catch {
            AppLogger.network("Aozora work download/import failed", error: error, context: ["workID": work.id])
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if error is URLError { throw AozoraLibraryDownloadError.connection }
            throw error
        }
    }

    private static func downloadOfficialFile(_ url: URL, to destination: URL) async throws {
        let http = RemoteLibraryHTTPClient(baseURL: url)
        // Use the shared remote-library session/identification. Check the original
        // HTTP status here because the Aozora UI reports every HTTP code, including
        // 401/403, rather than the OPDS authentication-specific error mapping.
        let (temporary, response) = try await http.session.download(for: http.sanitized(URLRequest(url: url, timeoutInterval: 120)))
        defer {
            if FileManager.default.fileExists(atPath: temporary.path) {
                do { try FileManager.default.removeItem(at: temporary) }
                catch { AppLogger.error("Aozora URLSession temporary file cleanup failed", error: error) }
            }
        }
        guard let response = response as? HTTPURLResponse else { throw OPDSError.noData }
        guard (200...299).contains(response.statusCode) else { throw AozoraLibraryDownloadError.http(response.statusCode) }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}
