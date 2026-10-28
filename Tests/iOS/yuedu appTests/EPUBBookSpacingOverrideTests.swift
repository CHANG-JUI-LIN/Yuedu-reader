@testable import YueduCoreText
import Testing
import UIKit
@testable import yuedu_app

/// 套用書本間距 (feedback #97): an EPUB whose stylesheet sets `line-height` and paragraph
/// margins kept the reader's 行距／段距 sliders out of reach, so EPUB had no spacing row at
/// all. With the switch on, the book's CSS still wins (today's look); off, the reader's own
/// spacing replaces it everywhere in the chapter.
@Suite("EPUB book spacing override", .serialized)
struct EPUBBookSpacingOverrideTests {

    private static let styledHTML = """
    <html><head><style>
      p { line-height: 2.4; margin: 1.5em 0 3em 0; }
      div.box p { margin-top: 2em; }
    </style></head>
    <body>
    <p>第一段文字，書本自己寫了行距和段距。</p>
    <p>第二段文字，書本自己寫了行距和段距。</p>
    <div class="box"><p>第三段文字。</p></div>
    </body></html>
    """

    /// The same text with no stylesheet: what the reader's own spacing alone produces.
    private static let plainHTML = """
    <html><head></head>
    <body>
    <p>第一段文字，書本自己寫了行距和段距。</p>
    <p>第二段文字，書本自己寫了行距和段距。</p>
    <div class="box"><p>第三段文字。</p></div>
    </body></html>
    """

    private static let fontSize: CGFloat = 20
    private static let lineHeightMultiple: CGFloat = 1.3
    private static let paragraphSpacing: CGFloat = 7

    private static func settings() -> ReaderRenderSettings {
        ReaderRenderSettings(
            theme: "test",
            textColor: .black,
            backgroundColor: .white,
            fontSize: fontSize,
            lineHeightMultiple: lineHeightMultiple,
            lineSpacing: 0,
            paragraphSpacing: paragraphSpacing,
            letterSpacing: 0,
            marginH: 0,
            marginV: 0,
            footerHeight: 0,
            contentInsets: .zero
        )
    }

    @MainActor
    private func render(_ html: String, usesBookSpacing: Bool) async throws -> NSAttributedString {
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: Self.fontSize,
            lineHeightMultiple: Self.lineHeightMultiple,
            lineSpacing: 0,
            paragraphSpacing: Self.paragraphSpacing,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            fontFamilyName: nil,
            renderWidth: 320
        )
        let ast = try #require(await HTMLAttributedStringBuilder().buildStyledAST(html: html, config: config))
        let nodes = HTMLStyledASTRenderableNodeConverter.convert(body: ast)
        let renderer = NodeAttributedStringRenderer(
            config: NodeAttributedStringRenderer.Config(
                from: Self.settings(),
                renderWidth: 320,
                honorsBookSpacing: usesBookSpacing
            )
        )
        return await renderer.render(nodes)
    }

    private struct Spacing: Equatable {
        let lineHeight: CGFloat
        let before: CGFloat
        let after: CGFloat
    }

    private func paragraphSpacings(_ string: NSAttributedString) -> [Spacing] {
        let ns = string.string as NSString
        var result: [Spacing] = []
        var location = 0
        while location < ns.length {
            let range = ns.paragraphRange(for: NSRange(location: location, length: 0))
            if let para = string.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                as? NSParagraphStyle {
                result.append(Spacing(
                    lineHeight: para.maximumLineHeight,
                    before: para.paragraphSpacingBefore,
                    after: para.paragraphSpacing
                ))
            }
            location = NSMaxRange(range)
        }
        return result
    }

    @Test @MainActor
    func bookSpacingOnKeepsTheStylesheetsLineHeightAndMargins() async throws {
        let styled = paragraphSpacings(try await render(Self.styledHTML, usesBookSpacing: true))
        let plain = paragraphSpacings(try await render(Self.plainHTML, usesBookSpacing: true))
        try #require(styled.count == 3 && plain.count == 3)
        #expect(styled[0].lineHeight > plain[0].lineHeight + 1)
        // 3em after the first paragraph collapses against 1.5em before the second: 60pt.
        #expect(abs(styled[0].after + styled[1].before - Self.fontSize * 3) < 0.5)
    }

    @Test @MainActor
    func bookSpacingOffUsesTheReadersSpacingEverywhere() async throws {
        let styled = paragraphSpacings(try await render(Self.styledHTML, usesBookSpacing: false))
        let plain = paragraphSpacings(try await render(Self.plainHTML, usesBookSpacing: false))
        try #require(styled.count == 3 && plain.count == 3)
        #expect(styled == plain)
        #expect(abs(styled[0].after - Self.paragraphSpacing) < 0.01)
        #expect(styled[1].before == 0)
        #expect(styled[2].before == 0)
    }

    @Test
    func togglingBookSpacingRelaysOut() {
        let on = Self.settings()
        var off = on
        off.usesBookSpacing = false
        #expect(off.refreshIntent(comparedTo: on) == .layout)
    }

    @Test
    func epubOffersTheSpacingSliders() {
        #expect(EPUBBookDocument.supportedCapabilities.contains(.spacing))
    }
}
