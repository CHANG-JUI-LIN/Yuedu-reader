import CoreText
import Foundation
import Testing
import UIKit
import YueduCoreText
@testable import yuedu_app

/// A very long chapter is laid out by several typesetters (`CoreTextChapterFramesetter`),
/// because one typesetter for the whole of it costs far more than its length. What the
/// reader shows must not depend on that: pages, chunks and every line in them have to be
/// the ones a single typesetter makes.
@Suite("CoreText chapter framesetter", .serialized)
struct CoreTextChapterFramesetterTests {
    private static let renderSize = CGSize(width: 390, height: 844)
    private static let insets = UIEdgeInsets(top: 24, left: 20, bottom: 24, right: 20)

    @Test(
        "Pages from windows are the pages one typesetter makes",
        arguments: [ReaderWritingMode.horizontal, .verticalRTL],
        // 3,000: several pages per window. 400: every page runs past its window's text, and
        // one paragraph is longer than five windows.
        [3_000, 400]
    )
    @MainActor
    func windowedPagesMatch(writingMode: ReaderWritingMode, windowLength: Int) async throws {
        let text = await Self.chapter()
        let whole = Self.layout(text, writingMode: writingMode)
        let windowed = CoreTextChapterFramesetter.$windowLengthOverride.withValue(windowLength) {
            Self.layout(text, writingMode: writingMode)
        }
        #expect(!whole.framesetter.isWindowed)
        #expect(windowed.framesetter.isWindowed)
        #expect(windowed.framesetter.windowCount > 2)
        try #require(whole.pageRanges.count > 8)
        #expect(windowed.pageRanges.map(\.location) == whole.pageRanges.map(\.location))
        #expect(windowed.pageRanges.map(\.length) == whole.pageRanges.map(\.length))
        try #require(windowed.pageArtifacts.count == whole.pageArtifacts.count)
        for (page, pair) in zip(whole.pageArtifacts, windowed.pageArtifacts).enumerated() {
            #expect(Self.lines(of: pair.0.frame) == Self.lines(of: pair.1.frame), "page \(page)")
            #expect(pair.0.lineOrigins == pair.1.lineOrigins, "page \(page)")
        }
    }

    @Test(
        "Scroll chunks from windows are the chunks one typesetter makes",
        arguments: [ReaderWritingMode.horizontal, .verticalRTL],
        [3_000, 400]
    )
    @MainActor
    func windowedChunksMatch(writingMode: ReaderWritingMode, windowLength: Int) async throws {
        let text = await Self.chapter()
        func slice() -> [CoreTextChunk] {
            CoreTextChunkSlicer.slice(
                attributedString: text, chapterIndex: 0, contentWidth: 350, heightCap: 600, writingMode: writingMode
            ).chunks
        }
        let whole = slice()
        let windowed = CoreTextChapterFramesetter.$windowLengthOverride.withValue(windowLength) { slice() }
        try #require(whole.count > 4)
        #expect(windowed.first?.framesetter.isWindowed == true)
        #expect(windowed.map(\.charRange.location) == whole.map(\.charRange.location))
        #expect(windowed.map(\.charRange.length) == whole.map(\.charRange.length))
        #expect(windowed.map(\.width) == whole.map(\.width))
        #expect(windowed.map(\.height) == whole.map(\.height))
        for (index, pair) in zip(whole, windowed).enumerated() {
            #expect(
                Self.lines(of: pair.0.makeFrame(using: pair.0.framesetter))
                    == Self.lines(of: pair.1.makeFrame(using: pair.1.framesetter)),
                "chunk \(index)"
            )
        }
    }

    @Test("A long chapter's first page builds one window; an ordinary chapter has one typesetter")
    @MainActor
    func firstPageBuildsOneWindow() async throws {
        let long = await Self.dialogue(characterCount: 200_000)
        let first = await CoreTextPaginator().paginateFirstPage(
            spineIndex: 0, attrStr: long, renderSize: Self.renderSize, fontSize: 17, revision: ContentRevision()
        )
        let framesetter = try #require(first).framesetter
        #expect(framesetter.isWindowed)
        #expect(framesetter.windowCount == 3)
        #expect(framesetter.builtWindowCount == 1)

        let ordinary = await Self.dialogue(characterCount: 60_000)
        #expect(!CoreTextChapterFramesetter(ordinary).isWindowed)
    }

    @Test("Windows cover the chapter without gaps, end at paragraphs, and number eight at most")
    func sharesCoverTheChapter() {
        let paragraph = String(repeating: "字", count: 613) + "\n"
        let string = String(repeating: paragraph, count: 1_400) as NSString
        let size = max(
            CoreTextChapterFramesetter.minimumWindowLength,
            (string.length + CoreTextChapterFramesetter.maximumWindows - 1) / CoreTextChapterFramesetter.maximumWindows
        )
        let shares = CoreTextChapterFramesetter.shares(of: string, size: size)
        #expect(shares.count <= CoreTextChapterFramesetter.maximumWindows)
        #expect(shares.first?.location == 0)
        #expect(shares.last.map(NSMaxRange) == string.length)
        for (previous, next) in zip(shares, shares.dropFirst()) {
            #expect(NSMaxRange(previous) == next.location)
            #expect(string.character(at: next.location - 1) == 0x000A)
        }
    }

    // MARK: - Fixtures

    /// Each line's string range and typographic width.
    private static func lines(of frame: CTFrame) -> [String] {
        (CTFrameGetLines(frame) as! [CTLine]).map { line in
            let range = CTLineGetStringRange(line)
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            return "\(range.location)+\(range.length) w=\(String(format: "%.2f", width))"
        }
    }

    private static func layout(_ text: NSAttributedString, writingMode: ReaderWritingMode) -> CoreTextPaginator.ChapterLayout {
        CoreTextPaginator.computeLayout(
            spineIndex: 0,
            attrStr: text,
            imagePage: nil,
            pageBackgroundImage: nil,
            pageBackgroundColor: nil,
            darkPageBackgroundColor: nil,
            anchorOffsets: [:],
            renderSize: renderSize,
            fontSize: 17,
            contentInsets: insets,
            writingMode: writingMode,
            bottomJustify: !writingMode.isVertical
        )
    }

    /// Headings, dialogue with adjacent marks, mixed scripts, a quotation, and one paragraph
    /// far longer than a page, through the production HTML pipeline.
    private static func chapter() async -> NSAttributedString {
        let dialogue = "「你來了。」他抬起頭，看見城牆上的旗幟在風中翻捲，低聲說道：「這一戰我們必須贏下來。」眾人沉默片刻，隨即齊聲應和。"
        let mixed = "他說：「這是 CoreText 的測試，English words mixed in, 123,456.78!」一段包含標點符號、引號『』與破折號——還有省略號……的文字。"
        let long = String(repeating: "山雨欲來風滿樓，「黑雲壓城城欲摧。」甲光向日金鱗開；", count: 90)
        var body = ""
        for section in 0..<6 {
            body += "<h2>第\(section + 1)節　風起</h2>"
            for index in 0..<14 {
                body += "<p>\(index % 3 == 0 ? mixed : dialogue)\(String(repeating: "他沒有回答。", count: index % 5))</p>"
            }
            body += "<blockquote><p>\(dialogue)</p></blockquote>"
            if section == 2 { body += "<p>\(long)</p>" }
        }
        return await EPUBTestFixtures.renderIR(
            html: EPUBTestFixtures.xhtml(title: "windows", body: body),
            config: EPUBTestFixtures.htmlConfig(renderWidth: renderSize.width)
        )
    }

    private static func dialogue(characterCount: Int) async -> NSAttributedString {
        let paragraph = "「你來了。」他抬起頭，看見城牆上的旗幟在風中翻捲，低聲說道：「這一戰我們必須贏下來。」眾人沉默片刻，隨即齊聲應和。"
        let count = max(1, characterCount / (paragraph.utf16.count + 1))
        return await EPUBTestFixtures.renderIR(
            html: EPUBTestFixtures.xhtml(title: "long", body: String(repeating: "<p>\(paragraph)</p>", count: count)),
            config: EPUBTestFixtures.htmlConfig(renderWidth: renderSize.width)
        )
    }
}
