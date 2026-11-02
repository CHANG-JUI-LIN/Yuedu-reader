import Foundation

/// Imports a MOBI or AZW3 file as an EPUB book converted at import (MOBI plan, step 4),
/// the way Aozora texts are: the original is kept next to the EPUB, so another device
/// converts its own copy and a converter change regenerates it
/// (`ConvertedBookRegenerator`).
@MainActor
enum MOBIBookImporter {
    /// A file converted into an EPUB in a work folder.
    struct Converted: Sendable {
        let epub: URL
        let manifest: MOBIEPUBManifest
        let kind: MOBIFile.Kind
        let workDirectory: URL
    }

    /// Converts and imports the file. A conversion failure throws: there is no other
    /// reader to fall back to.
    static func importBook(at url: URL, title: String?, store: BookStore, isInBookshelf: Bool = true) async throws -> ReadingBook {
        let converted = try await Task.detached(priority: .userInitiated) {
            try await convert(url, identifier: nil)
        }.value
        defer { remove(converted.workDirectory, reason: "work folder") }
        try Task.checkCancellation()

        var book = try await store.importEpub(url: converted.epub, title: title, requireValidPublication: true,
                                              isInBookshelf: isInBookshelf)
        let original = (book.contentFilename as NSString).deletingPathExtension + ".mobi."
            + url.pathExtension.lowercased()
        let originalURL = StorageLocations.bookFile(original)
        do {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: originalURL.path) {
                try FileManager.default.removeItem(at: originalURL)
            }
            try FileManager.default.copyItem(at: url, to: originalURL)
            book.mobi = MOBIBookSource(originalFilename: original, kind: converted.kind)
            store.saveReadingBook(book)
            return book
        } catch {
            // The book is recorded already; take it off with its files.
            store.delete(bookId: book.id)
            remove(originalURL, reason: "original")
            throw error
        }
    }

    /// Off the main actor: the file read, converted and written as an EPUB in a work
    /// folder. A regeneration passes the book's identifier so the package keeps it. What
    /// the converter could not carry over is logged here, with the file it came from.
    nonisolated static func convert(_ url: URL, identifier: String?) async throws -> Converted {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("MOBIImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            return try await SourcePerfTrace.spanAsync("mobi.convert", url.lastPathComponent) {
                let data = try Data(contentsOf: url)
                let file = try MOBIFile(data: data)
                let book = switch file.kind {
                case .mobi6: try MOBI6Converter.convert(file)
                case .kf8: try KF8Converter.convert(file)
                }
                for warning in book.warnings {
                    AppLogger.parse("[MOBI] \(warning)", context: ["file": url.lastPathComponent], level: .notice)
                }
                let epub = work.appendingPathComponent("book.epub")
                let manifest = try await MOBIEPUBWriter.write(
                    book, source: MOBIEPUBManifest.Source(original: data, kind: file.kind),
                    identifier: identifier ?? "urn:uuid:\(UUID().uuidString)", to: epub)
                return Converted(epub: epub, manifest: manifest, kind: file.kind, workDirectory: work)
            }
        } catch {
            AppLogger.error("A MOBI file could not be converted", error: error, context: ["file": url.lastPathComponent])
            remove(work, reason: "work folder")
            throw error
        }
    }

    /// Which of its books a file holds, read from its headers alone. Throws for a file that
    /// is not a MOBI, is encrypted, or uses a compression the converter cannot read: what a
    /// remote library's offline copy is checked for before it is kept.
    nonisolated static func kind(of url: URL) throws -> MOBIFile.Kind {
        do {
            return try MOBIFile(data: Data(contentsOf: url, options: .alwaysMapped)).kind
        } catch {
            AppLogger.error("A MOBI file's headers could not be read", error: error, context: ["file": url.lastPathComponent])
            throw error
        }
    }

    /// The converter `ConvertedBookRegenerator` calls for a MOBI book.
    nonisolated static let converter = ConvertedBookRegenerator.Converter(
        name: "MOBI", manifestPath: MOBIEPUBWriter.manifestPath,
        converterVersion: MOBIEPUBWriter.converterVersion, textVersion: MOBIEPUBWriter.textVersion,
        stampsTextVersion: true
    ) { original, identifier in
        let converted = try await convert(original, identifier: identifier)
        let manifest = converted.manifest
        return ConvertedBookRegenerator.Converted(
            epub: converted.epub,
            recorded: ConvertedBookRegenerator.Recorded(
                converterVersion: manifest.converterVersion, textVersion: manifest.textVersion,
                identifier: manifest.identifier,
                chapters: manifest.chapters.map { .init(length: $0.length, sha256: $0.sha256) }),
            workDirectory: converted.workDirectory)
    }

    nonisolated static func remove(_ url: URL, reason: String) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            AppLogger.error("MOBI import could not remove its \(reason)", error: error,
                            context: ["file": url.lastPathComponent])
        }
    }
}

// What a refused Kindle file says, wherever it arrives: Files, Open In, Calibre, a remote
// library. Here rather than beside the parser, which stays free of the app (MOBI plan,
// "Decided in step 1"). A DRM'd file is named as protected and nothing more.
extension MOBIError: LocalizedError, DiagnosableError {
    var errorDescription: String? {
        switch self {
        case .encrypted: localized("這個 Kindle 檔案有 DRM 保護，無法開啟")
        case .unknownCompression: localized("這個 Kindle 檔案的壓縮方式目前不支援")
        case .notMOBI, .unsupportedEncoding, .missingMOBIHeader, .truncatedRecord, .corruptText, .corruptIndex:
            localized("無法讀取這個 Kindle 檔案")
        }
    }

    var diagnosticDescription: String { String(describing: self) }
}

extension MOBIEPUBWriter.WriteError: LocalizedError, DiagnosableError {
    var errorDescription: String? { localized("無法讀取這個 Kindle 檔案") }
    var diagnosticDescription: String { description }
}
