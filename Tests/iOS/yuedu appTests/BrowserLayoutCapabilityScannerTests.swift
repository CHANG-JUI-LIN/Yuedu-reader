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

    @Test func rejectsInlineFloat() {
        let html = "<html><body><div style=\"float: left\">x</div></body></html>"
        #expect(scan(html).unsupportedFeatures.contains(.float))
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

    @Test func rejectsMathMLAndScript() {
        #expect(scan("<html><body><math><mi>x</mi></math></body></html>").unsupportedFeatures.contains(.mathML))
        #expect(scan("<html><body><script>alert(1)</script></body></html>").unsupportedFeatures.contains(.scriptedInteractive))
    }

    @Test func acceptsSupportedHorizontalRubySubset() {
        let accepted: [(String, [String])] = [
            ("<ruby>漢<rt>かん</rt></ruby>", []),
            ("<ruby><span>漢字</span><rt>かんじ</rt></ruby>", []),
            ("<ruby>漢<rt><span>かん</span></rt></ruby>", []),
            ("<ruby>漢<rp>(</rp><rt>かん</rt><rp>)</rp></ruby>", []),
            ("<ruby>漢<rt>かん</rt></ruby>", ["ruby { ruby-align:center; ruby-position:over }"]),
        ]
        for (ruby, css) in accepted {
            let result = scan("<html><body><p>\(ruby)</p></body></html>", css)
            #expect(result.supported)
            #expect(!result.unsupportedFeatures.contains(.ruby))
        }
    }

    @Test func rejectsRubyOutsideSupportedSubset() {
        let rejected: [(String, [String])] = [
            ("<ruby>漢</ruby>", []),
            ("<ruby>漢<rt>a</rt><rt>b</rt></ruby>", []),
            ("<ruby><rb>漢</rb><rt>a</rt></ruby>", []),
            ("<ruby>漢<rtc><rt>a</rt></rtc></ruby>", []),
            ("<ruby>漢<rt>a</rt></ruby>", ["ruby { ruby-position:under }"]),
            ("<ruby>漢<rt>a</rt></ruby>", ["ruby { ruby-position:inter-character }"]),
            ("<ruby>漢<rt>a</rt></ruby>", ["ruby { -epub-ruby-position:under }"]),
            ("<ruby>漢<rt>a</rt></ruby>", ["ruby { ruby-align:start }"]),
            ("<ruby>外<ruby>內<rt>n</rt></ruby><rt>w</rt></ruby>", []),
            ("<ruby>漢<rt><span style='display:block'>a</span></rt></ruby>", []),
        ]
        for (ruby, css) in rejected {
            let result = scan("<html><body><p>\(ruby)</p></body></html>", css)
            #expect(result.unsupportedFeatures.contains(.ruby))
        }
    }

    @Test func rubySupportDoesNotEraseIndependentFallbackReasons() {
        let result = scan(
            "<html><body><p><ruby>漢<rt>かん</rt></ruby></p><table><tr><td>x</td></tr></table></body></html>"
        )
        #expect(!result.unsupportedFeatures.contains(.ruby))
        #expect(result.unsupportedFeatures.contains(.table))
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

// MARK: - float: reject only what actually floats

extension BrowserLayoutCapabilityScannerTests {

    /// 红楼梦 declares `float: center` on 51 of 57 float-classed boxes. `center`
    /// is not a float value, so those boxes compute to `none` and need no float
    /// layout at all. Rejecting on the `float` key alone cost 41 chapters the
    /// browser engine for nothing.
    @Test func invalidFloatValueDoesNotRejectChapter() {
        let html = "<html><body><div class=\"f\"><p>Text</p></div></body></html>"
        let result = BrowserLayoutCapabilityScanner.scan(
            html: html,
            cssTexts: ["div.f { float: center; }"]
        )
        #expect(result.supported)
        #expect(!result.unsupportedFeatures.contains(.float))
    }

    @Test func floatNoneDoesNotRejectChapter() {
        let result = BrowserLayoutCapabilityScanner.scan(
            html: "<html><body><p>Text</p></body></html>",
            cssTexts: ["p { float: none; }"]
        )
        #expect(result.supported)
    }

    @Test func explicitWidthFloatIsAccepted() {
        for value in ["left", "right", "LEFT", "  right  "] {
            let result = BrowserLayoutCapabilityScanner.scan(
                html: "<html><body><div class=\"f\">x</div></body></html>",
                cssTexts: ["div.f { float: \(value); width: 120px; }"]
            )
            #expect(result.supported, "float: \(value) with fixed width must be supported")
        }
    }

    @Test func laterFloatNoneWinsCascade() {
        let result = BrowserLayoutCapabilityScanner.scan(
            html: "<html><body><div class=\"f\">x</div></body></html>",
            cssTexts: [".f { float: left; } .f { float: none; }"]
        )
        #expect(result.supported)
    }

    @Test func inlineWidthAutoOverridesStylesheetWidth() {
        let result = BrowserLayoutCapabilityScanner.scan(
            html: "<html><body><div class=\"f\" style=\"float: left; width: auto\">x</div></body></html>",
            cssTexts: [".f { width: 120px; }"]
        )
        #expect(!result.supported)
        #expect(result.unsupportedFeatures.contains(.float))
    }

    @Test func maxWidthDoesNotReplaceFloatShrinkToFit() {
        let result = BrowserLayoutCapabilityScanner.scan(
            html: "<html><body><div style=\"float: left; width: auto; max-width: 120px\">x</div></body></html>",
            cssTexts: []
        )
        #expect(!result.supported)
        #expect(result.unsupportedFeatures.contains(.float))
    }

    @Test func nestedFloatsFallBackAsComplexFloatLayout() {
        let html = """
        <html><body>
        <div style="float: left; width: 160px">
          <img style="float: right" src="cover.jpg">
        </div>
        </body></html>
        """
        let result = BrowserLayoutCapabilityScanner.scan(html: html, cssTexts: [])
        #expect(!result.supported)
        #expect(result.unsupportedFeatures.contains(.float))
    }

    @Test func styleElementParticipatesInFloatClassification() {
        let html = """
        <html><head><style>.f { float: left; }</style></head>
        <body><div class="f">x</div></body></html>
        """
        let result = BrowserLayoutCapabilityScanner.scan(html: html, cssTexts: [])
        #expect(!result.supported)
        #expect(result.unsupportedFeatures.contains(.float))
    }

    @Test func floatParserSharesOneWhitelist() {
        #expect(CSSFloat.parse("left") == .left)
        #expect(CSSFloat.parse("RIGHT") == .right)
        #expect(CSSFloat.parse(" none ") == CSSFloat.none)
        #expect(CSSFloat.parse("center") == nil)
        #expect(CSSFloat.parse("inline-start") == nil)
    }
}

// MARK: - text-indent resolved subset

extension BrowserLayoutCapabilityScannerTests {
    @Test func acceptsSupportedTextIndentSubset() {
        for value in ["0", "20px", "1em", "2rem", "10%"] {
            let result = scan(
                "<html><body><p>x</p></body></html>",
                ["p { text-indent:\(value) }"]
            )
            #expect(result.supported, "value=\(value)")
        }
    }

    @Test func rejectsEffectiveUnsupportedTextIndent() {
        for value in ["hanging", "each-line", "-1px", "calc(2em + 1px)", "2em hanging"] {
            let result = scan(
                "<html><body><p>x</p></body></html>",
                ["p { text-indent:\(value) }"]
            )
            #expect(result.unsupportedFeatures.contains(.textIndent), "value=\(value)")
        }
    }

    @Test func overriddenUnsupportedTextIndentDoesNotReject() {
        let result = scan(
            "<html><body><p class='x'>x</p></body></html>",
            ["p { text-indent:hanging } p.x { text-indent:0 }"]
        )
        #expect(result.supported)
    }

    @Test func inheritedUnsupportedOnlyRejectsAFormattingOwner() {
        let overridden = scan(
            "<html><body><div class='parent'><p class='child'>x</p></div></body></html>",
            [".parent { text-indent:hanging } .child { text-indent:0 }"]
        )
        #expect(overridden.supported)

        let inherited = scan(
            "<html><body><div class='parent'><p>x</p></div></body></html>",
            [".parent { text-indent:hanging }"]
        )
        #expect(inherited.unsupportedFeatures.contains(.textIndent))
    }

    @Test func nonBreakingSpaceAndPreformattedSpaceAreFormattingOwners() {
        let nonBreaking = scan(
            "<html><body><p>&#160;</p></body></html>",
            ["p { text-indent:hanging }"]
        )
        #expect(nonBreaking.unsupportedFeatures.contains(.textIndent))

        let preformatted = scan(
            "<html><body><pre>   </pre></body></html>",
            ["pre { white-space:pre; text-indent:hanging }"]
        )
        #expect(preformatted.unsupportedFeatures.contains(.textIndent))
    }
}
