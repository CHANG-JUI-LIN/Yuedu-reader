import Foundation
import ReadiumZIPFoundation
import SwiftSoup
import Testing
import UIKit
@testable import yuedu_app

/// The converter's oracle is the EPUB each Calibre fixture was made from: what the
/// MOBI 6 file carries over of it must come back out unchanged.
@Suite("MOBI 6 converter", .serialized)
struct MOBI6ConverterTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/MOBI")

    static let mobi6Fixtures = [
        "features.mobi", "features-uncompressed.mobi", "vertical-zh.mobi", "gutenberg-11-kindle.mobi",
    ]

    private static func convert(_ name: String) throws -> MOBIConvertedBook {
        try MOBI6Converter.convert(MOBIFile(data: Data(contentsOf: fixtures.appendingPathComponent(name))))
    }

    // MARK: - Text

    @Test("every chapter's text is the source EPUB's, in order", arguments: [
        ("features.mobi", "features.epub"), ("features-uncompressed.mobi", "features.epub"),
        ("vertical-zh.mobi", "vertical-zh.epub"), ("gutenberg-11-kindle.mobi", "gutenberg-11.epub"),
    ])
    func textMatchesSource(mobi: String, epub: String) async throws {
        let book = try Self.convert(mobi)
        let sourceWords = try await Self.spineDocuments(of: Self.fixtures.appendingPathComponent(epub))
            .flatMap { try Self.words(in: $0) }
        // Calibre adds one page of its own, the table of contents, last.
        let tocPage = try #require(book.chapters.last)
        #expect(try Self.words(in: tocPage.xhtml).starts(with: ["Table", "of", "Contents"]))
        let words = try book.chapters.dropLast().flatMap { try Self.words(in: $0.xhtml) }
        #expect(Self.firstDifference(words, sourceWords) == nil)
    }

    @Test("every chapter is well-formed XML", arguments: mobi6Fixtures)
    func wellFormed(name: String) throws {
        for chapter in try Self.convert(name).chapters {
            let parser = XMLParser(data: Data(chapter.xhtml.utf8))
            #expect(parser.parse(), "\(chapter.href): \(String(describing: parser.parserError))")
        }
    }

    /// The text contract (`docs/aozora/epub-text-contract.md`, which MOBI shares):
    /// reading positions index these chapters, so this fails on any change to their
    /// output, the converter's or SwiftSoup's serialisation. Until a release ships
    /// MOBI import nobody holds a position into them, and re-pinning is the fix.
    /// After it, a failure means bumping `MOBIEPUBWriter.textVersion` and shipping
    /// a position migration with it; never re-pin alone.
    @Test("chapter digests are pinned: a change here is a text change", arguments: [
        ("features.mobi", 5, "120db223d5b56abcb678d2550ec7399546d1d5a2da920f677dbf74b1873542d2"),
        ("features-uncompressed.mobi", 5, "120db223d5b56abcb678d2550ec7399546d1d5a2da920f677dbf74b1873542d2"),
        ("vertical-zh.mobi", 4, "81f895dd37811f30506847eb9d69497b7d602ce6aefd82d4ef6166e7b92f7ace"),
        ("gutenberg-11-kindle.mobi", 19, "9f42070059c4bff101d2487366e62afdb4970a1100f5f8f95034d6a58d8c47f2"),
    ])
    func pinnedText(name: String, chapters: Int, digest: String) throws {
        let book = try Self.convert(name)
        let digests = book.chapters.map { MOBIEPUBWriter.chapterDigest($0, in: book) }
        #expect(digests.count == chapters)
        #expect(EPUBPackageArchive.sha256(Data(digests.joined(separator: "\n").utf8)) == digest)
    }

    // MARK: - Table of contents and links

    @Test("the table of contents nests as the source's does")
    func tableOfContents() throws {
        #expect(Self.outline(try Self.convert("features.mobi").toc)
            == ["The First Watch", "Instruments", "  The Lens", "  The Clockwork", "Tides"])
        #expect(Self.outline(try Self.convert("vertical-zh.mobi").toc) == ["第一章　交接", "第二章　潮汐"])
    }

    @Test("Project Gutenberg's table of contents comes back as its EPUB lists it")
    func gutenbergTableOfContents() async throws {
        let book = try Self.convert("gutenberg-11-kindle.mobi")
        let ncx = try await Self.text(of: "OEBPS/toc.ncx", in: Self.fixtures.appendingPathComponent("gutenberg-11.epub"))
        let labels = ncx.matches(of: #/<navPoint\b[^>]*>\s*<navLabel>\s*<text>([^<]*)</text>/#).map { String($0.1) }
        #expect(labels.count == 16)
        #expect(Self.outline(book.toc) == labels)
    }

    @Test("a file whose guide names no table-of-contents page takes its NCX, which Calibre writes flat")
    func navigationIndexWithoutTOCPage() throws {
        var data = try Data(contentsOf: Self.fixtures.appendingPathComponent("features-uncompressed.mobi"))
        // The guide's one reference, renamed in place so no byte moves.
        let reference = Data(#"type="toc""#.utf8)
        let at = try #require(data.firstRange(of: reference))
        data.replaceSubrange(at, with: Data(#"type="xxx""#.utf8))
        let book = try MOBI6Converter.convert(MOBIFile(data: data))
        #expect(Self.outline(book.toc) == ["The First Watch", "Instruments", "The Lens", "The Clockwork", "Tides"])
        #expect(book.warnings.isEmpty)
        for entry in book.toc {
            let (file, id) = Self.split(entry.href)
            let chapter = try #require(book.chapters.first { $0.href == file })
            // The anchor before a heading moves onto it.
            let fragment = try #require(id)
            let heading = try #require(try SwiftSoup.parse(chapter.xhtml).getElementById(fragment))
            let text = try heading.text()
            #expect(text.hasPrefix(entry.title), "\(entry.title) lands on «\(text)»")
        }
    }

    @Test("every link and table-of-contents entry reaches an element that exists", arguments: mobi6Fixtures)
    func linksResolve(name: String) throws {
        let book = try Self.convert(name)
        var ids: [String: Set<String>] = [:]
        var targets = Self.flattened(book.toc).map(\.href)
        for chapter in book.chapters {
            let document = try SwiftSoup.parse(chapter.xhtml)
            ids[chapter.href] = Set(try document.select("[id]").array().map { try $0.attr("id") })
            for link in try document.select("a[href]").array() {
                let href = try link.attr("href")
                guard URL(string: href)?.scheme == nil else { continue }
                targets.append(Self.resolved(href, from: chapter.href))
            }
        }
        #expect(!targets.isEmpty)
        for target in targets {
            let (file, id) = Self.split(target)
            let chapterIDs = ids[file]
            #expect(chapterIDs != nil, "\(target) names no chapter")
            if let id { #expect(chapterIDs?.contains(id) == true, "\(target) names no element") }
        }
    }

    @Test("a link lands on the heading it pointed at, in both directions")
    func linkTargets() throws {
        let book = try Self.convert("features.mobi")
        #expect(try Self.linkTarget(reading: "the last chapter", in: book).hasPrefix("Tides"))
        #expect(try Self.linkTarget(reading: "the first watch", in: book).hasPrefix("The First Watch"))
    }

    // MARK: - Pictures

    @Test("pictures become package files that their chapters' src attributes reach")
    func pictures() throws {
        let book = try Self.convert("features.mobi")
        let pictures = book.resources.filter { $0.href.hasPrefix("images/") }
        #expect(pictures.map(\.href) == ["images/image00001.jpg", "images/image00003.jpg"])
        #expect(pictures.map(\.isCover) == [true, false])
        #expect(book.resources.map(\.href) == pictures.map(\.href) + ["style/mobi.css"])
        for resource in pictures {
            #expect(UIImage(data: resource.data) != nil, "\(resource.href) decodes")
        }
        var shown: [String] = []
        for chapter in book.chapters {
            for image in try SwiftSoup.parse(chapter.xhtml).select("img").array() {
                shown.append(Self.resolved(try image.attr("src"), from: chapter.href))
            }
        }
        #expect(shown.sorted() == pictures.map(\.href))
        // Calibre moves the source's first page, the cover, to just before its
        // table of contents; the conversion keeps it where the file has it.
        let cover = book.chapters[book.chapters.count - 2]
        #expect(try Self.words(in: cover.xhtml).isEmpty)
        #expect(cover.xhtml.contains(#"src="../images/image00001.jpg""#))
        #expect(book.warnings.isEmpty)
    }

    // MARK: - Markup

    @Test("Kindle's presentational markup becomes CSS both engines read")
    func markup() throws {
        let html = #"<p height="1em" width="-14pt" align="justify"><font size="+1" face="Georgia">A</font> "#
            + #"<tt>B</tt> <u>C</u> <strike>D</strike> <a>E</a></p><blockquote height="0pt" width="2em">F</blockquote>"#
            + #"<center>G</center><table align="center" width="50%"><tr><td valign="top">H</td></tr></table>"#
            + #"<p><img recindex="00002" alt="x"><img recindex="00009"></p><mbp:nu>I</mbp:nu><!-- c -->"#
            + #"<a id="filepos5"></a><p id="k">J</p><a id="filepos9"></a><p>K</p>"#
        let document = try SwiftSoup.parse(html)
        let body = try #require(document.body())
        var warnings: [String] = []
        try MOBIMarkupNormalizer.normalize(body, image: { $0 == 2 ? "../images/image00002.jpg" : nil },
                                           warnings: &warnings)
        document.outputSettings().syntax(syntax: .xml).escapeMode(.xhtml).prettyPrint(pretty: false)
        #expect(try body.html() == #"<p style="margin-top: 1em; text-indent: -14pt; margin-left: 14pt; "#
            + #"text-align: justify"><span style="font-size: 1.125rem; font-family: 'Georgia'">A</span> "#
            + #"<span style="font-family: monospace">B</span> <span style="text-decoration: underline">C</span> "#
            + #"<span style="text-decoration: line-through">D</span> E</p>"#
            + #"<blockquote style="margin-top: 0pt; text-indent: 2em">F</blockquote>"#
            + #"<div style="text-align: center">G</div><table width="50%" style="margin-left: auto; "#
            + #"margin-right: auto"><tbody><tr><td>H</td></tr></tbody></table>"#
            + #"<p><img alt="x" src="../images/image00002.jpg" /></p>I"#
            + #"<p id="k"><a id="filepos5"></a>J</p><p id="filepos9">K</p>"#)
        #expect(warnings == ["an image names recindex 00009, which holds no image"])
    }

    @Test("Kindle lengths and font sizes", arguments: [
        ("1em", "1em"), ("-14pt", "-14pt"), ("5%", "5%"), ("12", "12px"), (" 0.5EM ", "0.5em"),
        ("1em;", nil), ("auto", nil), ("", nil),
    ])
    func lengths(raw: String, css: String?) {
        #expect(MOBIMarkupNormalizer.length(raw) == css)
    }

    @Test("font sizes 1–7 and relative sizes clamp to the legacy table", arguments: [
        ("1", "0.625rem"), ("3", "1rem"), ("7", "3rem"), ("+1", "1.125rem"), ("-2", "0.625rem"),
        ("+9", "3rem"), ("big", nil),
    ])
    func fontSizes(raw: String, css: String?) {
        #expect(MOBIMarkupNormalizer.fontSize(raw) == css)
    }

    // MARK: - Synthetic files (what Calibre never writes)

    @Test("a file with no guide is still read page by page, and its EPUB lists the title")
    func guidelessFile() async throws {
        let html = #"<html><head></head><body><p width="2em">First line<br></br>second line</p>"#
            + #"<mbp:pagebreak/><p height="1em">Next page</p></body></html>"#
        let data = MOBIFileTests.shortHeaderFile(text: Array(html.utf8), encoding: 65001,
                                                 title: Array("Guideless".utf8), locale: 9)
        let book = try MOBI6Converter.convert(MOBIFile(data: data))
        #expect(book.chapters.count == 2)
        #expect(book.toc.isEmpty)
        // `<br></br>` is one break on a Kindle, not two.
        #expect(book.chapters[0].xhtml.components(separatedBy: "<br />").count == 2)
        #expect(try Self.words(in: book.chapters[0].xhtml) == ["First", "line", "second", "line"])

        let written = try await Self.write(book)
        let session = try await PublicationSession.open(sourceURL: written.url)
        #expect(session.bookTitle == "Guideless")
        #expect(session.language == "en")
        #expect(session.chapters.count == 2)
        #expect(session.tocEntries.map(\.title) == ["Guideless"])
    }

    @Test("a picture or link the file cannot back is dropped with a warning, never invented")
    func brokenReferences() throws {
        let html = #"<html><body><p>See <a filepos="0099999">nowhere</a>.<img recindex="00001"></p></body></html>"#
        let data = MOBIFileTests.shortHeaderFile(text: Array(html.utf8), encoding: 65001,
                                                 title: Array("Broken".utf8), locale: 9)
        let book = try MOBI6Converter.convert(MOBIFile(data: data))
        let body = try #require(try SwiftSoup.parse(book.chapters[0].xhtml).body())
        #expect(try body.select("img").isEmpty())
        #expect(try body.select("a[href]").isEmpty())
        #expect(try body.text() == "See nowhere.")
        #expect(book.resources.map(\.href) == ["style/mobi.css"])
        #expect(book.warnings == ["an image names recindex 00001, which holds no image",
                                  "a link points at byte 99999, past the text"])
    }

    // MARK: - Writer

    @Test("the written EPUB opens with the book's metadata, chapters and table of contents")
    func writtenEPUBOpens() async throws {
        let book = try Self.convert("features.mobi")
        let written = try await Self.write(book)
        let session = try await PublicationSession.open(sourceURL: written.url)
        #expect(session.bookTitle == "The Lantern Keeper's Almanac")
        #expect(session.author.contains("Mira Holt"))
        #expect(session.language == "en")
        #expect(session.chapters.count == book.chapters.count)
        #expect(session.chapters.prefix(3).map(\.title) == ["The First Watch", "Instruments", "Tides"])
        #expect(session.tocEntries.map(\.title) == ["The First Watch", "Instruments", "The Lens", "The Clockwork", "Tides"])
        #expect(session.tocEntries.map(\.level) == [0, 0, 1, 1, 0])
    }

    @Test("mimetype comes first, stored, and the manifest pins every chapter file")
    func packageAndManifest() async throws {
        let original = try Data(contentsOf: Self.fixtures.appendingPathComponent("features.mobi"))
        let book = try MOBI6Converter.convert(MOBIFile(data: original))
        let written = try await Self.write(book, original: original)
        let archive = try await Archive(url: written.url, accessMode: .read)
        let first = try #require(try await archive.entries().first)
        #expect(first.path == "mimetype")
        #expect(!first.isCompressed)

        let manifest = try JSONDecoder().decode(
            MOBIEPUBManifest.self, from: try await Self.data(of: MOBIEPUBWriter.manifestPath, in: archive))
        #expect(manifest == written.manifest)
        #expect(manifest.converterVersion == MOBIEPUBWriter.converterVersion)
        #expect(manifest.textVersion == MOBIEPUBWriter.textVersion)
        #expect(manifest.source == MOBIEPUBManifest.Source(sha256: EPUBPackageArchive.sha256(original),
                                                           kind: .mobi6, length: original.count))
        #expect(manifest.chapters.map(\.href) == book.chapters.map(\.href))
        for (recorded, chapter) in zip(manifest.chapters, book.chapters) {
            #expect(recorded.length == chapter.textLength)
            #expect(recorded.sha256 == MOBIEPUBWriter.chapterDigest(chapter, in: book))
            // The file holds exactly what the digest covers.
            #expect(String(decoding: try await Self.data(of: "OPS/" + chapter.href, in: archive), as: UTF8.self)
                == chapter.xhtml)
        }
        #expect(String(decoding: try await Self.data(of: "OPS/style/mobi.css", in: archive), as: UTF8.self)
            == MOBI6Converter.stylesheet)
        for resource in book.resources {
            #expect(try await Self.data(of: "OPS/" + resource.href, in: archive) == resource.data)
        }
        for path in ["OPS/nav.xhtml", "OPS/package.opf", "META-INF/container.xml"] {
            let parser = XMLParser(data: try await Self.data(of: path, in: archive))
            #expect(parser.parse(), "\(path): \(String(describing: parser.parserError))")
        }
        let opf = String(decoding: try await Self.data(of: "OPS/package.opf", in: archive), as: UTF8.self)
        #expect(opf.contains(#"href="images/image00001.jpg" media-type="image/jpeg" properties="cover-image""#))
        #expect(opf.contains(#"<dc:creator id="creator2">Daniel Ashe</dc:creator>"#))
        #expect(opf.contains("<dc:identifier>urn:isbn:9780000000002</dc:identifier>"))
        #expect(!opf.contains("page-progression-direction"))
    }

    // MARK: - Helpers (KF8ConverterTests uses them too)

    struct Written {
        let url: URL
        let manifest: MOBIEPUBManifest
    }

    static func write(_ book: MOBIConvertedBook, original: Data = Data()) async throws -> Written {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mobi-\(UUID().uuidString).epub")
        let manifest = try await MOBIEPUBWriter.write(
            book, source: MOBIEPUBManifest.Source(original: original, kind: book.kind),
            identifier: "urn:uuid:\(UUID().uuidString)", to: url)
        return Written(url: url, manifest: manifest)
    }

    /// Every text node's words, in document order; a no-break space separates
    /// words like any other.
    static func words(in xhtml: String) throws -> [String] {
        var pieces: [String] = []
        func walk(_ node: Node) {
            for child in node.getChildNodes() {
                if let text = child as? TextNode {
                    pieces.append(text.getWholeText())
                } else {
                    walk(child)
                }
            }
        }
        guard let body = try SwiftSoup.parse(xhtml).body() else { return [] }
        walk(body)
        return pieces.joined(separator: " ").split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Where two word lists part, with some context, or nil when they are equal.
    static func firstDifference(_ converted: [String], _ source: [String]) -> String? {
        guard converted != source else { return nil }
        let index = converted.indices.first { $0 >= source.count || converted[$0] != source[$0] } ?? converted.count
        let context = { (words: [String]) in words[max(0, index - 5)..<min(words.count, index + 5)].joined(separator: " ") }
        return "word \(index) of \(converted.count) vs \(source.count): «\(context(converted))» vs «\(context(source))»"
    }

    static func flattened(_ entries: [MOBIConvertedBook.TOCEntry]) -> [MOBIConvertedBook.TOCEntry] {
        entries.flatMap { [$0] + flattened($0.children) }
    }

    /// One line per entry, indented two spaces a level.
    static func outline(_ entries: [MOBIConvertedBook.TOCEntry], depth: Int = 0) -> [String] {
        entries.flatMap { [String(repeating: "  ", count: depth) + $0.title] + outline($0.children, depth: depth + 1) }
    }

    /// `href` as it reads from `chapter`, package-relative to `OPS/`, fragment kept.
    static func resolved(_ href: String, from chapter: String) -> String {
        let base = URL(string: "file:///OPS/" + chapter)!
        let url = URL(string: href, relativeTo: base)!.absoluteURL.standardized
        let path = String(url.path.dropFirst("/OPS/".count))
        return url.fragment.map { "\(path)#\($0)" } ?? path
    }

    static func split(_ target: String) -> (file: String, id: String?) {
        let parts = target.split(separator: "#", maxSplits: 1).map(String.init)
        return (parts[0], parts.count > 1 ? parts[1] : nil)
    }

    /// The text of the element the link reading `text` points at.
    static func linkTarget(reading text: String, in book: MOBIConvertedBook) throws -> String {
        for chapter in book.chapters {
            for link in try SwiftSoup.parse(chapter.xhtml).select("a[href]").array() where try link.text() == text {
                let (file, id) = split(resolved(try link.attr("href"), from: chapter.href))
                let target = try #require(book.chapters.first { $0.href == file })
                let fragment = try #require(id)
                let element = try #require(try SwiftSoup.parse(target.xhtml).getElementById(fragment))
                return try element.text()
            }
        }
        Issue.record("no link reads \(text)")
        return ""
    }

    // MARK: Source EPUBs

    /// The source EPUB's spine documents, in reading order.
    static func spineDocuments(of epub: URL) async throws -> [String] {
        let container = try await text(of: "META-INF/container.xml", in: epub)
        let opfPath = String(try #require(container.firstMatch(of: #/full-path="([^"]+)"/#)?.1))
        let base = (opfPath as NSString).deletingLastPathComponent
        let opf = try await text(of: opfPath, in: epub)
        var hrefByID: [String: String] = [:]
        for item in opf.matches(of: #/<item\b[^>]*>/#) {
            guard let id = item.0.firstMatch(of: #/\bid="([^"]+)"/#)?.1,
                  let href = item.0.firstMatch(of: #/\bhref="([^"]+)"/#)?.1 else { continue }
            hrefByID[String(id)] = String(href)
        }
        var documents: [String] = []
        for itemref in opf.matches(of: #/<itemref\b[^>]*\bidref="([^"]+)"/#) {
            let href = try #require(hrefByID[String(itemref.1)])
            documents.append(try await text(of: base.isEmpty ? href : base + "/" + href, in: epub))
        }
        return documents
    }

    static func text(of path: String, in epub: URL) async throws -> String {
        let archive = try await Archive(url: epub, accessMode: .read)
        return String(decoding: try await data(of: path, in: archive), as: UTF8.self)
    }

    static func data(of path: String, in archive: Archive) async throws -> Data {
        let entry = try #require(try await archive.get(path), "\(path) is in the archive")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        _ = try await archive.extract(entry, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Data(contentsOf: url)
    }
}
