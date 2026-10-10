import CoreGraphics
import CoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// 章節標題樣式 › 上距 must move the title down on every route a chapter title is
/// typeset through. Reported 2026-10-10 on iPad: changing it did nothing in an online
/// book, because the online builder ran the replace rules over the title block and the
/// default purification rule `^[\u3000\s]+` deleted the 上距 spacer line.
@Suite("Chapter title top spacing", .serialized)
@MainActor
struct ChapterTitleTopSpacingTests {

    private static let title = "第1章 永夜"
    private static let renderSize = CGSize(width: 400, height: 800)
    private static let insets = UIEdgeInsets(top: 40, left: 20, bottom: 40, right: 20)

    private static func style(topSpacing: CGFloat) -> ChapterTitleStyle {
        var style = ChapterTitleStyle.default
        style.advancedCSSEnabled = false
        style.splitEnabled = false
        style.topSpacing = topSpacing
        return style
    }

    private static func settings(topSpacing: CGFloat) -> ReaderRenderSettings {
        ReaderRenderSettings(
            theme: "sepia",
            textColor: .black,
            backgroundColor: .white,
            fontSize: 18,
            lineHeightMultiple: 1.6,
            lineSpacing: 10,
            paragraphSpacing: 8,
            letterSpacing: 0,
            marginH: insets.left,
            marginV: insets.top,
            footerHeight: 24,
            contentInsets: insets,
            chapterTitleStyle: style(topSpacing: topSpacing)
        )
    }

    /// Top of the title line on the first page, in top-left page coordinates.
    private static func titleTop(in attributed: NSAttributedString) async throws -> CGFloat {
        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: attributed,
            renderSize: renderSize,
            fontSize: 18,
            contentInsets: insets
        )
        let range = try #require(layout.pageRanges.first)
        let pathRect = CoreTextPaginator.coreTextContentPathRect(
            renderSize: layout.renderSize,
            contentInsets: layout.contentInsets,
            fontSize: layout.fontSize,
            writingMode: layout.writingMode
        )
        let frame = CTFramesetterCreateFrame(
            layout.framesetter, range, CGPath(rect: pathRect, transform: nil), nil
        )
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)
        let string = layout.attributedString.string as NSString
        for (index, line) in lines.enumerated() {
            let lineRange = CTLineGetStringRange(line)
            let text = string.substring(with: NSRange(location: lineRange.location, length: lineRange.length))
            guard text.contains("永夜") else { continue }
            var ascent: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, nil, nil)
            return layout.renderSize.height - (pathRect.minY + origins[index].y + ascent)
        }
        Issue.record("title line not found on the first page")
        return .nan
    }

    private static func assertMoves(
        route: String,
        build: (CGFloat) async throws -> NSAttributedString
    ) async throws {
        // The default purification rule that ate the spacer, installed here so the
        // test does not depend on what the simulator's rule list happens to hold.
        let leadingWhitespace = ReplaceRule(name: "TopSpacingTests", pattern: "^[\\u3000\\s]+")
        ReplaceRuleStore.shared.add(leadingWhitespace)
        defer { ReplaceRuleStore.shared.delete(id: leadingWhitespace.id) }

        var tops: [CGFloat] = []
        for spacing: CGFloat in [0, 20, 80] {
            let built = try await build(spacing)
            tops.append(try await titleTop(in: built))
        }
        print("⟐ titleTop route=\(route) tops=\(tops)")
        #expect(abs((tops[1] - tops[0]) - 20) < 2, "\(route): 0→20 moved \(tops[1] - tops[0])")
        #expect(abs((tops[2] - tops[1]) - 60) < 2, "\(route): 20→80 moved \(tops[2] - tops[1])")
    }

    @Test("TXT title moves with 上距")
    func txt() async throws {
        let body = "那一天太阳落下再也没有升起……\n永夜，天地漆黑。"
        try await Self.assertMoves(route: "txt") { spacing in
            let builder = TXTLazyAttributedStringBuilder(
                text: body,
                chapterIndexes: [
                    TXTChapterIndex(
                        index: 0,
                        title: Self.title,
                        contentRange: NSRange(location: 0, length: (body as NSString).length)
                    )
                ]
            )
            return try await builder.buildChapter(
                at: 0, settings: Self.settings(topSpacing: spacing),
                themeTextColor: .black, themeBackgroundColor: .white
            ).attributedString
        }
    }

    @Test("online plain-text title moves with 上距")
    func onlinePlain() async throws {
        try await Self.assertMoves(route: "online.plain") { spacing in
            let payload = ChapterContentPayload(
                index: 0, title: Self.title, plainText: "永夜，天地漆黑。",
                body: .plainText("永夜，天地漆黑。"), sourceHref: "https://example.com/1"
            )
            return try await OnlineProviderAttributedStringBuilder(
                provider: TopSpacingStubProvider(payload: payload), renderSize: Self.renderSize
            ).buildChapter(
                at: 0, settings: Self.settings(topSpacing: spacing),
                themeTextColor: .black, themeBackgroundColor: .white
            ).attributedString
        }
    }

    @Test("online HTML title moves with 上距")
    func onlineHTML() async throws {
        try await Self.assertMoves(route: "online.html") { spacing in
            let payload = ChapterContentPayload(
                index: 0, title: Self.title, plainText: "",
                body: .html("<h1>\(Self.title)</h1><p>永夜，天地漆黑。</p>"),
                sourceHref: "https://example.com/1"
            )
            return try await OnlineProviderAttributedStringBuilder(
                provider: TopSpacingStubProvider(payload: payload), renderSize: Self.renderSize
            ).buildChapter(
                at: 0, settings: Self.settings(topSpacing: spacing),
                themeTextColor: .black, themeBackgroundColor: .white
            ).attributedString
        }
    }

    @Test("online replace rules still clean the body, and leave the title block alone")
    func onlineReplaceRulesSkipTitleBlock() async throws {
        let rule = ReplaceRule(name: "TopSpacingTests.body", pattern: "永夜", replacement: "長夜")
        ReplaceRuleStore.shared.add(rule)
        defer { ReplaceRuleStore.shared.delete(id: rule.id) }

        let payload = ChapterContentPayload(
            index: 0, title: Self.title, plainText: "永夜，天地漆黑。",
            body: .plainText("永夜，天地漆黑。"), sourceHref: "https://example.com/1"
        )
        let built = try await OnlineProviderAttributedStringBuilder(
            provider: TopSpacingStubProvider(payload: payload), renderSize: Self.renderSize
        ).buildChapter(
            at: 0, settings: Self.settings(topSpacing: 20),
            themeTextColor: .black, themeBackgroundColor: .white
        ).attributedString.string

        #expect(built.contains(Self.title))
        #expect(built.contains("長夜，天地漆黑。"))
    }

    @Test("EPUB h1 moves with 上距")
    func epubHeading() async throws {
        try await Self.assertMoves(route: "epub.h1") { spacing in
            let renderer = NodeAttributedStringRenderer(
                config: NodeAttributedStringRenderer.Config(
                    from: Self.settings(topSpacing: spacing), renderWidth: 360
                )
            )
            return await renderer.render([
                .heading([.text(Self.title)], level: 1),
                .paragraph([.text("永夜，天地漆黑。")]),
            ])
        }
    }
}

private struct TopSpacingStubProvider: BookContentProvider {
    let payload: ChapterContentPayload

    var totalChapters: Int { 1 }

    func chapterTitle(at index: Int) -> String {
        index == payload.index ? payload.title : ""
    }

    func contentForChapter(index: Int) async throws -> ChapterContentPayload {
        guard index == payload.index else {
            throw BookContentProviderError.chapterIndexOutOfRange(index)
        }
        return payload
    }
}
