import Foundation
import ReadiumZIPFoundation
import UniformTypeIdentifiers

/// Shared local-file use case; receiving a file never creates an alternate
/// parser or reader pipeline. Callers retain ownership of staging and cleanup.
@MainActor
enum LocalBookImportService {
    nonisolated static let supportedExtensions: Set<String> = [
        "epub", "pdf", "txt", "md", "markdown", "json", "cbz", "zip",
        "mp3", "m4a", "m4b", "aac", "flac", "wav"
    ]

    static var supportedContentTypes: [UTType] {
        Array(Set(supportedExtensions.compactMap { UTType(filenameExtension: $0) }))
            .sorted { $0.identifier < $1.identifier }
    }

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
            } else if let document = await extractAozoraDocument(from: url) {
                // Official Aozora Bunko downloads are a zip holding one Shift_JIS
                // text (plus figures for illustrated works). Until the EPUB
                // converter lands, the text opens through the TXT importer;
                // the figures are not imported yet.
                defer { removeExtractedDocument(document.deletingLastPathComponent()) }
                book = try await store.importTxt(url: document, title: title)
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

    /// The first `.txt` entry that `AozoraDocumentDetector` accepts, extracted
    /// to its own temporary directory. A comic's readme is not enough: the
    /// detector needs a notation block or a 底本 colophon.
    private static func extractAozoraDocument(from archiveURL: URL) async -> URL? {
        await Task.detached(priority: .userInitiated) { () -> URL? in
            let archive: Archive
            let paths: [String]
            do {
                archive = try await Archive(url: archiveURL, accessMode: .read)
                paths = try await archive.entries()
                    .filter { $0.type == .file && isVisibleTextEntry($0.path) }
                    .map(\.path)
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            } catch {
                // The manga importer reports the unreadable archive to the user.
                AppLogger.error("Aozora zip probe could not list entries", error: error,
                                context: ["file": archiveURL.lastPathComponent])
                return nil
            }
            guard !paths.isEmpty else { return nil }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AozoraImport-\(UUID().uuidString)", isDirectory: true)
            for path in paths {
                let destination = directory.appendingPathComponent((path as NSString).lastPathComponent)
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    guard let entry = try await archive.get(path) else { continue }
                    _ = try await archive.extract(entry, to: destination)
                    if AozoraDocumentDetector.isAozoraDocument(try TXTFileReader.readTextFile(url: destination)) {
                        return destination
                    }
                } catch {
                    AppLogger.error("Aozora zip probe skipped a text entry", error: error,
                                    context: ["file": archiveURL.lastPathComponent, "entry": path])
                }
            }
            removeExtractedDocument(directory)
            return nil
        }.value
    }

    nonisolated private static func isVisibleTextEntry(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        guard let filename = components.last, !filename.hasPrefix(".") else { return false }
        guard !components.contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" }) else { return false }
        return (filename as NSString).pathExtension.lowercased() == "txt"
    }

    nonisolated private static func removeExtractedDocument(_ directory: URL) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            AppLogger.error("Aozora zip import could not remove its temporary text", error: error,
                            context: ["directory": directory.lastPathComponent])
        }
    }
}
