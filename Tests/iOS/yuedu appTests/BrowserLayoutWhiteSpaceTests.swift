import Testing
import UIKit
@testable import yuedu_app

/// `<br>` + `white-space` modes.
struct BrowserLayoutWhiteSpaceTests {

    @Test func brForcesLineBreakInNormalMode() async throws {
        let html = "<html><body><p>Alpha<br>Beta</p></body></html>"
        let (pages, doc) = try await BrowserLayoutTestSupport.layout(html)
        let visible = BrowserLayoutTestSupport.visibleText(pages, sourceText: doc.lastSourceText)
        #expect(visible == "Alpha\nBeta")
        // Three fragments: "Alpha", the zero-width "\n" break, and "Beta".
        let fragments = BrowserLayoutTestSupport.allTextFragments(pages)
        #expect(fragments.count == 3)
        #expect(fragments[0].rect.maxY <= fragments[2].rect.minY)
    }

    @Test func prePreservesWhitespaceVerbatim() async throws {
        let html = "<html><body><pre>  A   B\n C  </pre></body></html>"
        let (pages, doc) = try await BrowserLayoutTestSupport.layout(html)
        let visible = BrowserLayoutTestSupport.visibleText(pages, sourceText: doc.lastSourceText)
        #expect(visible == "  A   B\n C  ")
        let fragments = BrowserLayoutTestSupport.allTextFragments(pages)
        #expect(fragments.count == 2) // two lines (the \n)
    }

    @Test func nowrapNeverBreaksAtSpaces() async throws {
        let html = "<html><body><p style=\"white-space: nowrap\">AAAA BBBB CCCC DDDD EEEE</p></body></html>"
        let (pages, doc) = try await BrowserLayoutTestSupport.layout(html, width: 80)
        let fragments = BrowserLayoutTestSupport.allTextFragments(pages)
        // One line despite the narrow width (overflow accepted in Phase 1.5).
        #expect(fragments.count == 1)
        #expect(BrowserLayoutTestSupport.visibleText(pages, sourceText: doc.lastSourceText) == "AAAA BBBB CCCC DDDD EEEE")
    }

    @Test func preWrapBreaksLongWords() async throws {
        let html = "<html><body><p style=\"white-space: pre-wrap\">AAAA BBBB CCCC DDDD EEEE FFFF GGGG</p></body></html>"
        let (pages, _) = try await BrowserLayoutTestSupport.layout(html, width: 80)
        let fragments = BrowserLayoutTestSupport.allTextFragments(pages)
        #expect(fragments.count >= 2) // wraps at spaces, unlike nowrap
    }

    @Test func preLineCollapsesSpacesButKeepsNewlines() async throws {
        let html = "<html><body><p style=\"white-space: pre-line\">A   B\n   C</p></body></html>"
        let (pages, doc) = try await BrowserLayoutTestSupport.layout(html)
        let visible = BrowserLayoutTestSupport.visibleText(pages, sourceText: doc.lastSourceText)
        #expect(visible == "A B\nC")
    }

    @Test func normalCollapsesWhitespace() async throws {
        let html = "<html><body><p>Hello   world\n   again</p></body></html>"
        let (pages, doc) = try await BrowserLayoutTestSupport.layout(html)
        let visible = BrowserLayoutTestSupport.visibleText(pages, sourceText: doc.lastSourceText)
        #expect(visible == "Hello world again")
    }
}
