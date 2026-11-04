import Combine
import Foundation
import Testing
import UIKit
import YueduCoreText
@testable import yuedu_app

/// ページの左右中央 (Aozora plan, Task 15). The converter writes a chapter wholly under it
/// with `<body style="zy-page-align: center">`, and both engines set such a chapter, when it
/// fits on one page, in the middle of the page's block axis: top to bottom in horizontal
/// writing, right to left in vertical writing. Scroll mode leaves it at the top.
@Suite("Aozora page centring", .serialized)
@MainActor
struct AozoraPageCentringTests {
    static let source = """
        題
        著者

        ［＃改丁］
        ［＃ページの左右中央］
        　　　　　　　　献辞
        　　　　　　　　　　友に

        ［＃改ページ］
        本文の一行目。
        本文の二行目。

        底本：「題」架空書房
        入力：誰か

        """

    static let pageSize = CGSize(width: 320, height: 480)
    /// Unequal on every side, so a centre taken from the wrong edge shows.
    static let insets = UIEdgeInsets(top: 20, left: 16, bottom: 30, right: 24)

    static func settings(_ mode: ReaderWritingMode) -> ReaderRenderSettings {
        ReaderRenderSettings(
            theme: "test", textColor: .black, backgroundColor: .white, fontSize: 17,
            lineHeightMultiple: 1.5, lineSpacing: 0, paragraphSpacing: 8, letterSpacing: 0,
            marginH: 0, marginV: 0, footerHeight: 0, contentInsets: insets, writingMode: mode)
    }

    static func book() async throws -> (PublicationSession, [AozoraChapter], centred: Int, plain: Int) {
        let document = AozoraDocumentParser.parse(source)
        let chapters = AozoraChapterPlanner.plan(document, source: source)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aozora-centring-\(UUID().uuidString).epub")
        _ = try await AozoraEPUBWriter.write(
            document, chapters: chapters, images: [:],
            source: AozoraEPUBManifest.Source(sha256: "", encoding: String.Encoding.utf8.rawValue, length: source.utf16.count),
            identifier: "urn:uuid:aozora-centring", to: url)
        let centred = try #require(chapters.firstIndex { $0.text.contains("献辞") })
        let plain = try #require(chapters.firstIndex { $0.text.contains("本文の一行目") })
        return (try await PublicationSession.open(sourceURL: url), chapters, centred, plain)
    }

    /// The space a page leaves before and after `rects` along its block axis, inside the
    /// reader's content area.
    static func gaps(_ rects: [CGRect], mode: ReaderWritingMode) -> (start: CGFloat, end: CGFloat) {
        switch mode {
        case .horizontal:
            return (rects.map(\.minY).min()! - insets.top, pageSize.height - insets.bottom - rects.map(\.maxY).max()!)
        case .verticalRTL:
            return (pageSize.width - insets.right - rects.map(\.maxX).max()!, rects.map(\.minX).min()! - insets.left)
        }
    }

    @Test func theWriterMarksOnlyTheCentredChapter() async throws {
        let document = AozoraDocumentParser.parse(Self.source)
        let chapters = AozoraChapterPlanner.plan(document, source: Self.source)
        let marked = chapters.indices.filter {
            AozoraXHTMLWriter.document(for: chapters[$0], in: document, images: [:])
                .contains("<body style=\"\(AozoraXHTMLWriter.pageCentredBodyStyle)\">")
        }
        #expect(marked.map { chapters[$0].text.contains("献辞") } == [true])
        #expect(PublicationPageAlignment.centresSinglePage(bodyInlineStyle: AozoraXHTMLWriter.pageCentredBodyStyle))
        #expect(!PublicationPageAlignment.centresSinglePage(bodyInlineStyle: ""))
        #expect(!PublicationPageAlignment.centresSinglePage(bodyInlineStyle: "zy-fontsize-adjust: fixed"))
        // The text is the planned text, which the style does not touch.
        let (session, planned, centred, _) = try await Self.book()
        let legacy = try await EPUBAttributedStringBuilder(session: session, renderSize: Self.pageSize)
            .buildChapter(at: centred, settings: Self.settings(.horizontal), themeTextColor: .black, themeBackgroundColor: .white)
        #expect(legacy.centresSinglePage)
        #expect(AozoraEngineParityTests.firstDifference(read: legacy.attributedString.string,
                                                        planned: planned[centred].text, legacy: true) == nil)
    }

    @Test(arguments: LegacyTextEmphasisDecorationTests.modes)
    func browserAutoCentresTheTitlePage(mode: ReaderWritingMode) async throws {
        let (session, _, centred, plain) = try await Self.book()
        let renderer = EPUBPageRenderer()
        renderer.load(publicationSession: session, bookIdentifier: UUID().uuidString, renderSize: Self.pageSize,
                      settings: Self.settings(mode))
        for await ready in renderer.$isCoreTextReady.values where ready { break }
        let engine = try #require(renderer.engine as? BrowserLayoutPageEngine)
        func textRects(_ spine: Int) async throws -> (pages: Int, rects: [CGRect]) {
            _ = await engine.preloadChapter(at: spine)
            #expect(engine.choice(for: spine)?.isBrowser == true, "\(mode) spine \(spine)")
            let layout = try #require(engine.testLayout(for: spine))
            func texts(_ fragments: [Fragment]) -> [CGRect] {
                fragments.flatMap { fragment -> [CGRect] in
                    switch fragment {
                    case .text(let text): return [text.rect.rawValue]
                    case .group(let children): return texts(children)
                    case .fill, .image: return []
                    }
                }
            }
            return (layout.pages.count, texts(try #require(layout.pages.first).fragments))
        }
        let title = try await textRects(centred)
        #expect(title.pages == 1)
        let titleGaps = Self.gaps(title.rects, mode: mode)
        print("PAGE_CENTRING browser \(mode) gaps \(titleGaps)")
        #expect(abs(titleGaps.start - titleGaps.end) < 0.5, "\(mode) title page gaps \(titleGaps)")
        #expect(titleGaps.start > 50, "\(mode) the title page moved")
        // A chapter that does not ask stays at the start of its page: its first line sits
        // where any chapter's does, below the body's 8px user-agent margin.
        let body = try await textRects(plain)
        #expect(Self.gaps(body.rects, mode: mode).start < 12, "\(mode) body gaps \(Self.gaps(body.rects, mode: mode))")
    }

    @Test(arguments: LegacyTextEmphasisDecorationTests.modes)
    func legacyCentresTheTitlePage(mode: ReaderWritingMode) async throws {
        let (session, _, centred, plain) = try await Self.book()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = CoreTextPageEngine(session: session, renderSettings: Self.settings(mode),
                                        offsetStore: CharOffsetStore(directoryURL: directory))
        await engine.start(renderSize: Self.pageSize, bookId: UUID().uuidString)
        /// The page's ink, painted as the reader paints a page, in points.
        func ink(_ spine: Int) async throws -> (pages: Int, rects: [CGRect]) {
            _ = await engine.preloadChapter(at: spine)
            let layout = try #require(engine.layouts[spine])
            let pixels = try LegacyTextEmphasisDecorationTests.render(layout, scroll: false)
            let scale = LegacyTextEmphasisDecorationTests.scale
            let rects = pixels.blobs(LegacyTextEmphasisDecorationTests.Pixels.black).map {
                CGRect(x: CGFloat($0.minX) / scale, y: CGFloat($0.minY) / scale,
                       width: CGFloat($0.maxX - $0.minX + 1) / scale, height: CGFloat($0.maxY - $0.minY + 1) / scale)
            }
            try #require(!rects.isEmpty)
            return (layout.pageRanges.count, rects)
        }
        let title = try await ink(centred)
        #expect(title.pages == 1)
        let titleGaps = Self.gaps(title.rects, mode: mode)
        print("PAGE_CENTRING legacy \(mode) ink gaps \(titleGaps)")
        // Ink, not line boxes: a glyph's ink sits a little off its line's centre.
        #expect(abs(titleGaps.start - titleGaps.end) < 4, "\(mode) title page ink gaps \(titleGaps)")
        #expect(titleGaps.start > 50, "\(mode) the title page moved")
        let body = try await ink(plain)
        #expect(Self.gaps(body.rects, mode: mode).start < 8, "\(mode) body ink gaps \(Self.gaps(body.rects, mode: mode))")
    }
}
