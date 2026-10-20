@testable import YueduCoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// A chapter's embedded-font lookups run inside `NodeAttributedStringRenderer.render`, a
/// nonisolated async method, so they run on the global executor — off the main thread — while
/// other chapters register their `@font-face` faces on the main actor. Whatever that lookup
/// reads must therefore be a value the chapter owns, never the main-actor registration table.
@Suite(.serialized)
@MainActor
struct EPUBChapterFontSnapshotTests {
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var threads: [Bool] = []
        var calls: [Bool] { lock.withLock { threads } }
        func record() { lock.withLock { threads.append(Thread.isMainThread) } }
    }

    /// The premise: awaited from the main actor exactly as `buildChapter` does, the renderer
    /// calls its `resolvedFont` hook off the main thread. This holds because the app target
    /// builds without NonisolatedNonsendingByDefault or default main-actor isolation. If a build
    /// setting change makes this fail, the news is not about fonts: a 150–250 ms chapter render
    /// now runs on the caller's actor (main), and `render` needs `@concurrent`.
    @Test func rendererResolvesFontsOffTheMainThread() async throws {
        let probe = Probe()
        let config = NodeAttributedStringRenderer.Config(
            from: EPUBTestFixtures.renderSettings(),
            renderWidth: 320,
            resolvedFont: { @Sendable _, _, _, size in
                probe.record()
                return UIFont.systemFont(ofSize: size)
            }
        )
        let ast = try #require(await HTMLAttributedStringBuilder().buildStyledAST(
            html: "<html><body><p style='font-family: BookFace'>Text</p></body></html>",
            config: EPUBTestFixtures.htmlConfig()
        ))
        _ = await NodeAttributedStringRenderer(config: config)
            .render(HTMLStyledASTRenderableNodeConverter.convert(body: ast))
        #expect(!probe.calls.isEmpty)
        #expect(probe.calls.allSatisfy { !$0 },
            "render moved onto the caller's actor (main) — mark NodeAttributedStringRenderer.render @concurrent")
    }

    /// The race without a publication archive, for Thread Sanitizer: ReadiumZIPFoundation's
    /// `DataSource.readInt` traps on a misaligned load in a TSan build, so a TSan run cannot
    /// open the EPUB the builder-level test below uses. The production resolver registers other
    /// chapters' faces on the main actor while one chapter renders off it, with the font hook
    /// wired as the EPUB and Online builders wire it. With the hook calling the resolver's
    /// live table instead (the builders before 2026-10-18), TSan reports a Swift access race:
    /// read in `registeredFonts` from `NodeAttributedStringRenderer.makeFontResolved` on a
    /// worker thread, previous write by `registerFontFaces` on the main thread.
    @Test func chapterRenderWhileOtherFacesRegisterOnMain() async throws {
        let fontData = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Ahem.ttf"))
        let resolver = EPUBStyleResolver(
            resourceProvider: FontBytesProvider(fontData: fontData),
            fontRegistrationService: CoreTextFontRegistrationService()
        )
        let rendered = (0..<40).map { "Rendered\($0)" }
        let registering = (0..<200).map { "Registering\($0)" }
        _ = await resolver.processStylesheet(
            (rendered + registering).map {
                "@font-face { font-family: \($0); src: url('../Fonts/\($0).ttf'); }"
            }.joined(separator: "\n"),
            cssHref: "OPS/Styles/fonts.css",
            chapterHref: "OPS/chapter.xhtml"
        )
        await resolver.registerFontFaces(requests: Set(rendered.map {
            ResolvedFontRequest(family: $0, weight: 400, italic: false)
        }))
        // As the builders do: the snapshot of the faces this chapter registered.
        let fonts = resolver.registeredFonts
        let config = NodeAttributedStringRenderer.Config(
            from: EPUBTestFixtures.renderSettings(),
            renderWidth: 320,
            resolvedFont: { @Sendable families, weight, italic, size in
                fonts.resolve(families: families, weight: weight, italic: italic, size: size)
            }
        )
        let html = "<html><body>" + (0..<400).map {
            "<p style='font-family: \(rendered[$0 % rendered.count]); font-size: \(12 + $0 % 9)px'>Line \($0)</p>"
        }.joined() + "</body></html>"
        let ast = try #require(await HTMLAttributedStringBuilder().buildStyledAST(
            html: html, config: EPUBTestFixtures.htmlConfig()))
        let nodes = HTMLStyledASTRenderableNodeConverter.convert(body: ast)

        async let chapter = NodeAttributedStringRenderer(config: config).render(nodes)
        await resolver.registerFontFaces(requests: Set(registering.map {
            ResolvedFontRequest(family: $0, weight: 400, italic: false)
        }))
        let string = await chapter
        #expect(string.length > 0)
        #expect(Self.postScriptNames(in: string) == ["Ahem"])
        #expect(resolver.registeredFontFaces.count == rendered.count + registering.count)
    }

    /// Builds one long chapter while other chapters of the same book register their own
    /// `@font-face` aliases on the main actor. Before the chapter resolved from its own snapshot,
    /// the long chapter's background lookups read the resolver's dictionaries while those
    /// registrations wrote them: Thread Sanitizer reports the race on this test. Without TSan
    /// the outcome is timing-dependent, so the plain assertions only check that every chapter
    /// still gets its embedded face.
    @Test func chapterBuiltWhileOtherChaptersRegisterFontsKeepsItsEmbeddedFace() async throws {
        let otherChapters = 6
        let aliasesPerChapter = 24
        let session = try await PublicationSession.open(sourceURL: EPUBTestFixtures.makeArchive(
            entries: try Self.entries(otherChapters: otherChapters, aliasesPerChapter: aliasesPerChapter)
        ))
        let settings = EPUBTestFixtures.renderSettings()
        for _ in 0..<3 {
            let builder = EPUBAttributedStringBuilder(session: session, renderSize: CGSize(width: 320, height: 480))
            // Its own main-actor task, so the long build interleaves with the others'. It hands
            // back only what is checked: the chapter itself is not Sendable.
            let long = Task { @MainActor in
                let chapter = try await builder.buildChapter(
                    at: 0, settings: settings, themeTextColor: .black, themeBackgroundColor: .white
                ).attributedString
                return (length: chapter.length, faces: Self.postScriptNames(in: chapter))
            }
            var others: [NSAttributedString] = []
            for index in 1...otherChapters {
                others.append(try await builder.buildChapter(
                    at: index, settings: settings, themeTextColor: .black, themeBackgroundColor: .white
                ).attributedString)
            }
            let longChapter = try await long.value
            #expect(longChapter.length > 0)
            #expect(longChapter.faces == ["Ahem"])
            for chapter in others {
                #expect(chapter.length > 0)
                #expect(Self.postScriptNames(in: chapter) == ["Ahem"])
            }
        }
    }

    // MARK: - Benchmark (machine-local books)

    /// Chapter build time on real heavy-CSS books, cold (a fresh builder fetches and registers
    /// the chapter's faces) and warm (same builder again). Reads `render=` and the total from
    /// the `⏱ coreText.document.buildChapter` line. Set YUEDU_FONT_SNAPSHOT_BENCH=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YUEDU_FONT_SNAPSHOT_BENCH"] == "1"))
    func benchmarkHeavyCSSChapterBuild() async throws {
        let directory = "/Users/zhangruilin/Desktop/Test document/EPUB Format/"
        let books: [(id: String, file: String, spine: Int)] = [
            ("quanzhi-101-font-face", "《全职高手3》作者：蝴蝶蓝.epub", 69),
            ("game-designer-9-fonts", "《全能游戏设计师1》作者：冷陌 & 青衫取醉.epub", 10),
        ]
        let variant = ProcessInfo.processInfo.environment["YUEDU_FONT_SNAPSHOT_VARIANT"] ?? "?"
        let log = DiagnosticLog.shared
        let verbose = log.isVerboseEnabled
        log.isVerboseEnabled = true
        defer { log.isVerboseEnabled = verbose }
        let settings = EPUBTestFixtures.renderSettings()
        let size = CGSize(width: 390, height: 800)
        for book in books {
            let session = try await PublicationSession.open(sourceURL: URL(fileURLWithPath: directory + book.file))
            func measure(_ builder: EPUBAttributedStringBuilder) async throws -> (total: Double, render: Double, fonts: Double) {
                let before = Set(log.snapshot().map(\.id))
                _ = try await builder.buildChapter(
                    at: book.spine, settings: settings, themeTextColor: .black, themeBackgroundColor: .white)
                let line = try #require(log.snapshot().first {
                    !before.contains($0.id) && $0.message.contains("coreText.document.buildChapter")
                        && $0.message.contains("spine=\(book.spine) ")
                }).message
                return (Self.ms(line, after: "buildChapter "), Self.ms(line, after: "render="), Self.ms(line, after: "fonts="))
            }
            // Untimed: the process-wide font registration and the archive's first reads.
            _ = try await measure(EPUBAttributedStringBuilder(session: session, renderSize: size))
            var cold: [(Double, Double, Double)] = []
            var warm: [(Double, Double, Double)] = []
            for _ in 0..<10 {
                let builder = EPUBAttributedStringBuilder(session: session, renderSize: size)
                cold.append(try await measure(builder))
                warm.append(try await measure(builder))
            }
            for (phase, samples) in [("cold", cold), ("warm", warm)] {
                print("FONT-BENCH variant=\(variant) book=\(book.id) phase=\(phase) n=\(samples.count) "
                    + "total=\(Self.median(samples.map(\.0))) render=\(Self.median(samples.map(\.1))) "
                    + "fonts=\(Self.median(samples.map(\.2))) "
                    + "totals=\(samples.map { Int($0.0) }) renders=\(samples.map { Int($0.1) })")
            }
        }
    }

    private static func ms(_ line: String, after marker: String) -> Double {
        guard let range = line.range(of: marker) else { return .nan }
        let digits = line[range.upperBound...].prefix { $0.isNumber || $0 == "." }
        return Double(digits) ?? .nan
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? .nan : sorted[sorted.count / 2]
    }

    // MARK: - Fixture

    private static func entries(otherChapters: Int, aliasesPerChapter: Int) throws -> [String: Data] {
        let fontURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Ahem.ttf")
        var manifest = "<item id='nav' href='nav.xhtml' media-type='application/xhtml+xml' properties='nav'/>"
            + "<item id='font' href='Fonts/ahem.ttf' media-type='font/ttf'/>"
        var spine = ""
        var entries: [String: Data] = [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """.utf8),
            "OPS/Fonts/ahem.ttf": try Data(contentsOf: fontURL),
            "OPS/nav.xhtml": Data(EPUBTestFixtures.xhtml(
                title: "Nav", body: #"<nav epub:type="toc"><ol><li><a href="c0.xhtml">0</a></li></ol></nav>"#
            ).utf8),
        ]
        for chapter in 0...otherChapters {
            // Chapter 0 is the long one: hundreds of styled runs, each a font lookup.
            let aliases = chapter == 0
                ? ["LongFace", "LongFaceBold"]
                : (0..<aliasesPerChapter).map { "Face\(chapter)x\($0)" }
            let css = aliases.enumerated().map { offset, alias in
                "@font-face { font-family: \(alias); src: url('../Fonts/ahem.ttf'); }\n"
                    + ".f\(offset) { font-family: \(alias); }"
            }.joined(separator: "\n") + "\nb { font-weight: 700; }"
            let paragraphs = chapter == 0 ? 400 : aliasesPerChapter
            let body = (0..<paragraphs).map { index in
                "<p class='f\(index % aliases.count)'>Line \(index) <b>bold \(index)</b> tail</p>"
            }.joined()
            entries["OPS/Styles/c\(chapter).css"] = Data(css.utf8)
            entries["OPS/c\(chapter).xhtml"] = Data(EPUBTestFixtures.xhtml(
                title: "C\(chapter)",
                body: body,
                head: "<link href='Styles/c\(chapter).css' rel='stylesheet' type='text/css'/>"
            ).utf8)
            manifest += "<item id='c\(chapter)' href='c\(chapter).xhtml' media-type='application/xhtml+xml'/>"
                + "<item id='s\(chapter)' href='Styles/c\(chapter).css' media-type='text/css'/>"
            spine += "<itemref idref='c\(chapter)'/>"
        }
        entries["OPS/package.opf"] = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0" unique-identifier="bookid" xmlns="http://www.idpf.org/2007/opf">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">urn:uuid:font-snapshot</dc:identifier>
            <dc:title>Font snapshot</dc:title>
            <dc:language>en</dc:language>
          </metadata>
          <manifest>\(manifest)</manifest>
          <spine>\(spine)</spine>
        </package>
        """.utf8)
        return entries
    }

    /// Serves the same font bytes for every font URL, from off the main actor like the
    /// publication's archive reads.
    private final class FontBytesProvider: BookResourceProvider {
        let customScheme = "reader-test"
        let chapters: [BookResourceChapterDescriptor] = []
        let fontData: Data
        init(fontData: Data) { self.fontData = fontData }
        func cssResourceHrefs() -> [String] { [] }
        func resourceURL(for href: String) -> URL { URL(string: "\(customScheme)://book/\(href)")! }
        func resourceAvailability(for requestURL: URL) -> Bool? { true }
        func chapterDataSize(at index: Int) async throws -> Int { 0 }
        func chapterIndex(for href: String) -> Int? { nil }
        func chapterHTML(at index: Int) async throws -> String { "" }
        func response(for requestURL: URL) async throws -> PublicationResourceResponse {
            PublicationResourceResponse(data: fontData, mimeType: "font/ttf", textEncodingName: nil)
        }
    }

    private static func postScriptNames(in string: NSAttributedString) -> Set<String> {
        var names = Set<String>()
        let text = string.string as NSString
        string.enumerateAttribute(.font, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            guard let font = value as? UIFont,
                  text.substring(with: range).contains(where: { $0.isLetter || $0.isNumber })
            else { return }
            names.insert(font.fontName)
        }
        return names
    }
}
