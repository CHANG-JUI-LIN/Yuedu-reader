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
    /// edges, blank lines, a line split by 地付き and a multi-line heading; and a
    /// chapter of its own for the ruby BrowserAuto leaves to legacy.
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
        ［＃改ページ］
        室適《しつてき》［＃「室適」の左に「オクサマ」のルビ］と文字［＃ヘブライ文字「YOD」（fig1.png、横10×縦10）入る］《ヨッド》。

        底本：「題」架空書房
        入力：誰か

        """

    @Test("BrowserAuto's paged and scroll text and legacy's text are the planned chapter text", arguments: [
        ReaderWritingMode.horizontal, ReaderWritingMode.verticalRTL,
    ])
    func parity(mode: ReaderWritingMode) async throws {
        let (session, chapters) = try await Self.book()
        #expect(session.chapters.count == chapters.count)
        let document = AozoraDocumentParser.parse(Self.source)
        let xhtml = chapters.map { AozoraXHTMLWriter.document(for: $0, in: document, images: Self.images) }
        #expect(xhtml.filter(Self.holdsLegacyRuby).count == 1, "the fixture's ruby chapter")
        try await Self.expectPlannedText(in: session, chapters: chapters, spines: Array(chapters.indices),
                                         figures: { Self.figureCount(in: xhtml[$0]) },
                                         legacyRuby: { Self.holdsLegacyRuby(xhtml[$0]) }, mode: mode, label: "fixture")
    }

    /// Legacy, and BrowserAuto's paged and scroll layouts wherever it lays the chapter
    /// out, read each listed chapter as its planned text. `figures` gives a chapter's
    /// `<img>` count, and `legacyRuby` whether its ruby sends it to legacy.
    static func expectPlannedText(in session: PublicationSession, chapters: [AozoraChapter], spines: [Int],
                                  figures: (Int) -> Int, legacyRuby: (Int) -> Bool,
                                  mode: ReaderWritingMode, label: String) async throws {
        let size = CGSize(width: 320, height: 480)
        let settings = EPUBTestFixtures.renderSettings(writingMode: mode)
        let builder = EPUBAttributedStringBuilder(session: session, renderSize: size)
        for spine in spines {
            let planned = chapters[spine].text
            let figureCount = figures(spine)
            let place = "\(label) spine \(spine) \(mode)"
            // Legacy: one U+FFFC per figure, U+2028 for a line break, curled quotes.
            let legacy = try await builder.buildChapter(at: spine, settings: settings,
                themeTextColor: .black, themeBackgroundColor: .white).attributedString.string
            #expect(legacy.filter { $0 == "\u{FFFC}" }.count == figureCount, "\(place)")
            if let difference = firstDifference(read: legacy, planned: planned, legacy: true) {
                Issue.record("legacy \(place): \(difference)")
            }

            let renderer = EPUBPageRenderer()
            renderer.load(publicationSession: session, bookIdentifier: UUID().uuidString, renderSize: size, settings: settings)
            for await ready in renderer.$isCoreTextReady.values where ready { break }
            let engine = try #require(renderer.engine as? BrowserLayoutPageEngine)
            _ = await engine.preloadChapter(at: spine)
            // The engine choice: BrowserAuto everywhere in horizontal writing; in vertical
            // writing a chapter with a figure goes to legacy (VerticalTextSupport.accepts).
            // In either, so does a chapter with a ruby BrowserAuto does not lay out.
            let expectsBrowser = (mode == .horizontal || figureCount == 0) && !legacyRuby(spine)
            #expect(engine.choice(for: spine)?.isBrowser == expectsBrowser, "\(place)")
            guard expectsBrowser else { continue }
            guard let paged = engine.testLayout(for: spine) else {
                Issue.record("no BrowserAuto paged layout for \(place)")
                continue
            }
            if let difference = firstDifference(read: paged.sourceText, planned: planned) {
                Issue.record("paged \(place): \(difference)")
            }

            let scroll = try #require(renderer.scrollEngine)
            await scroll.start(initialChapter: spine, contentWidth: size.width, viewportExtent: size.height,
                               loadAdjacentChapters: false)
            guard case .browser(let tile)? = scroll.chunks.first else {
                Issue.record("expected a BrowserAuto scroll tile for \(place)")
                continue
            }
            if let difference = firstDifference(read: tile.chapter.document.sourceText, planned: planned) {
                Issue.record("scroll \(place): \(difference)")
            }
        }
    }

    /// Where an engine's text first departs from the planned text, with some context;
    /// nil when they agree. Legacy's text may hold a U+FFFC per figure, U+2028 for a
    /// line break, and curled quotes for straight ones.
    static func firstDifference(read: String, planned: String, legacy: Bool = false) -> String? {
        var actual = Array(read.unicodeScalars)
        if legacy { actual.removeAll { $0 == "\u{FFFC}" } }
        let expected = Array(planned.unicodeScalars)
        func same(_ a: Unicode.Scalar, _ b: Unicode.Scalar) -> Bool {
            guard a != b else { return true }
            guard legacy else { return false }
            switch (a, b) {
            case ("\u{2028}", "\n"), ("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{2018}", "'"), ("\u{2019}", "'"):
                return true
            default:
                return false
            }
        }
        let common = min(actual.count, expected.count)
        guard let index = (0..<common).first(where: { !same(actual[$0], expected[$0]) })
            ?? (actual.count == expected.count ? nil : common) else { return nil }
        func around(_ scalars: [Unicode.Scalar]) -> String {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[max(0, index - 20)..<min(scalars.count, index + 20)])
            return String(view).replacingOccurrences(of: "\n", with: "⏎")
        }
        return "scalar \(index) of \(expected.count) (read \(actual.count)): read «\(around(actual))», planned «\(around(expected))»"
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

    static let images = ["fig1.png": "../images/1-fig1.png"]

    /// A chapter's `<img>` elements, counted in its XHTML.
    nonisolated static func figureCount(in xhtml: String) -> Int {
        xhtml.components(separatedBy: "<img ").count - 1
    }

    /// Whether BrowserAuto leaves a chapter to legacy, in either writing mode, for its
    /// ruby: a ruby inside a ruby (a word with readings on both sides) or a figure in
    /// a ruby base. `HorizontalRubySupport` takes neither, nor `rtc`.
    nonisolated static func holdsLegacyRuby(_ xhtml: String) -> Bool {
        var depth = 0
        let tags = try! NSRegularExpression(pattern: "<ruby[ >]|</ruby>|<img ")
        for match in tags.matches(in: xhtml, range: NSRange(xhtml.startIndex..., in: xhtml)) {
            switch (xhtml as NSString).substring(with: match.range) {
            case "</ruby>": depth -= 1
            case "<img ": if depth > 0 { return true }
            default:
                if depth > 0 { return true }
                depth += 1
            }
        }
        return false
    }
}
