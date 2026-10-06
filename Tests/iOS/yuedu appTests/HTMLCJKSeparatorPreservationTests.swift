import Testing
import UIKit
@testable import yuedu_app

/// The legacy builder keeps whitespace between two Han characters.
///
/// It once claimed to strip it (`cleanDirtySpacesInHTML`), but that regex wrote NBSP as
/// `\u{00A0}` — Swift escape syntax ICU rejects — so `try? NSRegularExpression` was nil and the
/// cleanup never ran. It was deleted rather than fixed: every stored reading position, bookmark
/// and highlight in the legacy engine indexes the text with these separators in it, YueduCoreText
/// keeps them too, and U+3000 between Han is often meaningful (「夏目　漱石」, verse breaks).
@MainActor
@Suite("Legacy CJK separator preservation")
struct HTMLCJKSeparatorPreservationTests {
    @Test func ideographicSpaceBetweenHanCharactersSurvives() async {
        let text = await renderedText(separator: "\u{3000}")
        #expect(text.contains("漢\u{3000}字"), "\(text.debugDescription)")
    }

    @Test(arguments: [" ", "\u{00A0}", "&nbsp;", "&#160;"])
    func spaceBetweenHanCharactersCollapsesToOneSpace(_ separator: String) async {
        let text = await renderedText(separator: separator)
        #expect(text.contains("漢 字"), "\(text.debugDescription)")
    }

    private func renderedText(separator: String) async -> String {
        await EPUBTestFixtures.renderIR(
            html: "<html><body><p>漢\(separator)字</p></body></html>",
            config: EPUBTestFixtures.htmlConfig()
        ).string
    }
}
