import Foundation
import Testing
@testable import yuedu_app

/// legado's four-argument `java.showBrowser(url, html, js, config)` with no `html` opens `url`
/// itself (`BottomWebViewDialog` fetches it). We showed "" with `url` as its base: the 段評
/// sheet of 知秋's ✿起点（段评）✿ came up white (reported 2026-10-10).
@Suite("Source browser page without HTML", .serialized)
@MainActor
struct SourceBrowserPageWithoutHTMLTests {
    nonisolated private static let zhiqiuPath = "/Users/zhangruilin/Downloads/164bf06e8a7e90344c06866bfc441735.json"

    @Test("a null-html showBrowser asks for the URL itself, not an empty page")
    func nullHTMLMeansOpenTheURL() throws {
        var source = BookSource()
        source.bookSourceName = "fixture"
        source.bookSourceUrl = "https://fixture.example"
        let bridge = ModernParserBridge(source: source)
        var page: LegadoBrowserPageRequest?
        bridge.browserPagePresentHandler = { page = $0 }
        _ = bridge.evaluateSourceScript("java.showBrowser('https://fixture.example/comments?pid=3', null, null, '{}')")
        let request = try #require(page)
        #expect(request.baseURL == "https://fixture.example/comments?pid=3")
        #expect(request.html == nil)
    }

    @Test(
        "知秋's 段評 bubble opens the comment page URL",
        .enabled(if: FileManager.default.fileExists(atPath: zhiqiuPath), "Needs 知秋's source JSON at \(zhiqiuPath)")
    )
    func zhiqiuReviewOpensCommentPage() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.zhiqiuPath))
        var source = try #require(JSONDecoder().decode([BookSource].self, from: data).first)
        source.id = UUID()
        let bridge = ModernParserBridge(source: source)
        var page: LegadoBrowserPageRequest?
        bridge.browserPagePresentHandler = { page = $0 }
        // A stand-in token: the page URL only has to carry one.
        _ = bridge.evaluateSourceScript("source.setVariable('fixture-token'); showCmt.call(this, '1001', '2002', '3')")
        let request = try #require(page)
        #expect(request.html == nil)
        #expect(request.baseURL.contains("/novel/comment/page/"))
        #expect(request.baseURL.contains("pid=3"))
    }
}
