@testable import YueduCoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// A 段評 bubble belongs to its paragraph's last character. CoreText may break a line right
/// before an attachment, so a paragraph whose last line was full put its bubble alone at the
/// start of the next line (起点 qimo 第2章, paragraph 68).
@Suite("段評 bubble stays on its paragraph's last line", .serialized)
@MainActor
struct CommentBubbleLineEndTests {
    private let page = CGSize(width: 393, height: 852)
    private let insets = UIEdgeInsets(top: 70, left: 22, bottom: 50, right: 22)

    private var marker: String {
        ReaderHTMLUtilities.rewriteReviewComments(
            #"<comment count="2" onClick="java.startBrowser('https://example.com/r?p=1','段评')"/>"#
        )
    }

    @Test("the bubble never opens a line, whatever the paragraph's length")
    func bubbleNeverOpensALine() async throws {
        for length in 8...40 {
            let text = String(repeating: "字", count: length - 2) + "。”"
            let layout = try await layout(html: "<p>\(text)\(marker)</p>")
            let bubble = try #require(
                layout.inlineAttachments.values.flatMap { $0 }
                    .first { $0.linkHref?.hasPrefix("ydreview://") == true }
            )
            #expect(bubble.rect.minX > insets.left + 1, "\(length) characters: the bubble opened a line")
        }
    }

    @Test("a word joiner holds the bubble to the text, outside its review link")
    func bubbleIsGluedOutsideItsLink() async throws {
        let attributed = try await build(html: "<p>正文。”\(marker)</p>").attributedString
        let glue = try #require(attributed.string.range(of: "。”\u{2060}\u{FFFC}"))
        let joiner = NSRange(glue, in: attributed.string).location + 2
        #expect(attributed.attribute(HTMLAttributedStringBuilder.internalLinkAttribute, at: joiner, effectiveRange: nil) == nil)
        #expect(attributed.attribute(HTMLAttributedStringBuilder.internalLinkAttribute, at: joiner + 1, effectiveRange: nil) != nil)
    }

    private func build(html: String) async throws -> AttributedChapterBuildResult {
        let builder = OnlineProviderAttributedStringBuilder(
            provider: SingleChapterProvider(html: html),
            renderSize: CGSize(
                width: page.width - insets.left - insets.right,
                height: page.height - insets.top - insets.bottom
            )
        )
        return try await builder.buildChapter(
            at: 0,
            settings: ReaderRenderSettings(
                theme: "test", textColor: .black, backgroundColor: .white,
                fontSize: 20, lineHeightMultiple: 1.6, lineSpacing: 0, paragraphSpacing: 10,
                letterSpacing: 0, marginH: insets.left, marginV: insets.bottom, footerHeight: 0,
                contentInsets: insets, writingMode: .horizontal
            ),
            themeTextColor: .black,
            themeBackgroundColor: .white
        )
    }

    private func layout(html: String) async throws -> CoreTextPaginator.ChapterLayout {
        let built = try await build(html: html)
        return await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: built.attributedString,
            renderSize: page,
            fontSize: 20,
            contentInsets: insets
        )
    }
}

private final class SingleChapterProvider: BookContentProvider {
    private let html: String

    init(html: String) {
        self.html = html
    }

    var totalChapters: Int { 1 }

    func chapterTitle(at index: Int) -> String { "第1章" }

    func contentForChapter(index: Int) async throws -> ChapterContentPayload {
        ChapterContentPayload(
            index: 0,
            title: "第1章",
            plainText: "",
            body: .html(html),
            sourceHref: "https://example.com/1"
        )
    }
}
