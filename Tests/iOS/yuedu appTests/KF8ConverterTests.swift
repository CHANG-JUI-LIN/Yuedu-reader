import Combine
import Foundation
import ReadiumZIPFoundation
import SwiftSoup
import Testing
import UIKit
import YueduCoreText
@testable import yuedu_app

/// As for MOBI 6, the oracle is the EPUB each fixture was made from. KF8 keeps the
/// source's XHTML, so more of it must come back: every word, the pictures byte for
/// byte, the stylesheets, the page progression.
@Suite("KF8 converter", .serialized)
struct KF8ConverterTests {
    private typealias Helpers = MOBI6ConverterTests

    static let kf8Fixtures = [
        "features.azw3", "features-combo.mobi", "vertical-zh.azw3", "gutenberg-11-kf8.azw3", "embedded-font.azw3",
        "fixed-layout.azw3",
    ]

    private static func convert(_ name: String) throws -> MOBIConvertedBook {
        let file = try MOBIFile(data: Data(contentsOf: Helpers.fixtures.appendingPathComponent(name)))
        #expect(file.kind == .kf8)
        return try KF8Converter.convert(file)
    }

    private static func source(_ name: String) -> URL {
        let epub = ["features.azw3": "features.epub", "features-combo.mobi": "features.epub",
                    "vertical-zh.azw3": "vertical-zh.epub", "gutenberg-11-kf8.azw3": "gutenberg-11.epub",
                    "embedded-font.azw3": "embedded-font.epub", "fixed-layout.azw3": "fixed-layout.epub"][name]!
        return Helpers.fixtures.appendingPathComponent(epub)
    }

    // MARK: - Text

    @Test("every word of the source EPUB comes back, in order", arguments: kf8Fixtures)
    func textMatchesSource(name: String) async throws {
        let book = try Self.convert(name)
        let sourceWords = try await Helpers.spineDocuments(of: Self.source(name)).flatMap { try Helpers.words(in: $0) }
        // Calibre adds a page of its own, the table of contents, last, to a book
        // with more than one entry.
        let added = book.chapters.filter { $0.xhtml.contains(#"id="calibre_generated_inline_toc""#) }
        #expect(added.map(\.href) == (book.toc.count > 1 ? [book.chapters.last!.href] : []))
        for page in added {
            #expect(try Helpers.words(in: page.xhtml).starts(with: ["Table", "of", "Contents"]))
        }
        let words = try book.chapters.filter { !added.contains($0) }.flatMap { try Helpers.words(in: $0.xhtml) }
        #expect(Helpers.firstDifference(words, sourceWords) == nil)
    }

    @Test("every chapter is well-formed XML and nothing was left behind", arguments: kf8Fixtures)
    func wellFormed(name: String) throws {
        let book = try Self.convert(name)
        #expect(book.warnings.isEmpty)
        for chapter in book.chapters {
            let parser = XMLParser(data: Data(chapter.xhtml.utf8))
            #expect(parser.parse(), "\(chapter.href): \(String(describing: parser.parserError))")
            #expect(!chapter.xhtml.contains("kindle:"), "\(chapter.href) still names a kindle: URL")
        }
        for stylesheet in book.resources where stylesheet.mediaType == "text/css" {
            #expect(!String(decoding: stylesheet.data, as: UTF8.self).contains("kindle:"))
        }
    }

    /// The text contract, as `MOBI6ConverterTests.pinnedText` states it: until a
    /// release ships MOBI import, re-pinning is the fix; after it, a failure means
    /// bumping `MOBIEPUBWriter.textVersion` with a position migration.
    @Test("chapter digests are pinned: a change here is a text change", arguments: [
        ("features.azw3", 5, "f747cf86af16ba2a9083c9c7a3f4f2dbcc74f03882a629ca6586c36d284ca50f"),
        ("features-combo.mobi", 5, "ad465023279da89dc52db4cca831a03a1eb5e2ebdb03d1446c2621093e021e45"),
        ("vertical-zh.azw3", 4, "9f84d2d860c3f5f1996344ef1f085879e26eac1822e3b6ec943bd22bf1d3d60c"),
        ("gutenberg-11-kf8.azw3", 19, "9f1f9758fe19a727251a60cd2cf1163b00f6f29d27de2c9114ec5cc2fb4b8336"),
        ("embedded-font.azw3", 2, "23a5a81147b10623c1eea947a729ca16506f2fa8d79363063a59975a73366dbd"),
        ("fixed-layout.azw3", 4, "07386d419ef24a374016f46cd2cfe509a0e77ae72e256c743b6d480b3071f5a0"),
    ])
    func pinnedText(name: String, chapters: Int, digest: String) throws {
        let book = try Self.convert(name)
        let digests = book.chapters.map { MOBIEPUBWriter.chapterDigest($0, in: book) }
        #expect(digests.count == chapters)
        #expect(EPUBPackageArchive.sha256(Data(digests.joined(separator: "\n").utf8)) == digest)
    }

    // MARK: - Table of contents and links

    @Test("the table of contents is the source's")
    func tableOfContents() async throws {
        #expect(Helpers.outline(try Self.convert("features.azw3").toc)
            == ["The First Watch", "Instruments", "  The Lens", "  The Clockwork", "Tides"])
        #expect(Helpers.outline(try Self.convert("vertical-zh.azw3").toc) == ["第一章　交接", "第二章　潮汐"])
        let ncx = try await Helpers.text(of: "OEBPS/toc.ncx", in: Self.source("gutenberg-11-kf8.azw3"))
        let labels = ncx.matches(of: #/<navPoint\b[^>]*>\s*<navLabel>\s*<text>([^<]*)</text>/#).map { String($0.1) }
        #expect(labels.count == 16)
        #expect(Helpers.outline(try Self.convert("gutenberg-11-kf8.azw3").toc) == labels)
    }

    /// The fixed-layout book's entries name pages, which start with a caption, not a heading.
    @Test("each table-of-contents entry lands on the element that starts with its title",
          arguments: kf8Fixtures.filter { $0 != "fixed-layout.azw3" })
    func tableOfContentsTargets(name: String) throws {
        let book = try Self.convert(name)
        for entry in Helpers.flattened(book.toc) {
            let (file, id) = Helpers.split(entry.href)
            let chapter = try #require(book.chapters.first { $0.href == file })
            let fragment = try #require(id)
            let element = try #require(try SwiftSoup.parse(chapter.xhtml).getElementById(fragment))
            // Gutenberg's headings break their lines; titles keep U+3000, which
            // counts as whitespace too, so both sides collapse the same way.
            func collapsed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            let text = collapsed(try element.text())
            #expect(text.hasPrefix(collapsed(entry.title)), "\(entry.title) lands on «\(text.prefix(60))»")
        }
    }

    @Test("every link and table-of-contents entry reaches an element that exists", arguments: kf8Fixtures)
    func linksResolve(name: String) throws {
        let book = try Self.convert(name)
        var ids: [String: Set<String>] = [:]
        var targets = Helpers.flattened(book.toc).map(\.href)
        for chapter in book.chapters {
            let document = try SwiftSoup.parse(chapter.xhtml)
            ids[chapter.href] = Set(try document.select("[id]").array().map { try $0.attr("id") })
            for link in try document.select("a[href]").array() {
                let href = try link.attr("href")
                guard URL(string: href)?.scheme == nil else { continue }
                targets.append(Helpers.resolved(href, from: chapter.href))
            }
        }
        #expect(!targets.isEmpty)
        for target in targets {
            let (file, id) = Helpers.split(target)
            let chapterIDs = ids[file]
            #expect(chapterIDs != nil, "\(target) names no chapter")
            if let id { #expect(chapterIDs?.contains(id) == true, "\(target) names no element") }
        }
    }

    @Test("a link lands on the heading it pointed at, in both directions")
    func linkTargets() throws {
        let book = try Self.convert("features.azw3")
        #expect(try Helpers.linkTarget(reading: "the last chapter", in: book).hasPrefix("Tides"))
        #expect(try Helpers.linkTarget(reading: "the first watch", in: book).hasPrefix("The First Watch"))
    }

    @Test("a target with only an aid gets an id made from it, and the rest of the tag is untouched")
    func aidTargets() throws {
        let chapter = try Self.convert("vertical-zh.azw3").chapters[1]
        #expect(chapter.xhtml.contains(#"<h1 id="aid-UGI1" class="calibre3" aid="UGI1">第一章　交接</h1>"#))
    }

    // MARK: - Resources

    @Test("pictures are the source's bytes, and every src reaches one", arguments: kf8Fixtures)
    func pictures(name: String) async throws {
        let book = try Self.convert(name)
        let pictures = book.resources.filter { $0.href.hasPrefix("images/") }
        #expect(!pictures.isEmpty)
        #expect(pictures.filter(\.isCover).count == 1)
        let sourcePictures = try await Self.sourcePictures(Self.source(name))
        for picture in pictures {
            if name == "features-combo.mobi" {
                // A combination file's two parts share the MOBI 6 part's pictures,
                // which Calibre re-encodes as JPEG.
                #expect(UIImage(data: picture.data) != nil, "\(picture.href) decodes")
            } else {
                #expect(sourcePictures.contains(picture.data), "\(picture.href) is a source picture")
            }
        }
        var shown: Set<String> = []
        for chapter in book.chapters {
            let document = try SwiftSoup.parse(chapter.xhtml)
            for image in try document.select("img[src]").array() {
                shown.insert(Helpers.resolved(try image.attr("src"), from: chapter.href))
            }
            for image in try document.getElementsByTag("image").array() {
                shown.insert(Helpers.resolved(try image.attr("xlink:href"), from: chapter.href))
            }
        }
        #expect(shown == Set(pictures.map(\.href)))
    }

    @Test("Calibre's SVG cover wrapper is inline again, as the source had it")
    func svgCover() throws {
        let cover = try Self.convert("gutenberg-11-kf8.azw3").chapters[0]
        let svg = try #require(try SwiftSoup.parse(cover.xhtml).getElementsByTag("svg").first())
        #expect(try svg.attr("viewBox") == "0 0 800 1104")
        let image = try #require(try svg.getElementsByTag("image").first())
        #expect(try image.attr("xlink:href") == "../images/image00001.jpg")
        #expect(!cover.xhtml.contains("<img"))
        // The flow's own XML declaration stays out: a document has one, at its start.
        #expect(cover.xhtml.components(separatedBy: "<?xml").count == 2)
    }

    @Test("the stylesheets are the file's flows, linked from every chapter that used them")
    func stylesheets() throws {
        let book = try Self.convert("vertical-zh.azw3")
        let stylesheets = book.resources.filter { $0.mediaType == "text/css" }
        #expect(stylesheets.map(\.href) == ["style/flow0001.css", "style/flow0002.css", "style/flow0003.css"])
        #expect(String(decoding: stylesheets[0].data, as: UTF8.self).contains("writing-mode: vertical-rl"))
        for chapter in book.chapters {
            for link in try SwiftSoup.parse(chapter.xhtml).select("link[rel=stylesheet]").array() {
                let href = Helpers.resolved(try link.attr("href"), from: chapter.href)
                #expect(stylesheets.contains { $0.href == href }, "\(chapter.href) links \(href)")
            }
        }
    }

    @Test("an embedded font comes back byte for byte, where the stylesheet's @font-face finds it")
    func embeddedFont() throws {
        let book = try Self.convert("embedded-font.azw3")
        let font = try #require(book.resources.first { $0.href.hasPrefix("fonts/") })
        #expect(font.href == "fonts/font00003.ttf")
        #expect(font.mediaType == "font/ttf")
        #expect(font.data == (try Data(contentsOf: Helpers.fixtures.deletingLastPathComponent().appendingPathComponent("Ahem.ttf"))))
        let faces = book.resources.filter { $0.mediaType == "text/css" }
            .map { String(decoding: $0.data, as: UTF8.self) }.filter { $0.contains("@font-face") }
        #expect(faces.count == 1)
        #expect(faces.first?.contains("src: url(../fonts/font00003.ttf)") == true)
    }

    /// Calibre writes its fonts zlib-compressed and XOR-obfuscated with a 20-byte
    /// key (flags 3, which `embeddedFont` reads); the 16-byte key and the plain
    /// record come from other tools, so they are built here.
    @Test("a FONT record is de-obfuscated over 1040 bytes, or 1024 with a 16-byte key, then inflated")
    func fontRecords() throws {
        let font = Data((0..<3000).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) })
        func record(flags: UInt32, key: [UInt8], body: Data) -> Data {
            var data = Data("FONT".utf8)
            for field in [UInt32(font.count), flags, UInt32(24 + key.count), UInt32(key.count), 24] {
                data.append(contentsOf: withUnsafeBytes(of: field.bigEndian, Array.init))
            }
            return data + key + body
        }
        func obfuscated(_ data: Data, key: [UInt8], count: Int) -> Data {
            var bytes = [UInt8](data)
            for index in 0..<count { bytes[index] ^= key[index % key.count] }
            return Data(bytes)
        }
        let key16 = (0..<16).map { UInt8($0 * 11 + 1) }
        #expect(try KF8Converter.font(record(flags: 2, key: key16, body: obfuscated(font, key: key16, count: 1024)))
            == font)
        let key20 = (0..<20).map { UInt8($0 * 13 + 5) }
        #expect(try KF8Converter.font(record(flags: 2, key: key20, body: obfuscated(font, key: key20, count: 1040)))
            == font)
        #expect(try KF8Converter.font(record(flags: 0, key: [], body: font)) == font)

        let deflated = try (font as NSData).compressed(using: .zlib) as Data
        var adler: (a: UInt32, b: UInt32) = (1, 0)
        for byte in font {
            adler.a = (adler.a + UInt32(byte)) % 65521
            adler.b = (adler.b + adler.a) % 65521
        }
        let zlib = Data([0x78, 0x9C]) + deflated + withUnsafeBytes(of: (adler.b << 16 | adler.a).bigEndian, Array.init)
        #expect(try KF8Converter.font(record(flags: 1, key: [], body: zlib)) == font)
        var damaged = zlib
        damaged[damaged.count - 1] ^= 0xFF
        #expect(throws: GzipDecoderError.checksumMismatch) {
            try KF8Converter.font(record(flags: 1, key: [], body: damaged))
        }
    }

    /// Calibre's KF8 output keeps none of a fixed-layout book's markers: no EXTH
    /// 122 or 126, no RESC record. Its pages come out reflowable, as a Kindle shows
    /// a Calibre-made fixed-layout book; the viewport `<meta>` stays in the XHTML.
    @Test("Calibre writes a fixed-layout book's KF8 without its fixed-layout records")
    func fixedLayoutFromCalibre() async throws {
        let file = try MOBIFile(data: Data(contentsOf: Helpers.fixtures.appendingPathComponent("fixed-layout.azw3")))
        #expect(file.metadata.fixedLayout == false)
        #expect(file.metadata.originalResolution == nil)
        let resources = try (0..<(file.recordCount - file.resourceStart)).map { try file.resource($0).prefix(4) }
        #expect(!resources.contains(Data("RESC".utf8)))
        let book = try KF8Converter.convert(file)
        #expect(book.chapters[1].xhtml.contains(#"<meta name="viewport" content="width=600, height=800"/>"#))
        let session = try await PublicationSession.open(sourceURL: try await Helpers.write(book).url)
        let source = try await PublicationSession.open(sourceURL: Self.source("fixed-layout.azw3"))
        #expect(source.layoutMode == .prePaginated)
        #expect(session.layoutMode == .reflowable)
    }

    // MARK: - Writer

    @Test("the written EPUB opens as its source does: title, language, direction, layout",
          arguments: kf8Fixtures.filter { $0 != "fixed-layout.azw3" })
    func renditionMatchesSource(name: String) async throws {
        let book = try Self.convert(name)
        let written = try await Helpers.write(book)
        let converted = try await PublicationSession.open(sourceURL: written.url)
        let source = try await PublicationSession.open(sourceURL: Self.source(name))
        #expect(converted.bookTitle == source.bookTitle)
        #expect(converted.epubWritingMode == source.epubWritingMode)
        #expect(converted.pageProgressionDirection == source.pageProgressionDirection)
        #expect(converted.layoutMode == source.layoutMode)
        #expect(converted.tocEntries.map(\.title) == source.tocEntries.map(\.title))
        #expect(converted.tocEntries.map(\.level) == source.tocEntries.map(\.level))
        // Calibre writes the language without its region (zh-TW becomes zh).
        #expect(converted.language?.prefix(2) == source.language?.prefix(2))
        #expect(converted.chapters.count == book.chapters.count)
        // The opening animation's preflight, by the reader's own rules
        // (`BookWritingModes`; per-document modes are `BookWritingModesTests`).
        let convertedIsRTL = await PublicationSession.inspectDirectionIsRTL(sourceURL: written.url)
        let sourceIsRTL = await PublicationSession.inspectDirectionIsRTL(sourceURL: Self.source(name))
        #expect(convertedIsRTL == sourceIsRTL)
        #expect(convertedIsRTL == (name == "vertical-zh.azw3"))
    }

    /// The reader's own answer (`EPUBPageRenderer.resolveWritingModes`, the resolver both engines ask):
    /// the conversion reads in its source's direction, each document it shares with the source is laid out
    /// in the source's mode, and the table of contents Calibre appends, which declares no mode in a book
    /// whose CSS declares them, is horizontal.
    @Test("the reader lays the conversion out in its source's direction and modes, its appended TOC horizontal",
          arguments: ["vertical-zh.azw3", "features.azw3"])
    @MainActor
    func verticalInReader(name: String) async throws {
        func modes(_ url: URL) async throws -> (direction: BookDirection, chapters: [ReaderWritingMode]) {
            let session = try await PublicationSession.open(sourceURL: url)
            let modes = await EPUBPageRenderer().resolveWritingModes(for: session)
            var chapters: [ReaderWritingMode] = []
            for spine in session.chapters.indices { chapters.append(await modes.writingMode(forSpine: spine)) }
            return (modes.direction, chapters)
        }
        let source = try await modes(Self.source(name))
        let converted = try await modes(try await Helpers.write(try Self.convert(name)).url)
        #expect(converted.direction == source.direction)
        #expect(source.direction.isRTL == (name == "vertical-zh.azw3"))
        // The source's reading order marks its cover `linear="no"`, which the reader's chapters leave
        // out, so the conversion's documents do not line up with the source's by index.
        if name == "vertical-zh.azw3" {
            #expect(source.chapters == [.verticalRTL, .verticalRTL])
            #expect(converted.chapters == [.verticalRTL, .verticalRTL, .verticalRTL, .horizontal])
        } else {
            #expect(source.chapters.allSatisfy { $0 == .horizontal })
            #expect(converted.chapters.allSatisfy { $0 == .horizontal })
        }
    }

    @Test("the package records a KF8 source and writes the page progression from EXTH 527, not 525")
    func package() async throws {
        let original = try Data(contentsOf: Helpers.fixtures.appendingPathComponent("vertical-zh.azw3"))
        let book = try KF8Converter.convert(MOBIFile(data: original))
        let written = try await Helpers.write(book, original: original)
        #expect(written.manifest.source.kind == .kf8)
        let opf = try await Helpers.text(of: "OPS/package.opf", in: written.url)
        #expect(opf.contains(#"<spine page-progression-direction="rtl">"#))
        #expect(!opf.contains("primary-writing-mode"))
        #expect(opf.contains(#"href="style/flow0001.css" media-type="text/css""#))
        let horizontal = try await Helpers.write(try Self.convert("features.azw3"))
        #expect(!(try await Helpers.text(of: "OPS/package.opf", in: horizontal.url)).contains("page-progression-direction"))
    }

    // MARK: - Helpers

    private static func sourcePictures(_ epub: URL) async throws -> [Data] {
        let archive = try await Archive(url: epub, accessMode: .read)
        var pictures: [Data] = []
        for entry in try await archive.entries()
        where ["png", "jpg", "jpeg", "gif"].contains((entry.path as NSString).pathExtension.lowercased()) {
            pictures.append(try await Helpers.data(of: entry.path, in: archive))
        }
        return pictures
    }
}
