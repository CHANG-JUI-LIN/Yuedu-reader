import Foundation

/// What a converted MOBI book records about itself, in `OPS/yuedu-mobi.json`. It
/// lives in the EPUB, not in the book record, for the reason `AozoraEPUBManifest`
/// gives: a synced field would tell another device that its own copy was regenerated.
struct MOBIEPUBManifest: Codable, Equatable, Sendable {
    struct Source: Codable, Equatable, Sendable {
        /// SHA-256 of the original file's bytes, hex.
        var sha256: String
        /// Which of the file's books was converted: a combination file holds both.
        var kind: MOBIFile.Kind
        /// The original file's size in bytes.
        var length: Int

        init(sha256: String, kind: MOBIFile.Kind, length: Int) {
            self.sha256 = sha256
            self.kind = kind
            self.length = length
        }

        init(original: Data, kind: MOBIFile.Kind) {
            self.init(sha256: EPUBPackageArchive.sha256(original), kind: kind, length: original.count)
        }
    }

    struct Chapter: Codable, Equatable, Sendable {
        var href: String
        /// UTF-16 length of the chapter's text as an HTML parser reads it. For
        /// information: `sha256` is what decides whether the text changed.
        var length: Int
        /// SHA-256 of the book's stylesheets (in `href` order) followed by the
        /// chapter's XHTML, as UTF-8, hex. Markup and not text alone: the text a
        /// reading engine lays out, and so what positions index, depends on both (an
        /// element that becomes a block, a collapsed space, `display: none`), so any
        /// change to either counts as a text change.
        var sha256: String
    }

    var converterVersion: Int
    var textVersion: Int
    var identifier: String
    var source: Source
    var chapters: [Chapter]
}

/// Packages a converted MOBI or KF8 book as an EPUB 3 file.
enum MOBIEPUBWriter {
    /// Changes with any change to the files the writer produces.
    static let converterVersion = 1
    /// Changes only when some chapter's `sha256` changes, and then ships with a
    /// position migration, never alone.
    static let textVersion = 1
    static let manifestPath = "OPS/yuedu-mobi.json"

    enum WriteError: Error, CustomStringConvertible {
        case noChapters
        var description: String { "a MOBI book with no chapters" }
    }

    /// Writes the EPUB to `url` and returns the manifest it holds.
    static func write(_ book: MOBIConvertedBook, source: MOBIEPUBManifest.Source, identifier: String,
                      to url: URL) async throws -> MOBIEPUBManifest {
        guard !book.chapters.isEmpty else { throw WriteError.noChapters }
        let manifest = MOBIEPUBManifest(
            converterVersion: converterVersion, textVersion: textVersion, identifier: identifier, source: source,
            chapters: book.chapters.map {
                .init(href: $0.href, length: $0.textLength, sha256: chapterDigest($0, in: book))
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        var entries: [EPUBPackageArchive.Entry] = book.chapters.map { .text("OPS/" + $0.href, $0.xhtml) }
        entries.append(.data(manifestPath, try encoder.encode(manifest)))
        entries.append(.text("OPS/nav.xhtml", navigation(book)))
        entries.append(.text("OPS/package.opf", packageDocument(book, identifier: identifier)))
        entries.append(.text("META-INF/container.xml", EPUBPackageArchive.containerXML))
        entries += book.resources.map { .data("OPS/" + $0.href, $0.data) }
        try await EPUBPackageArchive.write(entries, to: url)
        return manifest
    }

    static func chapterDigest(_ chapter: MOBIConvertedBook.Chapter, in book: MOBIConvertedBook) -> String {
        EPUBPackageArchive.sha256(book.stylesheetText + Data(chapter.xhtml.utf8))
    }

    // MARK: Package documents

    private static func language(of book: MOBIConvertedBook) -> String {
        book.metadata.language ?? "und"
    }

    private static func title(of book: MOBIConvertedBook) -> String {
        book.metadata.title ?? ""
    }

    private static func packageDocument(_ book: MOBIConvertedBook, identifier: String) -> String {
        let escape = MOBIMarkupNormalizer.escaped
        let info = book.metadata
        var metadata = """
                <dc:identifier id="bookid">\(escape(identifier))</dc:identifier>
                <dc:title>\(escape(title(of: book)))</dc:title>
                <dc:language>\(escape(language(of: book)))</dc:language>

            """
        for (index, author) in info.authors.enumerated() {
            metadata += "    <dc:creator id=\"creator\(index + 1)\">\(escape(author))</dc:creator>\n"
            metadata += "    <meta refines=\"#creator\(index + 1)\" property=\"role\" scheme=\"marc:relators\">aut</meta>\n"
        }
        for contributor in info.contributors {
            metadata += "    <dc:contributor>\(escape(contributor))</dc:contributor>\n"
        }
        let single: [(element: String, value: String?)] = [
            ("publisher", info.publisher), ("description", info.description),
            ("date", info.published), ("rights", info.rights),
        ]
        for (element, value) in single {
            guard let value, !value.isEmpty else { continue }
            metadata += "    <dc:\(element)>\(escape(value))</dc:\(element)>\n"
        }
        for subject in info.subjects {
            metadata += "    <dc:subject>\(escape(subject))</dc:subject>\n"
        }
        if let isbn = info.isbn, !isbn.isEmpty {
            metadata += "    <dc:identifier>urn:isbn:\(escape(isbn))</dc:identifier>\n"
        }
        let cover = book.resources.firstIndex(where: \.isCover)
        if let cover {
            // The EPUB 2 form as well, for readers that know only it.
            metadata += "    <meta name=\"cover\" content=\"res\(cover + 1)\"/>\n"
        }
        metadata += "    <meta property=\"dcterms:modified\">\(EPUBPackageArchive.modifiedTimestamp())</meta>\n"

        var manifest = """
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="yuedu-mobi" href="yuedu-mobi.json" media-type="application/json"/>

            """
        var spine = ""
        for (index, chapter) in book.chapters.enumerated() {
            let id = String(format: "c%04d", index + 1)
            manifest += "    <item id=\"\(id)\" href=\"\(escape(chapter.href))\" media-type=\"application/xhtml+xml\"/>\n"
            spine += "    <itemref idref=\"\(id)\"/>\n"
        }
        for (index, resource) in book.resources.enumerated() {
            let properties = index == cover ? " properties=\"cover-image\"" : ""
            manifest += "    <item id=\"res\(index + 1)\" href=\"\(escape(resource.href))\" "
                + "media-type=\"\(escape(resource.mediaType))\"\(properties)/>\n"
        }
        // MOBI 6 is horizontal, as a Kindle shows it: no primary-writing-mode, no
        // page-progression-direction (foliate reads EXTH 527 for KF8 only). KF8
        // keeps its page progression (EXTH 527) but not EXTH 525, its primary
        // writing mode: Calibre writes `horizontal-rl` for a vertical book, which
        // an OPF would make authoritative, while the stylesheets say how the text runs.
        let direction = book.kind == .kf8
            ? book.metadata.pageProgressionDirection.flatMap { ["ltr", "rtl"].contains($0) ? $0 : nil }
            : nil
        let spineAttributes = direction.map { " page-progression-direction=\"\($0)\"" } ?? ""
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <package version="3.0" unique-identifier="bookid" xmlns="http://www.idpf.org/2007/opf" xml:lang="\(escape(language(of: book)))">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            \(metadata)  </metadata>
              <manifest>
            \(manifest)  </manifest>
              <spine\(spineAttributes)>
            \(spine)  </spine>
            </package>

            """
    }

    /// The table of contents as the file nests it. A file without one gets a
    /// single entry, the title, at the first chapter: a navigation document needs one.
    private static func navigation(_ book: MOBIConvertedBook) -> String {
        let escape = MOBIMarkupNormalizer.escaped
        let entries = book.toc.isEmpty
            ? [MOBIConvertedBook.TOCEntry(title: title(of: book), href: book.chapters[0].href, children: [])]
            : book.toc
        func list(_ entries: [MOBIConvertedBook.TOCEntry]) -> String {
            "<ol>" + entries.map { entry in
                "<li><a href=\"\(escape(entry.href))\">\(escape(entry.title))</a>"
                    + (entry.children.isEmpty ? "" : list(entry.children)) + "</li>"
            }.joined() + "</ol>"
        }
        let lang = escape(language(of: book))
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(lang)" lang="\(lang)">
            <head><title>\(escape(title(of: book)))</title></head>
            <body><nav epub:type="toc" id="toc">\(list(entries))</nav></body>
            </html>

            """
    }
}
