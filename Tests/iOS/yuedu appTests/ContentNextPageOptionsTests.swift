import Foundation
import Testing
@testable import yuedu_app

/// A content page's next link can carry AnalyzeUrl options, as any rule URL can: Legado reads
/// each next page with `AnalyzeUrl(mUrl = nextUrl)` (BookContent.kt), which splits them off.
@Suite("Content next page options")
struct ContentNextPageOptionsTests {
    private static let link = #"http://www.xsbook.org/227_227157/1823698_2.html,{"retry":2}"#

    @Test func analyzeUrlSplitsANextLinksOptions() {
        let analyzeUrl = AnalyzeUrl(ruleUrl: Self.link, baseUrl: "http://www.xsbook.org")
        #expect(analyzeUrl.url == "http://www.xsbook.org/227_227157/1823698_2.html")
        #expect(analyzeUrl.toURLRequest()?.url?.absoluteString == "http://www.xsbook.org/227_227157/1823698_2.html")
        #expect(analyzeUrl.retry == 2)
    }

    @Test func aNextLinkWithOptionsGoesToTheRuntime() {
        var source = BookSource()
        source.bookSourceUrl = "http://www.xsbook.org"
        #expect(source.shouldUseLegadoRuntimeFetch(for: Self.link))
    }
}
