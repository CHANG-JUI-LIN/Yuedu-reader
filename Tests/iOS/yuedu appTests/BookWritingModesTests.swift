import Foundation
import ReadiumZIPFoundation
import Testing
import YueduCoreText
@testable import yuedu_app

/// Writing mode is decided per document, page order per book (`Technotes`-level rules in
/// `BookWritingModeFacts`). The case that started it: a Calibre conversion of a vertical book appends a
/// generated table of contents that declares no writing mode, and the reader laid it out vertically.
@Suite("BookWritingModes", .serialized)
@MainActor
struct BookWritingModesTests {
    private typealias MOBI = MOBI6ConverterTests

    // MARK: - Reader and shelf

    /// Every spine's mode, the direction, and the shelf's answer for the same file.
    private struct Resolved {
        let modes: [ReaderWritingMode]
        let direction: BookDirection
        let shelfIsRTL: Bool
    }

    private static func resolve(_ url: URL) async throws -> Resolved {
        let session = try await PublicationSession.open(sourceURL: url)
        let modes = await BookWritingModes.resolve(session: session,
                                                   resource: EPUBBrowserLayoutResourceAdapter(session: session))
        var perSpine: [ReaderWritingMode] = []
        for spine in session.chapters.indices { perSpine.append(await modes.writingMode(forSpine: spine)) }
        return Resolved(modes: perSpine, direction: modes.direction,
                        shelfIsRTL: await PublicationSession.inspectDirectionIsRTL(sourceURL: url))
    }

    private static func converted(_ name: String) async throws -> URL {
        let file = try MOBIFile(data: Data(contentsOf: MOBI.fixtures.appendingPathComponent(name)))
        return try await MOBI.write(try KF8Converter.convert(file)).url
    }

    @Test("a Calibre conversion's generated table of contents is horizontal inside a vertical book")
    func calibreInlineTableOfContents() async throws {
        let book = try await Self.resolve(try await Self.converted("vertical-zh.azw3"))
        #expect(book.modes == [.verticalRTL, .verticalRTL, .verticalRTL, .horizontal])
        #expect(book.direction == BookDirection(isRTL: true, principalMode: .verticalRTL))
        #expect(book.shelfIsRTL)
    }

    @Test("the conversion's chapters read as its source's do")
    func conversionMatchesSource() async throws {
        let source = try await Self.resolve(MOBI.fixtures.appendingPathComponent("vertical-zh.epub"))
        let converted = try await Self.resolve(try await Self.converted("vertical-zh.azw3"))
        #expect(Array(converted.modes.prefix(source.modes.count)) == source.modes)
        #expect(converted.direction == source.direction)
    }

    @Test("a horizontal conversion stays horizontal, left to right")
    func horizontalConversion() async throws {
        let book = try await Self.resolve(try await Self.converted("features.azw3"))
        #expect(book.modes.allSatisfy { $0 == .horizontal })
        #expect(!book.direction.isRTL)
        #expect(!book.shelfIsRTL)
    }

    @Test("a CSS-free Japanese book with right-to-left pages is vertical by its OPF")
    func opfInferenceWithoutCSS() async throws {
        let book = try await Self.resolve(try await Self.epub(language: "ja", progression: "rtl",
                                                              chapters: ["<p>山路を登りながら</p>", "<p>智に働けば</p>"]))
        #expect(book.modes == [.verticalRTL, .verticalRTL])
        #expect(book.direction == BookDirection(isRTL: true, principalMode: .verticalRTL))
        #expect(book.shelfIsRTL)
    }

    @Test("a vertical rule on an inner element does not turn the book vertical")
    func poemClass() async throws {
        let css = ".poem { writing-mode: vertical-rl }"
        let book = try await Self.resolve(try await Self.epub(
            language: "zh-Hant", css: css,
            chapters: [#"<p>序</p>"#, #"<p>正文</p><div class="poem"><p>床前明月光</p></div>"#]
        ))
        #expect(book.modes == [.horizontal, .horizontal])
        #expect(book.direction == BookDirection(isRTL: false, principalMode: .horizontal))
        #expect(!book.shelfIsRTL)
    }

    @Test("a document that declares horizontal is horizontal inside a vertical book, which still pages right to left")
    func declaredHorizontalChapter() async throws {
        let css = "html { writing-mode: vertical-rl } body.yoko { writing-mode: horizontal-tb }"
        let book = try await Self.resolve(try await Self.epub(
            language: "ja", progression: "rtl", css: css,
            chapters: ["<p>一</p>", "<p>二</p>", "<p>三</p>", "<p>Colophon</p>"],
            bodyClasses: [3: "yoko"]
        ))
        #expect(book.modes == [.verticalRTL, .verticalRTL, .verticalRTL, .horizontal])
        #expect(book.direction == BookDirection(isRTL: true, principalMode: .verticalRTL))
    }

    @Test("Hebrew pages right to left and stays horizontal")
    func hebrew() async throws {
        let book = try await Self.resolve(try await Self.epub(language: "he", progression: "rtl",
                                                              chapters: ["<p>בראשית</p>"]))
        #expect(book.modes == [.horizontal])
        #expect(book.direction == BookDirection(isRTL: true, principalMode: .horizontal))
        #expect(book.shelfIsRTL)
    }

    @Test("a CSS-only vertical book without a page progression pages right to left, on the shelf too")
    func cssOnlyVerticalWithoutProgression() async throws {
        let book = try await Self.resolve(try await Self.epub(
            language: "zh-Hant", css: "html { -epub-writing-mode: vertical-rl; writing-mode: vertical-rl }",
            chapters: ["<p>一</p>", "<p>二</p>"]
        ))
        #expect(book.modes == [.verticalRTL, .verticalRTL])
        #expect(book.direction == BookDirection(isRTL: true, principalMode: .verticalRTL))
        #expect(book.shelfIsRTL)
    }

    @Test("a declared left-to-right progression wins over a vertical principal mode")
    func declaredProgressionWins() async throws {
        let book = try await Self.resolve(try await Self.epub(
            language: "ja", progression: "ltr", css: "html { writing-mode: vertical-rl }", chapters: ["<p>一</p>"]
        ))
        #expect(book.modes == [.verticalRTL])
        #expect(book.direction == BookDirection(isRTL: false, principalMode: .verticalRTL))
        #expect(!book.shelfIsRTL)
    }

    // MARK: - Rules

    @Test("rule 1 reads any writing-mode declaration, under any selector and any spelling, but not comments")
    func declarationScan() {
        #expect(BookWritingModeFacts.containsWritingModeDeclaration(in: "body { writing-mode: vertical-rl; }"))
        #expect(BookWritingModeFacts.containsWritingModeDeclaration(in: ".book{-webkit-writing-mode:vertical-rl}"))
        #expect(BookWritingModeFacts.containsWritingModeDeclaration(in: "p { -epub-writing-mode: tb-rl }"))
        #expect(BookWritingModeFacts.containsWritingModeDeclaration(in: "body { writing-mode: horizontal-tb; }"))
        #expect(BookWritingModeFacts.containsWritingModeDeclaration(in: #"<body style="writing-mode:vertical-rl">"#))
        #expect(!BookWritingModeFacts.containsWritingModeDeclaration(in: "/* writing-mode: vertical-rl */ p {}"))
        #expect(!BookWritingModeFacts.containsWritingModeDeclaration(in: "p { text-orientation: upright }"))
    }

    @Test("undeclared documents follow the CSS when the book declares modes, the OPF when it does not")
    func bookDefault() {
        func facts(_ opf: EPUBWritingMode, css: Bool, progression: EPUBPageProgressionDirection = .default)
            -> BookWritingModeFacts {
            BookWritingModeFacts(opfWritingMode: opf, pageProgression: progression,
                                 declaresWritingModeInCSS: css, leadingDocumentHrefs: [])
        }
        #expect(facts(.verticalRL, css: true).bookDefault == .horizontal)
        #expect(facts(.verticalRL, css: false).bookDefault == .verticalRTL)
        #expect(facts(.unspecified, css: false).bookDefault == .horizontal)
        #expect(facts(.verticalRL, css: true).writingMode(declared: .verticalRTL) == .verticalRTL)
        #expect(facts(.verticalRL, css: true, progression: .rtl).direction(leadingDeclared: [nil, .verticalRTL])
                == BookDirection(isRTL: true, principalMode: .verticalRTL))
        #expect(facts(.unspecified, css: true).direction(leadingDeclared: [nil, nil])
                == BookDirection(isRTL: false, principalMode: .horizontal))
    }

    @Test("a book in the user's mode answers that mode everywhere")
    func uniform() async {
        let modes = BookWritingModes(uniform: .verticalRTL)
        #expect(modes.direction == BookDirection(isRTL: true, principalMode: .verticalRTL))
        #expect(await modes.writingMode(forSpine: 7) == .verticalRTL)
        #expect(modes.cachedWritingMode(forSpine: 7) == .verticalRTL)
    }

    // MARK: - Fixtures

    /// A minimal EPUB 3: one stylesheet linked from every chapter when `css` is given.
    private static func epub(language: String, progression: String? = nil, css: String? = nil,
                             chapters: [String], bodyClasses: [Int: String] = [:]) async throws -> URL {
        var entries: [String: Data] = [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """.utf8),
        ]
        let link = css == nil ? "" : #"<link rel="stylesheet" type="text/css" href="style.css"/>"#
        for (index, body) in chapters.enumerated() {
            let bodyClass = bodyClasses[index].map { #" class="\#($0)""# } ?? ""
            entries["OPS/c\(index).xhtml"] = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>\(index)</title>\(link)</head>
            <body\(bodyClass)>\(body)</body></html>
            """.utf8)
        }
        if let css { entries["OPS/style.css"] = Data(css.utf8) }
        let items = chapters.indices.map { #"<item id="c\#($0)" href="c\#($0).xhtml" media-type="application/xhtml+xml"/>"# }
            + (css == nil ? [] : [#"<item id="css" href="style.css" media-type="text/css"/>"#])
        let itemrefs = chapters.indices.map { #"<itemref idref="c\#($0)"/>"# }
        let spine = progression.map { #"<spine page-progression-direction="\#($0)">"# } ?? "<spine>"
        entries["OPS/package.opf"] = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0" unique-identifier="id" xmlns="http://www.idpf.org/2007/opf">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="id">urn:uuid:\(UUID().uuidString)</dc:identifier>
            <dc:title>Writing modes</dc:title><dc:language>\(language)</dc:language>
          </metadata>
          <manifest>\(items.joined())</manifest>
          \(spine)\(itemrefs.joined())</spine>
        </package>
        """.utf8)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        // A name of its own: the session's spine cache is keyed by the file's name.
        let archiveURL = root.appendingPathComponent("\(UUID().uuidString).epub")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archive = try await Archive(url: archiveURL, accessMode: .create)
        // `mimetype` first, as the container requires.
        for path in ["mimetype"] + entries.keys.filter({ $0 != "mimetype" }).sorted() {
            let file = root.appendingPathComponent("source").appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try entries[path]!.write(to: file)
            try await archive.addEntry(with: path, fileURL: file)
        }
        return archiveURL
    }
}
