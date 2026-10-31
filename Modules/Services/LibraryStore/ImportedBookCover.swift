import Foundation
import UIKit

/// An imported book's own cover, read again from the book's file the way its import read it
/// (`BookStore.importEpub`, `importLocalPDF`, `importLocalManga`, `importLocalAudiobook`).
///
/// Nothing else keeps a copy. 快取管理 in 3.0.0 (143) deleted these files along with the
/// downloaded covers while the books kept their names (feedback #116); only the book's file
/// brings one back.
enum ImportedBookCover {
    enum Format: String, Sendable {
        case epub, pdf, comic
        /// Read from the first track: an archive's separate cover image is not kept after import.
        case audio
    }

    /// The format whose import read the book's cover from its own file. Nil for an online book,
    /// a remote-library copy (its cover comes from the catalog), TXT and Markdown.
    static func format(of book: ReadingBook) -> Format? {
        guard !book.isOnline, book.remoteSource == nil else { return nil }
        let ext = (book.contentFilename as NSString).pathExtension.lowercased()
        switch book.contentPipelineKind {
        case .audio:
            return .audio
        case .manga:
            return ext == "cbz" || ext == "zip" ? .comic : nil
        default:
            if ext == "pdf" { return .pdf }
            // `_epub.json`: a record from before EPUBs were read in place (`localEPUBURL`).
            if ext == "epub" || book.contentFilename.hasSuffix("_epub.json") { return .epub }
            return nil
        }
    }

    /// The cover's bytes as the import saved them, or nil (logged) when `file` yields none.
    static func read(_ format: Format, from file: URL) async -> Data? {
        let data: Data?
        switch format {
        case .epub:
            data = await PublicationSession.extractCoverImage(sourceURL: file)?.jpegData(compressionQuality: 0.85)
        case .pdf:
            data = LocalPDFArchive.coverImageData(from: file)
        case .comic:
            data = await LocalMangaArchive.coverImageData(from: file)?.data
        case .audio:
            do {
                let artwork = try await LocalAudiobookArchive.inspectSingleFile(url: file).coverImageData
                data = artwork.flatMap { UIImage(data: $0)?.jpegData(compressionQuality: 0.88) }
            } catch {
                AppLogger.cache("⟐ audiobook track could not be read for its cover", error: error)
                return nil
            }
        }
        if data == nil {
            AppLogger.cache("⟐ book file yields no cover", context: ["format": format.rawValue], level: .warning)
        }
        return data
    }
}
