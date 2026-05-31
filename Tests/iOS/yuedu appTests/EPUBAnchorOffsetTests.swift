import Foundation
import Testing
import UIKit
@testable import yuedu_app

// Regression coverage for TOC anchor resolution. EPUBs (e.g. Project Gutenberg) often place
// many TOC sub-sections inside one spine file, distinguished only by `#fragment` anchors that
// point at block headings/divs. Those anchors must land in `anchorOffsets` so each entry maps
// to its own page instead of all collapsing to the spine's first page.
@Suite("EPUB anchor offsets")
@MainActor
struct EPUBAnchorOffsetTests {

    private func config() -> HTMLAttributedStringBuilder.Config {
        HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 0,
            paragraphSpacing: 8,
            firstLineIndent: 0,
            textColor: .label,
            backgroundColor: .systemBackground,
            fontFamilyName: nil,
            renderWidth: 360
        )
    }

    @Test("captures id anchors on block headings and divs, not only inline spans")
    func blockAndInlineAnchors() async throws {
        let html = """
        <html><body>
        <p>Intro paragraph before any of the sections begins.</p>
        <h3 id="sec-a">Section A. General Historical Points of View.</h3>
        <p>The body of section A with enough words to advance the offset.</p>
        <div class="chapter" id="sec-b"><p>Section B content lives in a block div.</p></div>
        <p>Trailing text with an <span id="sec-c">inline anchor</span> at the end.</p>
        </body></html>
        """
        let result = await HTMLAttributedStringBuilder().build(html: html, config: config())
        let offsets = result.anchorOffsets

        let a = try #require(offsets["sec-a"], "block <h3> id should be an anchor")
        let b = try #require(offsets["sec-b"], "block <div> id should be an anchor")
        let c = try #require(offsets["sec-c"], "inline <span> id should be an anchor")

        // Sections resolve to distinct, increasing offsets — not all 0 (which previously
        // collapsed every TOC entry onto the spine's first page).
        #expect(a > 0)
        #expect(b > a)
        #expect(c > b)
    }
}
