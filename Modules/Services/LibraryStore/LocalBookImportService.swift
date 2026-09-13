import Foundation

/// Shared local-file use case; receiving a file never creates an alternate
/// parser or reader pipeline. Callers retain ownership of staging and cleanup.
@MainActor
enum LocalBookImportService {
    static func importBook(at url: URL, title: String? = nil, author: String? = nil, store: BookStore) async throws -> ReadingBook {
        try Task.checkCancellation()
        var book: ReadingBook
        switch url.pathExtension.lowercased() {
        case "epub": book = try await store.importEpub(url: url, title: title, author: author, requireValidPublication: true)
        case "pdf": book = try await store.importLocalPDF(url: url, title: title, author: author)
        case "txt": book = try await store.importTxt(url: url, title: title)
        case "md", "markdown": book = try store.importMarkdown(url: url, title: title, author: author ?? localized("未知作者"))
        case "json":
            let parsed = try await BookParserRegistry.parse(url: url)
            book = try store.importWeb(content: parsed.storageText, title: title ?? parsed.title,
                                       author: author ?? parsed.author, sourceURL: "local")
        case "zip":
            if await LocalAudiobookArchive.zipContainsAudio(url) {
                book = try await store.importLocalAudiobook(url: url, title: title, author: author)
            } else {
                book = try await store.importLocalManga(url: url, title: title, author: author)
            }
        case "cbz": book = try await store.importLocalManga(url: url, title: title, author: author)
        case "mp3", "m4a", "m4b", "aac", "flac", "wav":
            book = try await store.importLocalAudiobook(url: url, title: title, author: author)
        default: throw BookParserRegistryError.unsupportedFormat
        }
        // A user's confirmed import form or Calibre's metadata is authoritative.
        // Preserve the same imported ID and pipeline while applying these fields.
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { book.title = title }
        if let author, !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { book.author = author }
        // Completing an import is a durable shelf operation, not a debounced
        // reading-progress update. Reloading immediately must keep the new book.
        store.saveReadingBook(book)
        return book
    }

    struct BatchResult {
        var books: [ReadingBook] = []
        var failures: [String] = []
    }

    /// Files grants access to each selected URL. Keep that access alive until
    /// its existing format importer owns a persistent copy. A bad file must not
    /// discard the other selections; cancellation stops only unfinished work.
    static func importBooks(at urls: [URL], store: BookStore,
                            progress: (Int, String) -> Void = { _, _ in }) async throws -> BatchResult {
        var result = BatchResult()
        for (index, url) in urls.enumerated() {
            try Task.checkCancellation()
            progress(index, url.lastPathComponent)
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                result.books.append(try await importBook(at: url, store: store))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result.failures.append(url.lastPathComponent + ": " + error.localizedDescription)
            }
        }
        return result
    }

}
