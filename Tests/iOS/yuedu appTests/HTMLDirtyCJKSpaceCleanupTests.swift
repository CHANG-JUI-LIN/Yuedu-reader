import Testing
import UIKit
@testable import yuedu_app

/// `HTMLAttributedStringBuilder.cleanDirtySpacesInHTML` says it strips whitespace, NBSP,
/// `&nbsp;` and `&#160;` between two Han characters before the chapter is parsed.
///
/// It has never run. `dirtyCJKSpaceRegex` writes NBSP as `\u{00A0}` — Swift escape syntax that
/// ICU rejects (it wants ` ` or `\x{00A0}`), so `try? NSRegularExpression` yields nil and
/// the cleanup returns the HTML untouched. Every case below fails until that is settled.
@MainActor
@Suite("Legacy CJK dirty-space cleanup")
struct HTMLDirtyCJKSpaceCleanupTests {
    @Test(arguments: ["\u{3000}", " ", "\u{00A0}", "&nbsp;", "&#160;"])
    func separatorBetweenHanCharactersIsRemoved(_ separator: String) async {
        let text = await EPUBTestFixtures.renderIR(
            html: "<html><body><p>漢\(separator)字</p></body></html>",
            config: EPUBTestFixtures.htmlConfig()
        ).string
        let scalars = separator.unicodeScalars.map { String(format: "U+%04X", $0.value) }
        #expect(
            text.contains("漢字"),
            "separator \(scalars.joined(separator: " ")) survived: \(text.debugDescription)"
        )
    }
}
