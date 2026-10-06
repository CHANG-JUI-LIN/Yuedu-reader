import Combine
import Foundation
import Testing
import UIKit
import YueduCoreText
@testable import yuedu_app

/// The text both engines read from a converted chapter is the planned chapter
/// text (docs/aozora/epub-text-contract.md). Anyone changing the writer's markup
/// or its stylesheet keeps this green.
@Suite("Aozora engine parity", .serialized)
@MainActor
struct AozoraEngineParityTests {
    /// Every construct of the writer's table, collapsed ASCII spaces, U+3000 at block
    /// edges, blank lines, a line split by 地付き and a multi-line heading.
    static let source = """
        題
        著者

        前書きの段落。
        第一章［＃「第一章」は大見出し］
        　字下げの段落、｜漢字《かんじ》と刺［＃「刺」の左に「テフダ」の注記］。
        強調［＃「強調」に傍点］と点［＃「点」の左に傍点］、線［＃「線」に傍線］と線［＃「線」の左に傍線］。
        太［＃「太」は太字］と斜［＃「斜」は斜体］、大［＃「大」は１段階大きな文字］、12［＃「12」は縦中横］。
        x2［＃「2」は上付き小文字］とx2［＃「2」は下付き小文字］、学［＃（ビテ）］而時習［＃レ］之。
        本［＃割り注］注［＃割り注終わり］、箱［＃「箱」は罫囲み］、ABC［＃「ABC」は横組み］、図１［＃「図１」はキャプション］。
        ※［＃「口＋世」、ページ数-行数］と本文［＃「本文」はママ］、A  B and C\tD 、A&B<C>。
        上［＃改行］下

        文。［＃地付き］（未完）
        ［＃ここから中見出し］
        二

        副題
        ［＃ここで中見出し終わり］
        ［＃ここから２字下げ］
        字下げの行
        ［＃ここで字下げ終わり］
        小節［＃「小節」は小見出し］
        一［＃「一」は同行中見出し］　同行の本文
        ［＃改ページ］
        図の前［＃「猫の図」のキャプション付きの図（fig1.png、横10×縦10）入る］図の後
        ［＃挿絵１（fig1.png、横10×縦10）入る］
        "A" and 'B' are straight quotes.

        底本：「題」架空書房
        入力：誰か

        """

    @Test("BrowserAuto's paged and scroll text and legacy's text are the planned chapter text", arguments: [
        ReaderWritingMode.horizontal, ReaderWritingMode.verticalRTL,
    ])
    func parity(mode: ReaderWritingMode) async throws {
        let (session, chapters) = try await Self.book()
        #expect(session.chapters.count == chapters.count)
        let size = CGSize(width: 320, height: 480)
        let settings = EPUBTestFixtures.renderSettings(writingMode: mode)
        let builder = EPUBAttributedStringBuilder(session: session, renderSize: size)
        for (spine, chapter) in chapters.enumerated() {
            let figures = Self.figureCount(chapter)
            // Legacy: one U+FFFC per figure, U+2028 for a line break, curled quotes.
            let legacy = try await builder.buildChapter(at: spine, settings: settings,
                themeTextColor: .black, themeBackgroundColor: .white).attributedString.string
            #expect(legacy.filter { $0 == "\u{FFFC}" }.count == figures, "spine \(spine)")
            #expect(Self.normalizedLegacy(legacy) == chapter.text, "legacy spine \(spine) \(mode)")

            let renderer = EPUBPageRenderer()
            renderer.load(publicationSession: session, bookIdentifier: UUID().uuidString, renderSize: size, settings: settings)
            for await ready in renderer.$isCoreTextReady.values where ready { break }
            let engine = try #require(renderer.engine as? BrowserLayoutPageEngine)
            _ = await engine.preloadChapter(at: spine)
            // The engine choice: BrowserAuto everywhere in horizontal writing; in vertical
            // writing a chapter with a figure goes to legacy (VerticalTextSupport.accepts).
            let expectsBrowser = mode == .horizontal || figures == 0
            #expect(engine.choice(for: spine)?.isBrowser == expectsBrowser, "spine \(spine) \(mode)")
            guard expectsBrowser else { continue }
            let paged = try #require(engine.testLayout(for: spine))
            #expect(paged.sourceText == chapter.text, "paged spine \(spine) \(mode)")

            let scroll = try #require(renderer.scrollEngine)
            await scroll.start(initialChapter: spine, contentWidth: size.width, viewportExtent: size.height,
                               loadAdjacentChapters: false)
            guard case .browser(let tile)? = scroll.chunks.first else {
                Issue.record("expected a BrowserAuto scroll tile for spine \(spine) \(mode)")
                continue
            }
            #expect(tile.chapter.document.sourceText == chapter.text, "scroll spine \(spine) \(mode)")
        }
    }

    // MARK: Helpers

    static func book() async throws -> (PublicationSession, [AozoraChapter]) {
        let document = AozoraDocumentParser.parse(source)
        let chapters = AozoraChapterPlanner.plan(document, source: source)
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        try #require(image.pngData()).write(to: png)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aozora-parity-\(UUID().uuidString).epub")
        _ = try await AozoraEPUBWriter.write(
            document, chapters: chapters, images: ["fig1.png": png],
            source: AozoraEPUBManifest.Source(sha256: "", encoding: String.Encoding.utf8.rawValue, length: source.utf16.count),
            identifier: "urn:uuid:aozora-parity", to: url)
        return (try await PublicationSession.open(sourceURL: url), chapters)
    }

    /// Legacy's text read as BrowserAuto's: a line break inside a block is U+2028
    /// there, quotes are curled, and a figure is U+FFFC.
    static func normalizedLegacy(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "\u{2028}": out.append("\n")
            case "\u{201C}", "\u{201D}": out.append("\"")
            case "\u{2018}", "\u{2019}": out.append("'")
            case "\u{FFFC}": continue
            default: out.append(character)
            }
        }
        return out
    }

    static func figureCount(_ chapter: AozoraChapter) -> Int {
        let document = AozoraDocumentParser.parse(source)
        var count = 0
        func walk(_ inlines: [AozoraInline]) {
            for inline in inlines {
                switch inline {
                case .image: count += 1
                case .ruby(let children, _, _), .emphasis(_, _, let children), .sideline(_, _, let children),
                     .bold(let children), .italic(let children), .size(_, let children),
                     .tateChuYoko(let children), .script(_, let children), .warichu(let children),
                     .heading(_, _, let children), .boxed(let children), .horizontal(let children),
                     .caption(let children):
                    walk(children)
                default: break
                }
            }
        }
        for span in chapter.spans {
            switch AozoraXHTMLWriter.block(span, in: document) {
            case .image: count += 1
            case .paragraph(let inlines, _), .heading(_, _, let inlines, _): walk(inlines)
            case .pageBreak: break
            }
        }
        return count
    }
}
