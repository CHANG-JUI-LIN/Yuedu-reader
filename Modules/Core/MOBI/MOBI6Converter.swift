// Ported from foliate-js `mobi.js` (MIT, Copyright (c) 2022 John Factotum).
// The full licence is in foliate-js-LICENSE.txt beside this file.

import Foundation
import SwiftSoup

/// MOBI 6 → EPUB content (foliate's `MOBI6` class): one chapter per
/// `<mbp:pagebreak>` section, `filepos` byte offsets turned into element ids and
/// links, `recindex` images into files, and the guide's table-of-contents page
/// into a nested table of contents.
enum MOBI6Converter {
    static let stylesheet = """
        /* MOBI 6: a block's space above comes from its Kindle `height`, written as
           margin-top, so paragraphs carry no margins of their own. Blockquotes
           indent by 1em, as Kindles show them (foliate's default stylesheet). */
        p { margin-top: 0; margin-bottom: 0; }
        blockquote { margin: 0 0 0 1em; }

        """

    private static let pagebreak = try! NSRegularExpression(
        pattern: #"<\s*(?:mbp:)?pagebreak[^>]*>"#, options: [.caseInsensitive])
    private static let fileposLink = try! NSRegularExpression(
        pattern: #"<[^<>]+filepos=['"]{0,1}(\d+)[^<>]*>"#, options: [.caseInsensitive])
    /// `</br>`, which Kindle tools write after every `<br>`. HTML parsing reads it
    /// as a second break; a Kindle shows one.
    private static let brEndTag = try! NSRegularExpression(
        pattern: #"<\s*/\s*br\s*>"#, options: [.caseInsensitive])
    private static let linkPlaceholder = try! NSRegularExpression(
        pattern: #"href="yuedu-filepos:(\d+)""#)

    private struct Section {
        var start: Int
        var end: Int
    }

    static func convert(_ file: MOBIFile) throws -> MOBIConvertedBook {
        precondition(file.kind == .mobi6, "a KF8 file goes to the KF8 converter")
        let encoding = file.headers.encoding
        let raw = [UInt8](try file.text())
        // One character per byte, so regex offsets are byte offsets: `filepos`
        // values count bytes of the undecoded text.
        let latin1 = String(data: Data(raw), encoding: .isoLatin1)! as NSString
        let bytes = latin1 as String

        var starts = [0]
        for match in pagebreak.matches(in: bytes, range: NSRange(location: 0, length: latin1.length))
        where match.range.location > 0 {
            starts.append(match.range.location)
        }
        let sections = starts.enumerated().map { index, start in
            Section(start: start, end: index + 1 < starts.count ? starts[index + 1] : raw.count)
        }
        var warnings: [String] = []
        let ncx = MOBINCXEntry.read(from: file, warnings: &warnings)
        // Every byte a link or the NCX points at gets an anchor.
        let targets = Set(fileposLink.matches(in: bytes, range: NSRange(location: 0, length: latin1.length))
            .compactMap { Int(latin1.substring(with: $0.range(at: 1))) } + ncx.flatMap(Self.offsets)).sorted()

        var resources: [MOBIConvertedBook.Resource] = []
        var resourceByIndex: [Int: String] = [:]
        func image(_ resourceIndex: Int) throws -> String? {
            if let path = resourceByIndex[resourceIndex] { return path }
            // An index past the file is a broken reference; a record the file
            // cut short is a broken file and throws.
            guard resourceIndex >= 0, file.resourceStart + resourceIndex < file.recordCount else { return nil }
            let data = try file.resource(resourceIndex)
            guard let type = MOBIConvertedBook.Resource.imageType(of: data) else { return nil }
            let href = String(format: "images/image%05d.%@", resourceIndex + 1, type.extension)
            resources.append(.init(href: href, mediaType: type.mediaType, data: data, isCover: false))
            resourceByIndex[resourceIndex] = href
            return href
        }

        // Pass 1: each section parsed, normalised and written with placeholder
        // links, because a link's chapter file depends on which later sections
        // turn out empty.
        var written: [(section: Int, body: String, textLength: Int)] = []
        var guide: [(type: String, filepos: Int)] = []
        var tocPage: [(title: String, filepos: Int, indent: Double)] = []
        for (index, section) in sections.enumerated() {
            let html = try decodedSection(raw, section, targets: targets, encoding: encoding)
            let document = try SwiftSoup.parse(html)
            if index == 0 {
                guide = try document.select("guide reference[filepos]").array().compactMap { reference in
                    guard let filepos = Int(try reference.attr("filepos")) else { return nil }
                    return (try reference.attr("type").lowercased(), filepos)
                }
            }
            if let toc = guide.first(where: { $0.type.split(separator: " ").contains("toc") }),
               toc.filepos >= section.start, toc.filepos < section.end {
                tocPage = try tableOfContentsLinks(in: document)
            }
            guard let body = document.body() else { continue }
            for link in try body.select("[filepos]").array() {
                if let filepos = Int(try link.attr("filepos")) {
                    try link.attr("href", "yuedu-filepos:\(filepos)")
                }
                try link.removeAttr("filepos")
            }
            // Chapters are in `text/`, pictures in `images/`.
            try MOBIMarkupNormalizer.normalize(body, image: { try image($0 - 1).map { "../" + $0 } },
                                               warnings: &warnings)
            // A section with no text, no picture and nothing linking into it is
            // markup between two page breaks (Calibre ends a book with one).
            let text = try body.text()
            let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines.union(["\u{00A0}"])).isEmpty
            let hasImage = try !body.getElementsByTag("img").isEmpty()
            let isTarget = targets.contains { $0 >= section.start && $0 < section.end }
            guard hasText || hasImage || isTarget else { continue }
            document.outputSettings().syntax(syntax: .xml).escapeMode(.xhtml).prettyPrint(pretty: false)
            written.append((index, try body.html(), text.utf16.count))
        }

        // Pass 2: chapter files are known; links and the table of contents resolve.
        let hrefBySection = Dictionary(uniqueKeysWithValues: written.enumerated().map {
            ($0.element.section, String(format: "text/c%04d.xhtml", $0.offset + 1))
        })
        func href(for filepos: Int) -> String? {
            guard let section = sections.firstIndex(where: { filepos >= $0.start && filepos < $0.end }),
                  let file = hrefBySection[section] else { return nil }
            return "\(file)#filepos\(filepos)"
        }
        // The guide's table-of-contents page first: Calibre's MOBI 6 NCX is flat
        // where its page nests as the source did. The NCX for a file without one.
        let toc = (tocPage.isEmpty ? ncx.map(Node.init) : nestedTOC(tocPage)).flatMap { resolve($0, href) }
        let metadata = try file.metadata.entitiesDecoded()

        var chapters: [MOBIConvertedBook.Chapter] = []
        for entry in written {
            let body = resolveLinks(in: entry.body, href: href, warnings: &warnings)
            // Every chapter's <title> is the book's, not a table-of-contents entry's:
            // the chapter digest covers the whole document, and a better table of
            // contents must not count as a text change. Readers take chapter titles
            // from the navigation document.
            chapters.append(.init(href: hrefBySection[entry.section]!,
                                  xhtml: chapterDocument(body: body, title: metadata.title ?? "",
                                                         language: metadata.language),
                                  textLength: entry.textLength))
        }

        if let cover = metadata.coverResource {
            if let path = try image(cover), let index = resources.firstIndex(where: { $0.href == path }) {
                resources[index].isCover = true
            } else {
                warnings.append("the cover names resource \(cover), which holds no image")
            }
        }
        resources.append(.init(href: "style/mobi.css", mediaType: "text/css", data: Data(stylesheet.utf8),
                               isCover: false))
        resources.sort { $0.href < $1.href }
        return MOBIConvertedBook(kind: .mobi6, metadata: metadata, chapters: chapters, resources: resources,
                                 toc: toc, warnings: warnings)
    }

    // MARK: Sections

    /// A section's bytes with an empty `<a id="fileposN">` at every link target
    /// inside it, decoded, with its page break and Kindle's `</br>` removed
    /// (foliate's `loadText`).
    private static func decodedSection(_ raw: [UInt8], _ section: Section, targets: [Int],
                                       encoding: MOBITextEncoding) throws -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(section.end - section.start + 64)
        var cursor = section.start
        for filepos in targets where filepos >= section.start && filepos < section.end {
            let at = insertionPoint(raw, filepos, from: max(cursor, section.start), encoding: encoding)
            bytes.append(contentsOf: raw[cursor..<at])
            bytes.append(contentsOf: Array(#"<a id="filepos\#(filepos)"></a>"#.utf8))
            cursor = at
        }
        bytes.append(contentsOf: raw[cursor..<section.end])
        var html = encoding.decode(Data(bytes))
        html = pagebreak.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html),
                                                  withTemplate: "")
        html = brEndTag.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html),
                                                 withTemplate: "")
        return html
    }

    /// Where an anchor for `filepos` can go: the byte itself, unless that falls
    /// inside a tag (then before the tag) or inside a UTF-8 character (then
    /// before the character). Never before `floor`, the previous anchor's place.
    private static func insertionPoint(_ raw: [UInt8], _ filepos: Int, from floor: Int,
                                       encoding: MOBITextEncoding) -> Int {
        var at = filepos
        var scan = filepos - 1
        while scan >= floor {
            if raw[scan] == UInt8(ascii: ">") { break }
            if raw[scan] == UInt8(ascii: "<") {
                at = scan
                break
            }
            scan -= 1
        }
        if encoding == .utf8 {
            while at > floor, at < raw.count, raw[at] & 0xC0 == 0x80 { at -= 1 }
        }
        return at
    }

    // MARK: Table of contents

    /// foliate's reading of a Kindle table-of-contents page: every `filepos` link
    /// in order, nested by how far its ancestors indent it (1.5 for each `<p>`,
    /// 2 for each `<blockquote>`).
    private static func tableOfContentsLinks(in document: Document) throws
        -> [(title: String, filepos: Int, indent: Double)] {
        try document.select("a[filepos]").array().compactMap { link in
            guard let filepos = Int(try link.attr("filepos")) else { return nil }
            var indent = 0.0
            var parent = link.parent()
            while let element = parent {
                switch element.tagName().lowercased() {
                case "p": indent += 1.5
                case "blockquote": indent += 2
                default: break
                }
                parent = element.parent()
            }
            return (try link.text().trimmingCharacters(in: .whitespacesAndNewlines), filepos, indent)
        }
    }

    private final class Node {
        let title: String
        /// nil for an NCX entry without one: it gives its place to its children.
        let filepos: Int?
        var children: [Node] = []
        init(title: String, filepos: Int?) {
            self.title = title
            self.filepos = filepos
        }

        convenience init(_ entry: MOBINCXEntry) {
            self.init(title: entry.title, filepos: entry.offset)
            children = entry.children.map(Node.init)
        }
    }

    private static func offsets(_ entry: MOBINCXEntry) -> [Int] {
        (entry.offset.map { [$0] } ?? []) + entry.children.flatMap(offsets)
    }

    /// foliate's nesting: deeper than the last entry is one level down, the same
    /// indent is the same level, and a shallower indent returns to the level that
    /// indent last had (else one level up).
    private static func nestedTOC(_ links: [(title: String, filepos: Int, indent: Double)]) -> [Node] {
        var roots: [Node] = []
        var lastItem: Node?
        var lastLevel = 0
        var lastIndent = 0.0
        var levelOfIndent: [Double: Int] = [:]
        var parentOfLevel: [Int: Node] = [:]
        for link in links {
            let item = Node(title: link.title, filepos: link.filepos)
            let level = link.indent > lastIndent ? lastLevel + 1
                : link.indent == lastIndent ? lastLevel
                : levelOfIndent[link.indent] ?? max(0, lastLevel - 1)
            if level > lastLevel {
                if let lastItem {
                    lastItem.children.append(item)
                    parentOfLevel[level] = lastItem
                } else {
                    roots.append(item)
                }
            } else if let parent = parentOfLevel[level] {
                parent.children.append(item)
            } else {
                roots.append(item)
            }
            lastItem = item
            lastLevel = level
            lastIndent = link.indent
            levelOfIndent[link.indent] = level
        }
        return roots
    }

    /// An entry whose target lies past the text is dropped with its children; one
    /// with no title (a linked picture) gives its place to its children, because a
    /// navigation document's entries need text.
    private static func resolve(_ node: Node, _ href: (Int) -> String?) -> [MOBIConvertedBook.TOCEntry] {
        let children = node.children.flatMap { resolve($0, href) }
        guard let filepos = node.filepos else { return children }
        guard let target = href(filepos) else { return [] }
        guard !node.title.isEmpty else { return children }
        return [.init(title: node.title, href: target, children: children)]
    }

    // MARK: Documents

    /// Every placeholder link written in pass 1, pointed at its chapter file;
    /// one whose byte lies past the text loses its `href`.
    private static func resolveLinks(in body: String, href: (Int) -> String?, warnings: inout [String]) -> String {
        let text = body as NSString
        var result = ""
        var cursor = 0
        for match in linkPlaceholder.matches(in: body, range: NSRange(location: 0, length: text.length)) {
            result += text.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let filepos = Int(text.substring(with: match.range(at: 1)))!
            if let target = href(filepos) {
                // Chapters share a folder, so the file name is the whole relative path.
                result += "href=\"\(MOBIMarkupNormalizer.escaped((target as NSString).lastPathComponent))\""
            } else {
                warnings.append("a link points at byte \(filepos), past the text")
            }
            cursor = match.range.location + match.range.length
        }
        result += text.substring(from: cursor)
        return result
    }

    private static func chapterDocument(body: String, title: String, language: String?) -> String {
        let escape = MOBIMarkupNormalizer.escaped
        let lang = language.map { " xml:lang=\"\(escape($0))\" lang=\"\(escape($0))\"" } ?? ""
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml"\(lang)>
            <head><meta charset="UTF-8"/><title>\(escape(title))</title><link rel="stylesheet" type="text/css" href="../style/mobi.css"/></head>
            <body>\(body)</body>
            </html>

            """
    }
}
