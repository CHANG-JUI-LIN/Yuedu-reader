import Foundation

/// The file formats a book is read from, in one table. Every gate that decides whether
/// a file is a readable book — local import, Calibre's wireless device, a remote
/// library's item and detail page, an OPDS acquisition, WebDAV, upload — reads it here
/// instead of keeping a list of its own (MOBI plan, step 4).
enum BookFileFormat: CaseIterable, Sendable {
    // Documents, in reading preference: a book offered in several opens in the first.
    // AZW3 and MOBI convert into an EPUB at import (`MOBIBookImporter`): after an EPUB,
    // which needs no conversion, and before a PDF, which reflows worse.
    case epub, azw3, mobi, pdf, txt, markdown
    // Read from a file on this device only.
    case json, comicArchive, zip, audio

    /// What is read wherever the file is: on this device, from a remote library, an OPDS
    /// catalog or WebDAV, or sent by Calibre. In reading preference.
    static let documents: [BookFileFormat] = [.epub, .azw3, .mobi, .pdf, .txt, .markdown]

    /// The file name extensions, lowercase, the usual one first.
    var extensions: [String] {
        switch self {
        case .epub: ["epub"]
        // Mobipocket's own extensions, and Amazon's for the same format before KF8.
        case .mobi: ["mobi", "prc", "azw"]
        case .azw3: ["azw3"]
        case .pdf: ["pdf"]
        case .txt: ["txt"]
        case .markdown: ["md", "markdown"]
        case .json: ["json"]
        case .comicArchive: ["cbz"]
        case .zip: ["zip"]
        case .audio: ["mp3", "m4a", "m4b", "aac", "flac", "wav"]
        }
    }

    /// The media type a remote file of this format is labelled with.
    var mediaType: String? {
        switch self {
        case .epub: "application/epub+zip"
        case .mobi: "application/x-mobipocket-ebook"
        case .azw3: "application/x-mobi8-ebook"
        case .pdf: "application/pdf"
        case .txt: "text/plain"
        case .markdown: "text/markdown"
        case .json, .comicArchive, .zip, .audio: nil
        }
    }

    var isDocument: Bool { Self.documents.contains(self) }

    /// Whether a remote library may be sent a file of this format: nothing here writes
    /// MOBI or AZW3 to a server.
    var isUploadable: Bool { isDocument && !importsAsMOBI }

    /// Read by `MOBIBookImporter`, which converts the file into an EPUB at import. Which
    /// of the two a file holds is read from the file, not its name.
    var importsAsMOBI: Bool { self == .mobi || self == .azw3 }

    /// Rank in reading preference, 0 first; nil for a format that is not a document.
    var readingPreference: Int? { Self.documents.firstIndex(of: self) }

    init?(fileExtension: String) {
        let ext = fileExtension.lowercased()
        guard let format = Self.allCases.first(where: { $0.extensions.contains(ext) }) else { return nil }
        self = format
    }

    /// The document format a media type names, read as catalogs write them: an EPUB or
    /// PDF type with parameters or a vendor prefix, any Markdown type, plain text, and
    /// the Kindle types. Project Gutenberg labels its KF8 files with the Mobipocket type,
    /// which is harmless: the file itself says which it holds.
    init?(mediaType: String) {
        let type = mediaType.lowercased().split(separator: ";").first.map(String.init) ?? ""
        if ["application/x-mobi8-ebook", "application/vnd.amazon.mobi8-ebook"].contains(type) { self = .azw3 }
        else if ["application/x-mobipocket-ebook", "application/vnd.amazon.ebook"].contains(type) { self = .mobi }
        else if type.contains("epub") { self = .epub }
        else if type.contains("pdf") { self = .pdf }
        else if type.contains("markdown") { self = .markdown }
        else if type == "text/plain" { self = .txt }
        else { return nil }
    }

    /// Every extension local import reads.
    static let localImportExtensions = Set(allCases.flatMap(\.extensions))
    /// Every document extension, in reading preference.
    static let documentExtensions = documents.flatMap(\.extensions)
    static let uploadExtensions = Set(allCases.filter(\.isUploadable).flatMap(\.extensions))

    /// A document's file extension, or nil for any other.
    static func document(fileExtension: String) -> BookFileFormat? {
        BookFileFormat(fileExtension: fileExtension).flatMap { $0.isDocument ? $0 : nil }
    }
}
