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
        default: throw BookParserRegistryError.unsupportedFormat
        }
        // A user's confirmed import form or Calibre's metadata is authoritative.
        // Preserve the same imported ID and pipeline while applying these fields.
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { book.title = title }
        if let author, !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { book.author = author }
        if title != nil || author != nil { store.saveReadingBook(book) }
        return book
    }
}
