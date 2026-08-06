import Testing
import UIKit
@testable import yuedu_app

/// Capability scanner: conservative accept/reject per chapter.
struct BrowserLayoutCapabilityScannerTests {

    private func scan(_ html: String, _ css: [String] = []) -> BrowserLayoutCapabilityResult {
        BrowserLayoutCapabilityScanner.scan(html: html, cssTexts: css)
    }

    @Test func acceptsPlainReflowableContent() {
        let html = """
        <html><body><p>Hello <strong>world</strong></p>
        <p><a href="x.html">link</a> and <img src="a.png" alt="x"></p>
        </body></html>
        """
        let css = ["p { margin: 0 0 1em 0; line-height: 1.4 }", "a { color: #0000cc }"]
        let result = scan(html, css)
        #expect(result.supported)
        #expect(result.unsupportedFeatures.isEmpty)
    }

    @Test func acceptsPaintOnlyUnsupportedProperties() {
        // background-image / text-shadow do not affect layout → allowed.
        let html = "<html><body><p>Text</p></body></html>"
        let css = ["p { background-image: url(bg.png); text-shadow: 1px 1px; }"]
        #expect(scan(html, css).supported)
    }

    @Test func rejectsVerticalWritingMode() {
        let css = ["body { writing-mode: vertical-rl }"]
        let result = scan("<html><body><p>文</p></body></html>", css)
        #expect(!result.supported)
        #expect(result.unsupportedFeatures.contains(.verticalWritingMode))
    }

    @Test func rejectsVerticalEpubPrefix() {
        let css = ["body { -epub-writing-mode: vertical-rl }"]
        #expect(!scan("<html><body></body></html>", css).supported)
    }

    @Test func rejectsFloat() {
        let css = [".x { float: left }"]
        #expect(scan("<html><body><div class=\"x\">y</div></body></html>", css).unsupportedFeatures.contains(.float))
    }

    @Test func rejectsTable() {
        let html = "<html><body><table><tr><td>cell</td></tr></table></body></html>"
        #expect(scan(html).unsupportedFeatures.contains(.table))
    }

    @Test func rejectsFlexGrid() {
        let css = ["body { display: flex }"]
        #expect(scan("<html><body></body></html>", css).unsupportedFeatures.contains(.unknownBlockDisplay))
        // A rule must MATCH a real element to reject (DOM-aware scanning:
        // unmatched rules in a shared stylesheet must not reject a chapter).
        let css2 = [".x { grid-template-columns: 1fr }"]
        #expect(scan("<html><body><div class=\"x\">y</div></body></html>", css2).unsupportedFeatures.contains(.flexGrid))
        #expect(!scan("<html><body></body></html>", css2).supported || scan("<html><body></body></html>", css2).unsupportedFeatures.isEmpty)
    }

    @Test func rejectsPositioned() {
        let css = [".x { position: absolute }"]
        #expect(scan("<html><body><div class=\"x\">y</div></body></html>", css).unsupportedFeatures.contains(.positioned))
        let inline = "<html><body><p style=\"position: fixed\">x</p></body></html>"
        #expect(scan(inline).unsupportedFeatures.contains(.positioned))
        // Unmatched rule on an empty body does NOT reject (shared-stylesheet case).
        #expect(scan("<html><body></body></html>", css).unsupportedFeatures.isEmpty)
    }

    @Test func rejectsRubyAndMathMLAndScript() {
        #expect(scan("<html><body><ruby>漢<rt>かん</rt></ruby></body></html>").unsupportedFeatures.contains(.ruby))
        #expect(scan("<html><body><math><mi>x</mi></math></body></html>").unsupportedFeatures.contains(.mathML))
        #expect(scan("<html><body><script>alert(1)</script></body></html>").unsupportedFeatures.contains(.scriptedInteractive))
    }

    @Test func rejectsMediaQueriesAndCalc() {
        let media = ["@media screen { p { font-size: 20px } }"]
        #expect(scan("<html><body><p>x</p></body></html>", media).unsupportedFeatures.contains(.mediaQueries))
        let calc = ["p { width: calc(100% - 10px) }"]
        #expect(scan("<html><body><p>x</p></body></html>", calc).unsupportedFeatures.contains(.calcOrModernFunctions))
    }

    @Test func commentedOutFeaturesDoNotReject() {
        let css = ["/* .x { float: left } */ p { margin: 0 }"]
        #expect(scan("<html><body><p>x</p></body></html>", css).supported)
    }
}
