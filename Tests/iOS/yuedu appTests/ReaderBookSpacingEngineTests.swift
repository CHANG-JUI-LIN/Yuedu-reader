@testable import YueduCoreText
import Testing
import UIKit
@testable import yuedu_app

/// 套用書本間距 through the EPUB engine that cascades CSS. Off, the reader's 行距 and 段距
/// replace the book's — until 2026-11-21 only the legacy engine heard the switch, and
/// on this one, which every EPUB opens with, it moved nothing.
@MainActor
struct ReaderBookSpacingEngineTests {
    private static let renderSize = CGSize(width: 300, height: 400)
    private static let insets = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

    private func pages(usesBookSpacing: Bool) async throws -> [PageFragments] {
        var settings = ReaderRenderSettings(
            theme: "paper", textColor: .black, backgroundColor: .white,
            fontSize: 17, lineHeightMultiple: 1.4, lineSpacing: 0, paragraphSpacing: 6,
            letterSpacing: 0, marginH: 12, marginV: 12, footerHeight: 24,
            contentInsets: Self.insets
        )
        settings.usesBookSpacing = usesBookSpacing
        // A book that sets its paragraphs very loose, in a sheet and inline both.
        let html = "<html><head><style>p { line-height: 3; margin: 2em 0; }</style></head><body>"
            + String(repeating: "<p style=\"line-height: 3\">這本書把行距和段距都排得很寬，關掉套用書本間距之後應該照閱讀設定排。</p>", count: 24)
            + "</body></html>"
        let resource = MockBrowserLayoutResource(chapters: [
            .init(title: "c", href: "c.xhtml", html: html, css: [])
        ])
        let store = CharOffsetStore(directoryURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("bs-\(UUID().uuidString)"))
        let delegate = CoreTextPageEngine(
            attributedBuilder: MockAttributedStringBuilder(texts: ["c"]),
            renderSettings: settings, offsetStore: store
        )
        let engine = BrowserLayoutPageEngine(resource: resource, delegate: delegate, settings: settings, mode: .browserAuto)
        await engine.start(renderSize: Self.renderSize, bookId: "bs")
        return try #require(engine.testLayout(for: 0)).pages
    }

    /// The smallest step between two baselines on a page: the line pitch.
    private static func linePitch(_ page: PageFragments) -> CGFloat {
        let baselines = Set(BrowserLayoutTestSupport.allTextFragments([page]).map { ($0.baselineY * 10).rounded() / 10 })
            .sorted()
        return zip(baselines.dropFirst(), baselines).map { $0 - $1 }.min() ?? 0
    }

    @Test func offPutsTheReadersSpacingOverTheBooks() async throws {
        let book = try await pages(usesBookSpacing: true)
        let reader = try await pages(usesBookSpacing: false)
        let bookPitch = Self.linePitch(try #require(book.first))
        let readerPitch = Self.linePitch(try #require(reader.first))
        // 3 × 17 from the book, 1.4 × 17 from the reader's 行距.
        #expect(abs(bookPitch - 51) < 1, "book pitch \(bookPitch)")
        #expect(abs(readerPitch - 23.8) < 1, "reader pitch \(readerPitch)")
        #expect(reader.count < book.count)
    }

    @Test func theReadersSheetIsOnlyThereWhenTheSwitchIsOff() {
        var settings = EPUBTestFixtures.renderSettings(lineHeightMultiple: 1.5)
        #expect(ReaderBookSpacingStyleSheet.css(for: settings) == nil)
        let input = CSSFrontendInput.currentCompatibility(html: "<p>x</p>", cssTexts: ["p { margin: 1em }"])
        #expect(ReaderBookSpacingStyleSheet.applying(to: input, settings: settings).stylesheets.count
            == input.stylesheets.count)

        settings.usesBookSpacing = false
        settings.firstLineIndentEm = 1
        let css = try! #require(ReaderBookSpacingStyleSheet.css(for: settings))
        #expect(css.contains("line-height: 1.500 !important"))
        #expect(css.contains("text-indent: 1.000em !important"))
        let styled = ReaderBookSpacingStyleSheet.applying(to: input, settings: settings)
        #expect(styled.stylesheets.count == input.stylesheets.count + 1)
        // After every sheet of the book's, so it is the last word in the cascade.
        #expect(styled.productionStylesheetTexts.last == css)
    }

    /// The legacy engine carries the same rule on its node tree.
    @Test func theLegacyEngineTakesTheReadersIndentToo() {
        var style = RenderStyle(textIndent: 0)
        style.lineHeightMultiplier = 3
        let stripped = NodeAttributedStringRenderer.withoutBookSpacing(
            .paragraph([.text("段落")], style: style), paragraphIndent: 34)
        guard case let .paragraph(_, result) = stripped else {
            Issue.record("not a paragraph")
            return
        }
        #expect(result.textIndent == 34)
        #expect(result.lineHeightMultiplier == 1.0)
    }
}
