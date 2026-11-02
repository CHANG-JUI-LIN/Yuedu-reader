import Foundation

/// A MOBI book converted to EPUB content, before packaging: what both converters
/// (`MOBI6Converter`, `KF8Converter`) hand to `MOBIEPUBWriter`.
struct MOBIConvertedBook: Sendable {
    struct Chapter: Sendable, Equatable {
        /// Package-relative to `OPS/`, e.g. `text/c0001.xhtml`.
        var href: String
        /// The complete XHTML document, exactly as it is written.
        var xhtml: String
        /// UTF-16 length of the body's text as SwiftSoup reads it (whitespace
        /// collapsed). For information only: it is not what either engine reads,
        /// and it is not what positions index.
        var textLength: Int
    }

    /// A file beside the chapters: a picture, a stylesheet, a font.
    struct Resource: Sendable, Equatable {
        /// Package-relative to `OPS/`, e.g. `images/image00003.jpg`.
        var href: String
        var mediaType: String
        var data: Data
        var isCover: Bool

        /// The formats MOBI files carry pictures in, by their first bytes.
        static func imageType(of data: Data) -> (mediaType: String, extension: String)? {
            let head = [UInt8](data.prefix(4))
            if head.starts(with: [0xFF, 0xD8, 0xFF]) { return ("image/jpeg", "jpg") }
            if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return ("image/png", "png") }
            if head.starts(with: [0x47, 0x49, 0x46, 0x38]) { return ("image/gif", "gif") }
            if head.starts(with: [0x42, 0x4D]) { return ("image/bmp", "bmp") }
            return nil
        }

        /// A font's format by its first bytes, with the EPUB core media type.
        static func fontType(of data: Data) -> (mediaType: String, extension: String)? {
            let head = [UInt8](data.prefix(4))
            if head == [0x00, 0x01, 0x00, 0x00] || head == Array("true".utf8) { return ("font/ttf", "ttf") }
            if head == Array("OTTO".utf8) { return ("font/otf", "otf") }
            if head == Array("wOFF".utf8) { return ("font/woff", "woff") }
            if head == Array("wOF2".utf8) { return ("font/woff2", "woff2") }
            return nil
        }
    }

    struct TOCEntry: Sendable, Equatable {
        var title: String
        /// Package-relative to `OPS/`, with a fragment.
        var href: String
        var children: [TOCEntry]
    }

    var kind: MOBIFile.Kind
    /// Strings with their HTML entities decoded.
    var metadata: MOBIMetadata
    var chapters: [Chapter]
    var resources: [Resource]
    var toc: [TOCEntry]
    /// Things the file names that could not be carried over, for the importer's log.
    var warnings: [String]

    /// The stylesheets' text in `href` order, what a chapter's layout reads
    /// besides its own XHTML.
    var stylesheetText: Data {
        resources.filter { $0.mediaType == "text/css" }.reduce(into: Data()) { $0.append($1.data) }
    }
}
