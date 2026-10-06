import CryptoKit
import Foundation
import ReadiumZIPFoundation

/// What a converted book records about itself, in `OPS/yuedu-aozora.json`. It lives
/// in the EPUB, not in the book record: a synced field would tell another device
/// that its own copy was regenerated when only this one was.
struct AozoraEPUBManifest: Codable, Equatable, Sendable {
    struct Source: Codable, Equatable, Sendable {
        /// SHA-256 of the original file's bytes, hex.
        var sha256: String
        /// The encoding it was read with, `String.Encoding.rawValue`.
        var encoding: UInt
        /// UTF-16 length of the decoded text.
        var length: Int
    }

    struct Chapter: Codable, Equatable, Sendable {
        var href: String
        /// UTF-16 length of the chapter's text.
        var length: Int
        /// SHA-256 of the chapter's text as UTF-8, hex.
        var sha256: String
        /// The chapter's source map, five integers a run: displayed start, source
        /// start, displayed length, source length, and 1 for a copy. A later
        /// text-changing upgrade migrates positions with these; a newer parser
        /// cannot rebuild an older version's text.
        var sourceMap: [Int]
    }

    var converterVersion: Int
    var textVersion: Int
    var identifier: String
    var source: Source
    var chapters: [Chapter]
}

/// Packages a planned Aozora document as an EPUB 3 file (Phase 1b, Task 16).
enum AozoraEPUBWriter {
    /// Changes with any change to the files the writer produces.
    static let converterVersion = 1
    /// Changes only when some chapter's text changes, and then ships with a
    /// position migration (Phase 1c's tools), never alone.
    static let textVersion = 1
    static let manifestPath = "OPS/yuedu-aozora.json"

    enum WriteError: Error, CustomStringConvertible {
        case noChapters
        var description: String { "an Aozora document with no chapters" }
    }

    /// Writes the EPUB to `url` and returns the manifest it holds. `images` maps a
    /// figure's source name to its file; only the figures the document names go in.
    static func write(_ document: AozoraDocument, chapters: [AozoraChapter], images: [String: URL],
                      source: AozoraEPUBManifest.Source, identifier: String, to url: URL) async throws -> AozoraEPUBManifest {
        guard !chapters.isEmpty else { throw WriteError.noChapters }
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("aozora-epub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: staging)
            } catch {
                AppLogger.parse("[Aozora] could not remove the EPUB staging folder: \(error)", level: .notice)
            }
        }

        // Figures: package path by source name, for the chapters that show them.
        var figures: [(name: String, path: String, file: URL)] = []
        var figurePaths: [String: String] = [:]
        for name in figureNames(in: document) where figurePaths[name] == nil {
            guard let file = images[name] else { continue }
            // Named after the figure the text names, numbered so two names that clean up alike stay apart.
            let packageName = "\(figures.count + 1)-" + sanitized((name as NSString).lastPathComponent)
            figures.append((name, "OPS/images/" + packageName, file))
            figurePaths[name] = "../images/" + packageName
        }

        var entries: [(path: String, data: Data)] = []
        var manifestChapters: [AozoraEPUBManifest.Chapter] = []
        for (index, chapter) in chapters.enumerated() {
            let href = String(format: "text/c%04d.xhtml", index + 1)
            let xhtml = AozoraXHTMLWriter.document(for: chapter, in: document, images: figurePaths)
            entries.append(("OPS/" + href, Data(xhtml.utf8)))
            manifestChapters.append(AozoraEPUBManifest.Chapter(
                href: href, length: chapter.text.utf16.count, sha256: sha256(Data(chapter.text.utf8)),
                sourceMap: chapter.sourceMap.runs.flatMap {
                    [$0.displayedStart, $0.sourceStart, $0.displayedLength, $0.sourceLength, $0.isIdentity ? 1 : 0]
                }))
        }
        let manifest = AozoraEPUBManifest(converterVersion: converterVersion, textVersion: textVersion,
                                          identifier: identifier, source: source, chapters: manifestChapters)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        entries.append((manifestPath, try encoder.encode(manifest)))
        entries.append(("OPS/style/aozora.css", Data(AozoraXHTMLWriter.stylesheet.utf8)))
        entries.append(("OPS/nav.xhtml", Data(navigation(chapters, title: title(of: document)).utf8)))
        entries.append(("OPS/package.opf", Data(packageDocument(document, chapters: chapters,
                                                                figures: figures.map { (path: $0.path, name: $0.name) },
                                                                identifier: identifier).utf8)))
        entries.append(("META-INF/container.xml", Data(containerXML.utf8)))

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let archive = try await Archive(url: url, accessMode: .create)
        // `mimetype` first and stored, as OCF requires.
        try await add("mimetype", Data("application/epub+zip".utf8), to: archive, in: staging, compression: .none)
        for entry in entries {
            try await add(entry.path, entry.data, to: archive, in: staging, compression: .deflate)
        }
        for figure in figures {
            try await archive.addEntry(with: figure.path, fileURL: figure.file, compressionMethod: .deflate)
        }
        return manifest
    }

    private static func add(_ path: String, _ data: Data, to archive: Archive, in staging: URL,
                            compression: CompressionMethod) async throws {
        let file = staging.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        try await archive.addEntry(with: path, fileURL: file, compressionMethod: compression)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Package documents

    private static let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>

        """

    private static func title(of document: AozoraDocument) -> String {
        document.header?.title ?? document.headerBlocks.first?.displayedText ?? ""
    }

    private static func packageDocument(_ document: AozoraDocument, chapters: [AozoraChapter],
                                        figures: [(path: String, name: String)], identifier: String) -> String {
        let escape = AozoraXHTMLWriter.escaped
        var metadata = """
                <dc:identifier id="bookid">\(escape(identifier))</dc:identifier>
                <dc:title>\(escape(title(of: document)))</dc:title>
                <dc:language>ja</dc:language>

            """
        var people: [(name: String, role: String, element: String)] = []
        if let author = document.header?.author { people.append((author, "aut", "creator")) }
        if let translator = document.header?.translator { people.append((translator, "trl", "contributor")) }
        if let editor = document.header?.editor { people.append((editor, "edt", "contributor")) }
        if let henyaku = document.header?.henyaku {
            people.append((henyaku, "edt", "contributor"))
            people.append((henyaku, "trl", "contributor"))
        }
        for (index, person) in people.enumerated() {
            let id = "person\(index + 1)"
            metadata += "    <dc:\(person.element) id=\"\(id)\">\(escape(person.name))</dc:\(person.element)>\n"
            metadata += "    <meta refines=\"#\(id)\" property=\"role\" scheme=\"marc:relators\">\(person.role)</meta>\n"
        }
        metadata += "    <meta property=\"dcterms:modified\">\(modifiedDate())</meta>\n"

        var manifest = """
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="css" href="style/aozora.css" media-type="text/css"/>
                <item id="yuedu-aozora" href="yuedu-aozora.json" media-type="application/json"/>

            """
        var spine = ""
        for index in chapters.indices {
            let id = String(format: "c%04d", index + 1)
            manifest += "    <item id=\"\(id)\" href=\"text/\(id).xhtml\" media-type=\"application/xhtml+xml\"/>\n"
            spine += "    <itemref idref=\"\(id)\"/>\n"
        }
        for (index, figure) in figures.enumerated() {
            let href = String(figure.path.dropFirst("OPS/".count))
            manifest += "    <item id=\"img\(index + 1)\" href=\"\(escape(href))\" media-type=\"\(mediaType(of: href))\"/>\n"
        }
        // Horizontal in Phase 1b: no primary-writing-mode, no page-progression-direction.
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <package version="3.0" unique-identifier="bookid" xmlns="http://www.idpf.org/2007/opf" xml:lang="ja">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            \(metadata)  </metadata>
              <manifest>
            \(manifest)  </manifest>
              <spine>
            \(spine)  </spine>
            </package>

            """
    }

    /// The table of contents: every chapter's entries, nested by level.
    private static func navigation(_ chapters: [AozoraChapter], title: String) -> String {
        var entries: [(title: String, level: Int, href: String)] = []
        for (index, chapter) in chapters.enumerated() {
            let file = String(format: "text/c%04d.xhtml", index + 1)
            for entry in chapter.navigation {
                entries.append((entry.title, entry.level, entry.anchor.map { "\(file)#\($0)" } ?? file))
            }
        }
        if entries.isEmpty { entries = [(title, 1, "text/c0001.xhtml")] }
        let escape = AozoraXHTMLWriter.escaped
        var list = ""
        var open = 0
        for (entry, depth) in zip(entries, nestingDepths(entries.map(\.level))) {
            if open == 0 {
                list += "<ol>"
                open = 1
            } else if depth + 1 > open {
                list += "<ol>"
                open += 1
            } else {
                list += "</li>"
                while open > depth + 1 {
                    list += "</ol></li>"
                    open -= 1
                }
            }
            list += "<li><a href=\"\(escape(entry.href))\">\(escape(entry.title))</a>"
        }
        while open > 0 {
            list += "</li></ol>"
            open -= 1
        }
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="ja" lang="ja">
            <head><title>\(escape(title))</title></head>
            <body><nav epub:type="toc" id="toc">\(list)</nav></body>
            </html>

            """
    }

    /// How deep each table-of-contents entry nests, from 0: under the nearest earlier
    /// entry of a higher level (a smaller number), one step at a time, so a 小見出し
    /// directly under a 大見出し nests one step, not two, and entries of one level are
    /// siblings.
    static func nestingDepths(_ levels: [Int]) -> [Int] {
        var open: [Int] = []
        return levels.map { level in
            while let last = open.last, last >= level { open.removeLast() }
            open.append(level)
            return open.count - 1
        }
    }

    private static func modifiedDate() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    private static func mediaType(of path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "gif": return "image/gif"
        default: return "image/jpeg"
        }
    }

    /// A file name safe inside the package: ASCII letters, digits, `.`, `-` and `_`.
    private static func sanitized(_ name: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "figure" : cleaned
    }

    // MARK: Figures

    /// The source names of every figure the document shows, in order.
    static func figureNames(in document: AozoraDocument) -> [String] {
        var names: [String] = []
        func walk(_ inlines: [AozoraInline]) {
            for inline in inlines {
                switch inline {
                case .image(let source, _, _, let caption):
                    names.append(source)
                    walk(caption)
                case .ruby(let children, _, _), .emphasis(_, _, let children), .sideline(_, _, let children),
                     .bold(let children), .italic(let children), .size(_, let children),
                     .tateChuYoko(let children), .script(_, let children), .warichu(let children),
                     .heading(_, _, let children), .boxed(let children), .horizontal(let children),
                     .caption(let children):
                    walk(children)
                case .text, .gaiji, .kaeriten, .kuntenOkurigana, .lineBreak, .editorialNote, .unknownAnnotation:
                    break
                }
            }
        }
        for block in document.headerBlocks + document.body + document.colophon {
            switch block {
            case .paragraph(let inlines, _), .heading(_, _, let inlines, _): walk(inlines)
            case .image(let source, _, _, let caption):
                names.append(source)
                walk(caption)
            case .pageBreak: break
            }
        }
        return names
    }
}
