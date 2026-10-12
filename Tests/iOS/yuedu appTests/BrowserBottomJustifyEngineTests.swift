@testable import YueduCoreText
import CoreText
import Testing
import UIKit
@testable import yuedu_app

/// 底部對齊 through the EPUB engine: `ReaderRenderSettings.bottomJustify` reaches
/// `BrowserLayoutConfig`, and the package moves each full page's lines down so the
/// last one sits on the content bottom.
@MainActor
struct BrowserBottomJustifyEngineTests {
    private static let renderSize = CGSize(width: 300, height: 400)
    private static let insets = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

    private func pages(bottomJustify: Bool) async throws -> [PageFragments] {
        var settings = ReaderRenderSettings(
            theme: "paper", textColor: .black, backgroundColor: .white,
            fontSize: 17, lineHeightMultiple: 1.4, lineSpacing: 0, paragraphSpacing: 6,
            letterSpacing: 0, marginH: 12, marginV: 12, footerHeight: 24,
            contentInsets: Self.insets
        )
        settings.bottomJustify = bottomJustify
        let html = "<html><body>"
            + String(repeating: "<p>每一頁的最後一行都要貼齊內容區的底邊，中間的行距平均分攤剩下的空間。</p>", count: 30)
            + "</body></html>"
        let resource = MockBrowserLayoutResource(chapters: [
            .init(title: "c", href: "c.xhtml", html: html, css: [])
        ])
        let store = CharOffsetStore(directoryURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("bj-\(UUID().uuidString)"))
        let delegate = CoreTextPageEngine(
            attributedBuilder: MockAttributedStringBuilder(texts: ["c"]),
            renderSettings: settings, offsetStore: store
        )
        // `.browserAuto` explicitly: the default `.legacy` would route through the delegate.
        let engine = BrowserLayoutPageEngine(resource: resource, delegate: delegate, settings: settings, mode: .browserAuto)
        await engine.start(renderSize: Self.renderSize, bookId: "bj")
        return try #require(engine.testLayout(for: 0)).pages
    }

    private static func inkBottom(_ page: PageFragments) -> CGFloat {
        BrowserLayoutTestSupport.allTextFragments([page]).map { text in
            var descent: CGFloat = 0
            if let line = text.ctLine { CTLineGetTypographicBounds(line, nil, &descent, nil) }
            return text.baselineY + descent
        }.max() ?? 0
    }

    @Test func fullEPUBPagesEndOnTheContentBottom() async throws {
        let natural = try await pages(bottomJustify: false)
        let justified = try await pages(bottomJustify: true)
        try #require(natural.count >= 3)
        #expect(justified.count == natural.count)
        let contentBottom = Self.renderSize.height - Self.insets.bottom
        for (plain, page) in zip(natural, justified).dropLast() {
            #expect(Self.inkBottom(plain) < contentBottom - 1, "the natural page already reached the bottom")
            #expect(abs(Self.inkBottom(page) - contentBottom) < 0.5)
        }
    }
}
